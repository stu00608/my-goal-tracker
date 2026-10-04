import Foundation
import CoreLocation
import CryptoKit

nonisolated struct ConditionError: Error, Equatable {
    let key: String
    init(_ key: String) { self.key = key }
}
nonisolated enum ConditionState: Equatable { case met, unmet, unknown }

// Gate evaluation uses real distance and its uncertainty, never a photo or a recorded entry.
nonisolated enum ConditionEvaluation {
    static func requireMet(_ state: ConditionState) throws {
        switch state {
        case .met: return
        case .unmet: throw ConditionError("Your location does not meet the conditions. Your draft was kept.")
        case .unknown: throw ConditionError("Your location is too uncertain or stale. Try again in a moment. Your draft was kept.")
        }
    }
    static func state(distance: Double, accuracy: Double, relation: PlaceRelation) -> ConditionState {
        guard distance.isFinite, distance >= 0, accuracy.isFinite, accuracy >= 0 else { return .unknown }
        if distance + accuracy <= PlaceCondition.radius { return relation == .inside ? .met : .unmet }
        if distance - accuracy > PlaceCondition.radius { return relation == .outside ? .met : .unmet }
        return .unknown
    }
    static func state(_ condition: PlaceCondition, fix: CLLocation, now: Date) -> ConditionState {
        let point = RecordedLocation(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
        guard condition.location.isValid, point.isValid, (-5...60).contains(now.timeIntervalSince(fix.timestamp)) else { return .unknown }
        let center = CLLocation(latitude: condition.location.latitude, longitude: condition.location.longitude)
        return state(distance: fix.distance(from: center), accuracy: fix.horizontalAccuracy, relation: condition.relation)
    }
    static func aggregate(_ states: [ConditionState], combination: ConditionCombination) -> ConditionState {
        guard !states.isEmpty else { return .unknown }
        switch combination {
        case .all:
            if states.contains(.unmet) { return .unmet }
            return states.allSatisfy { $0 == .met } ? .met : .unknown
        case .any:
            if states.contains(.met) { return .met }
            return states.allSatisfy { $0 == .unmet } ? .unmet : .unknown
        }
    }
    static func aggregate(_ tracker: Tracker, fix: CLLocation, now: Date) -> ConditionState {
        aggregate(tracker.resolvedConditions.map { state($0, fix: fix, now: now) }, combination: tracker.resolvedCombination)
    }
}

@MainActor enum RecordConditions {
    static func verify(tracker: Tracker) async throws {
        try Task.checkCancellation()
        guard tracker.requiresLocationGate else { return }
        #if DEBUG && targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--uitesting"), let argument = args.first(where: { $0.hasPrefix("--condition-gate=") }) {
            let value = String(argument.dropFirst("--condition-gate=".count))
            let state: ConditionState = value == "met" ? .met : value == "unmet" ? .unmet : .unknown
            try ConditionEvaluation.requireMet(state)
            return
        }
        #endif
        let request = ConditionFixRequest(tracker: tracker)
        try await request.verify()
    }
}

@MainActor private final class ConditionFixRequest: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let tracker: Tracker
    private var manager: CLLocationManager?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var accuracyRequest: Task<Void, Never>?
    private var started = false
    private var requestedAccuracy = false
    private var requestedWhenInUse = false
    private var lastState = ConditionState.unknown
    init(tracker: Tracker) { self.tracker = tracker }
    func verify() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                guard CLLocationManager.locationServicesEnabled() else {
                    finish(.failure(ConditionError("Location Services are off. Enable them to verify your conditions."))); return
                }
                let manager = CLLocationManager()
                self.manager = manager
                manager.delegate = self
                manager.desiredAccuracy = kCLLocationAccuracyBest
                advance(manager)
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }
    private func advance(_ manager: CLLocationManager) {
        guard self.manager === manager, continuation != nil else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            if !requestedWhenInUse { requestedWhenInUse = true; manager.requestWhenInUseAuthorization() }
        case .restricted, .denied:
            finish(.failure(ConditionError("Location access is denied. Enable it in iPhone Settings to verify your conditions.")))
        case .authorizedAlways, .authorizedWhenInUse:
            if started && manager.accuracyAuthorization != .fullAccuracy {
                finish(.failure(ConditionError("Precise Location is required to verify these 200 m conditions."))); return
            }
            guard !started, accuracyRequest == nil else { return }
            if manager.accuracyAuthorization == .reducedAccuracy {
                guard !requestedAccuracy else {
                    finish(.failure(ConditionError("Precise Location is required to verify these 200 m conditions."))); return
                }
                requestedAccuracy = true
                accuracyRequest = Task { [weak self, weak manager] in
                    guard let self, let manager else { return }
                    do { try await manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "GoalookerCondition") }
                    catch { self.finish(.failure(ConditionError("Could not verify your location. Your draft was kept."))); return }
                    self.accuracyRequest = nil
                    self.advance(manager)
                }
                return
            }
            started = true
            manager.startUpdatingLocation()
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                guard let self else { return }
                self.finish(.failure(ConditionError("Your location is too uncertain or stale. Try again in a moment. Your draft was kept.")))
            }
        @unknown default: finish(.failure(ConditionError("Could not verify your location. Your draft was kept.")))
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { advance(manager) }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard self.manager === manager, started, manager.accuracyAuthorization == .fullAccuracy, let fix = locations.last else { return }
        lastState = ConditionEvaluation.aggregate(tracker, fix: fix, now: Date())
        switch lastState {
        case .met: finish(.success(()))
        case .unmet: finish(.failure(ConditionError("Your location does not meet the conditions. Your draft was kept.")))
        case .unknown: break // Keep improving the fix until the bounded timeout.
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard self.manager === manager else { return }
        if (error as? CLError)?.code == .locationUnknown { return }
        finish(.failure(ConditionError("Could not verify your location. Your draft was kept.")))
    }
    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        accuracyRequest?.cancel(); accuracyRequest = nil
        manager?.stopUpdatingLocation(); manager?.delegate = nil; manager = nil
        continuation.resume(with: result)
    }
}

// Stable rounded centers share one native monitor condition even across trackers and relations.
nonisolated struct ConditionCenter: Hashable {
    let latitude: Int
    let longitude: Int
    init(_ location: RecordedLocation) {
        latitude = Int((location.latitude * 100_000).rounded())
        longitude = Int((location.longitude * 100_000).rounded())
    }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: Double(latitude) / 100_000, longitude: Double(longitude) / 100_000)
    }
    var identifier: String { "Place" + Self.hash("\(latitude),\(longitude)") }
    static func hash(_ string: String) -> String { SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined() }
}
nonisolated enum ConditionPlan {
    static func mayNotify(transition: Bool, eventState: ConditionState, eventDate: Date, now: Date,
                          enabled: Bool, authorized: Bool) -> Bool {
        transition && enabled && authorized && eventState != .unknown && (-5...60).contains(now.timeIntervalSince(eventDate))
    }
    static func eligible(_ trackers: [Tracker]) -> [Tracker] {
        trackers.filter { !$0.archived && $0.remindWhenMet == true && !$0.resolvedConditions.isEmpty }
    }
    static func centers(_ trackers: [Tracker]) throws -> Set<ConditionCenter> {
        let conditions = eligible(trackers).flatMap(\.resolvedConditions)
        guard conditions.allSatisfy({ $0.location.isValid }) else { throw ConditionError("Choose a valid place for every condition.") }
        let result = Set(conditions.map { ConditionCenter($0.location) })
        guard result.count <= 20 else { throw ConditionError("Location reminders support up to 20 different places. Remove a place or disable a location reminder.") }
        return result
    }
    static func signature(_ tracker: Tracker) -> String {
        let conditions = tracker.resolvedConditions.map {
            "\($0.id.uuidString):\($0.location.isValid ? ConditionCenter($0.location).identifier : "Invalid"):\($0.relation.rawValue)"
        }.sorted().joined(separator: "|")
        return ConditionCenter.hash(tracker.resolvedCombination.rawValue + "|" + conditions)
    }
    static func state(inside: ConditionState, date: Date, relation: PlaceRelation, now: Date) -> ConditionState {
        guard (-5...43_200).contains(now.timeIntervalSince(date)) else { return .unknown }
        guard relation == .outside else { return inside }
        switch inside { case .met: return .unmet; case .unmet: return .met; case .unknown: return .unknown }
    }
}

// Only aggregate history is persisted. Native CLMonitor records remain the source of region state.
nonisolated struct ConditionTransition: Codable, Equatable {
    var signature: String
    var aggregate: Bool?
    var lastNotifiedAt: Date?
    mutating func observe(_ state: ConditionState, signature: String, now: Date, prime: Bool = false, initialStatesKnown: Bool = true) -> Bool {
        if prime || self.signature != signature {
            self.signature = signature
            aggregate = !initialStatesKnown || state == .unknown ? nil : state == .met
            return false
        }
        // Uncertainty must not manufacture a new exit/entry cycle.
        guard state != .unknown else { return false }
        guard let prior = aggregate else {
            guard initialStatesKnown else { return false }
            aggregate = state == .met
            return false
        }
        let current = state == .met
        aggregate = current
        return !prior && current && (lastNotifiedAt.map { now.timeIntervalSince($0) >= 7200 } ?? true)
    }
    mutating func delivered(at now: Date) { lastNotifiedAt = now }
    mutating func reset() { aggregate = nil }
}

nonisolated enum TrackerFields {
    static func website(_ input: String) throws -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.count <= 2048, let url = URLComponents(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.url != nil else {
            throw ConditionError("Enter a complete http or https website address.")
        }
        return text
    }
    static func axis(lower: String, upper: String, locale: Locale) throws -> (String?, String?) {
        let low = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        let high = upper.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = low.isEmpty ? nil : try Numbers.parse(low, locale: locale)
        let u = high.isEmpty ? nil : try Numbers.parse(high, locale: locale)
        if let l, let u, let a = Numbers.decimal(l), let b = Numbers.decimal(u), a >= b {
            throw ConditionError("The chart minimum must be less than the maximum.")
        }
        return (l, u)
    }
}
