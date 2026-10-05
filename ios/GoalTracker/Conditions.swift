import Foundation
import CoreLocation
import CryptoKit

nonisolated struct ConditionError: Error, Equatable {
    let key: String
    init(_ key: String) { self.key = key }
}
nonisolated enum ConditionState: Equatable { case met, unmet, unknown }

// Transient facts and results never become ledger, backup or Widget data.
nonisolated struct ConditionFacts {
    var fix: CLLocation?
    var places: [UUID: ConditionState] = [:]
    var health: [HealthFactKey: HealthFact] = [:]
    var locationIssue: String?
    var loadingPlaces = false
    var loadingHealth: Set<HealthFactKey> = []
    #if DEBUG && targetEnvironment(simulator)
    var fixtureStates: [UUID: ConditionState] = [:]
    #endif
}
nonisolated struct ConditionLeafStatus: Identifiable {
    let id: UUID
    let state: ConditionState
    var loading = false
    var detail: String?
    var measurement: Decimal?
    var measuredAt: Date?
}
nonisolated struct ConditionGroupStatus: Identifiable {
    let id: UUID
    let state: ConditionState
    let leaves: [ConditionLeafStatus]
    var loading: Bool { state == .unknown && leaves.contains { $0.loading } }
}
nonisolated struct ConditionStatus {
    let state: ConditionState
    let groups: [ConditionGroupStatus]
    var loading: Bool { state == .unknown && groups.contains { $0.loading } }
}

// Gate evaluation uses real distance and its uncertainty, never a photo or a recorded entry.
nonisolated enum ConditionEvaluation {
    static func requireMet(_ state: ConditionState) throws {
        switch state {
        case .met: return
        case .unmet: throw ConditionError("The achievement conditions are not met.")
        case .unknown: throw ConditionError("Could not verify the achievement conditions. Check their status and try again.")
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
        status(tracker: tracker, facts: ConditionFacts(fix: fix), now: now).state
    }
    static func time(_ condition: TimeCondition, calendar: Calendar, now: Date) -> ConditionState {
        guard (0..<1440).contains(condition.startMinute), (0..<1440).contains(condition.endMinute) else { return .unknown }
        if condition.startMinute == condition.endMinute { return .met }
        let components = calendar.dateComponents([.hour, .minute], from: now)
        guard let hour = components.hour, let minute = components.minute else { return .unknown }
        let current = hour * 60 + minute
        let met = condition.startMinute < condition.endMinute
            ? (condition.startMinute...condition.endMinute).contains(current)
            : current >= condition.startMinute || current <= condition.endMinute
        return met ? .met : .unmet
    }
    static func status(tracker: Tracker, facts: ConditionFacts, now: Date) -> ConditionStatus {
        let groups = tracker.resolvedConditionGroups.map { group in
            let leaves = group.conditions.map { leaf(tracker: tracker, condition: $0, facts: facts, now: now) }
            return ConditionGroupStatus(id: group.id, state: aggregate(leaves.map(\.state), combination: group.combination), leaves: leaves)
        }
        return ConditionStatus(state: aggregate(groups.map(\.state), combination: tracker.resolvedOuterCombination), groups: groups)
    }
    static func leaf(tracker: Tracker, condition: AchievementCondition, facts: ConditionFacts, now: Date) -> ConditionLeafStatus {
        #if DEBUG && targetEnvironment(simulator)
        if let state = facts.fixtureStates[condition.id] {
            return ConditionLeafStatus(id: condition.id, state: state)
        }
        #endif
        switch condition.payload {
        case .place(let place):
            let result = facts.places[condition.id] ?? facts.fix.map { state(place, fix: $0, now: now) } ?? .unknown
            return ConditionLeafStatus(id: condition.id, state: result,
                loading: result == .unknown && facts.loadingPlaces,
                detail: result == .unknown && !facts.loadingPlaces ? (facts.locationIssue ?? "Check your current location to evaluate this condition.") : nil)
        case .time(let value):
            return ConditionLeafStatus(id: condition.id, state: time(value, calendar: tracker.calendar, now: now))
        case .weekdays(let days):
            guard !days.isEmpty, Set(days).count == days.count, days.allSatisfy({ (1...7).contains($0) }) else {
                return ConditionLeafStatus(id: condition.id, state: .unknown)
            }
            return ConditionLeafStatus(id: condition.id, state: days.contains(tracker.calendar.component(.weekday, from: now)) ? .met : .unmet)
        case .steps(let threshold), .sleep(let threshold):
            let key = HealthFactKey(metric: condition.isSleep ? .sleep : .steps, window: threshold.window)
            guard let fact = facts.health[key] else {
                return ConditionLeafStatus(id: condition.id, state: .unknown, loading: facts.loadingHealth.contains(key),
                    detail: facts.loadingHealth.contains(key) ? nil : "Connect Apple Health or refresh to read this period’s data.")
            }
            guard let start = HealthConditionEvaluation.start(window: key.window, calendar: tracker.calendar, now: now),
                  start == fact.start, (0...300).contains(now.timeIntervalSince(fact.through)) else {
                return ConditionLeafStatus(id: condition.id, state: .unknown, loading: facts.loadingHealth.contains(key),
                    detail: facts.loadingHealth.contains(key) ? nil : "Health data needs refreshing for the current period.")
            }
            return ConditionLeafStatus(id: condition.id, state: HealthConditionEvaluation.compare(fact.value, threshold: threshold, metric: key.metric),
                loading: facts.loadingHealth.contains(key), detail: fact.issue,
                measurement: fact.value, measuredAt: fact.through)
        }
    }
    // Only unresolved groups can affect an unresolved aggregate. Cheap decisive branches require no permission.
    static func neededLeaves(tracker: Tracker, facts: ConditionFacts, now: Date) -> [AchievementCondition] {
        let snapshot = status(tracker: tracker, facts: facts, now: now)
        guard snapshot.state == .unknown else { return [] }
        return tracker.resolvedConditionGroups.flatMap { group -> [AchievementCondition] in
            guard let result = snapshot.groups.first(where: { $0.id == group.id }), result.state == .unknown else { return [] }
            let unresolved = Set(result.leaves.filter { $0.state == .unknown }.map(\.id))
            return group.conditions.filter { unresolved.contains($0.id) }
        }
    }
    static func canVerifyWithLocation(tracker: Tracker, facts: ConditionFacts, now: Date) -> Bool {
        let places = neededLeaves(tracker: tracker, facts: facts, now: now).filter { $0.place != nil }
        guard !places.isEmpty else { return false }
        var optimistic = facts
        for place in places { optimistic.places[place.id] = .met }
        return status(tracker: tracker, facts: optimistic, now: now).state == .met
    }
}

nonisolated extension AchievementCondition {
    var isSleep: Bool { if case .sleep = payload { true } else { false } }
    var healthKey: HealthFactKey? {
        switch payload {
        case .steps(let value): HealthFactKey(metric: .steps, window: value.window)
        case .sleep(let value): HealthFactKey(metric: .sleep, window: value.window)
        default: nil
        }
    }
}

@MainActor enum RecordConditions {
    static func verify(tracker: Tracker) async throws {
        try Task.checkCancellation()
        guard tracker.requiresConditionGate else { return }
        if let fixture = previewFixture(tracker: tracker) {
            try ConditionEvaluation.requireMet(ConditionEvaluation.status(tracker: tracker, facts: fixture, now: Date()).state)
            return
        }
        var facts = ConditionFacts()
        var now = Date()
        if ConditionEvaluation.status(tracker: tracker, facts: facts, now: now).state != .unknown {
            try ConditionEvaluation.requireMet(ConditionEvaluation.status(tracker: tracker, facts: facts, now: now).state)
            return
        }
        let keys = Set(ConditionEvaluation.neededLeaves(tracker: tracker, facts: facts, now: now).compactMap(\.healthKey))
        facts.health = try await HealthConditions.shared.read(keys: keys, tracker: tracker, now: now)
        try Task.checkCancellation()
        now = Date()
        if ConditionEvaluation.canVerifyWithLocation(tracker: tracker, facts: facts, now: now) {
            let request = ConditionFixRequest(tracker: tracker, facts: facts, precise: true)
            facts.fix = try await request.acquire()
        }
        try Task.checkCancellation()
        try ConditionEvaluation.requireMet(ConditionEvaluation.status(tracker: tracker, facts: facts, now: Date()).state)
    }
    static func status(tracker: Tracker, now: Date = Date(), facts: ConditionFacts = ConditionFacts()) -> ConditionStatus {
        ConditionEvaluation.status(tracker: tracker, facts: previewFixture(tracker: tracker) ?? facts, now: now)
    }
    static func previewFixture(tracker: Tracker) -> ConditionFacts? {
        #if DEBUG && targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--uitesting"), let argument = args.first(where: { $0.hasPrefix("--condition-gate=") }) {
            let value = String(argument.dropFirst("--condition-gate=".count))
            let state: ConditionState = value == "met" ? .met : value == "unmet" ? .unmet : .unknown
            var facts = ConditionFacts()
            for condition in tracker.resolvedConditionGroups.flatMap(\.conditions) { facts.fixtureStates[condition.id] = state }
            return facts
        }
        #endif
        return nil
    }
    static func checkLocation(tracker: Tracker) async throws -> CLLocation {
        try await ConditionFixRequest(tracker: tracker, facts: ConditionFacts(), precise: false).acquire()
    }
    static func checkAuthorizedLocation(tracker: Tracker) async throws -> CLLocation? {
        try Task.checkCancellation()
        let permission = CLLocationManager()
        guard CLLocationManager.locationServicesEnabled(),
              permission.authorizationStatus == .authorizedWhenInUse || permission.authorizationStatus == .authorizedAlways else { return nil }
        return try await ConditionFixRequest(tracker: tracker, facts: ConditionFacts(), precise: false, requestPermission: false).acquire()
    }
}

@MainActor private final class ConditionFixRequest: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let tracker: Tracker
    private let facts: ConditionFacts
    private let precise: Bool
    private let requestPermission: Bool
    private var manager: CLLocationManager?
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var timeout: Task<Void, Never>?
    private var accuracyRequest: Task<Void, Never>?
    private var started = false
    private var requestedAccuracy = false
    private var requestedWhenInUse = false
    init(tracker: Tracker, facts: ConditionFacts, precise: Bool, requestPermission: Bool = true) {
        self.tracker = tracker; self.facts = facts; self.precise = precise; self.requestPermission = requestPermission
    }
    func acquire() async throws -> CLLocation {
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
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
            guard requestPermission else {
                finish(.failure(ConditionError("Check your current location to evaluate this condition."))); return
            }
            if !requestedWhenInUse { requestedWhenInUse = true; manager.requestWhenInUseAuthorization() }
        case .restricted, .denied:
            finish(.failure(ConditionError("Location access is denied. Enable it in iPhone Settings to verify your conditions.")))
        case .authorizedAlways, .authorizedWhenInUse:
            if precise && started && manager.accuracyAuthorization != .fullAccuracy {
                finish(.failure(ConditionError("Precise Location is required to verify these 200 m conditions."))); return
            }
            guard !started, accuracyRequest == nil else { return }
            if precise && manager.accuracyAuthorization == .reducedAccuracy {
                guard !requestedAccuracy else {
                    finish(.failure(ConditionError("Precise Location is required to verify these 200 m conditions."))); return
                }
                requestedAccuracy = true
                accuracyRequest = Task { [weak self, weak manager] in
                    guard let self, let manager else { return }
                    do { try await manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "GoalookerCondition") }
                    catch { self.finish(.failure(ConditionError("Could not check your current location. Try again."))); return }
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
                self.finish(.failure(ConditionError("Your current location is uncertain or stale. Try checking again.")))
            }
        @unknown default: finish(.failure(ConditionError("Could not check your current location. Try again.")))
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { advance(manager) }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard self.manager === manager, started, (!precise || manager.accuracyAuthorization == .fullAccuracy), let fix = locations.last else { return }
        let now = Date()
        guard (-5...60).contains(now.timeIntervalSince(fix.timestamp)), fix.horizontalAccuracy.isFinite,
              fix.horizontalAccuracy >= 0, CLLocationCoordinate2DIsValid(fix.coordinate) else { return }
        var candidate = facts; candidate.fix = fix
        // Preview returns the uncertainty band; save keeps improving an undecidable fix for at most eight seconds.
        if !precise || !ConditionEvaluation.neededLeaves(tracker: tracker, facts: candidate, now: now).contains(where: { $0.place != nil }) {
            finish(.success(fix))
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard self.manager === manager else { return }
        if (error as? CLError)?.code == .locationUnknown { return }
        finish(.failure(ConditionError("Could not check your current location. Try again.")))
    }
    private func finish(_ result: Result<CLLocation, Error>) {
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
nonisolated struct ConditionRegionFact {
    let inside: ConditionState
    let date: Date
}
nonisolated enum ConditionPlan {
    static func facts(_ tracker: Tracker, regions: [String: ConditionRegionFact], now: Date) -> ConditionFacts {
        var result = ConditionFacts()
        for condition in tracker.resolvedConditionGroups.flatMap(\.conditions) {
            guard let place = condition.place else { continue }
            result.places[condition.id] = regions[ConditionCenter(place.location).identifier].map {
                state(inside: $0.inside, date: $0.date, relation: place.relation, now: now)
            } ?? .unknown
        }
        return result
    }
    static func mayNotify(transition: Bool, eventState: ConditionState, eventDate: Date, now: Date,
                          enabled: Bool, authorized: Bool) -> Bool {
        transition && enabled && authorized && eventState != .unknown && (-5...60).contains(now.timeIntervalSince(eventDate))
    }
    static func eligible(_ trackers: [Tracker]) -> [Tracker] {
        trackers.filter { !$0.archived && $0.remindWhenMet == true && $0.supportsConditionReminders }
    }
    static func centers(_ trackers: [Tracker]) throws -> Set<ConditionCenter> {
        guard !trackers.contains(where: { !$0.archived && $0.remindWhenMet == true && !$0.supportsConditionReminders }) else {
            throw ConditionError("Condition reminders need a place and cannot include health conditions. Use Time and weekdays for scheduled reminders.")
        }
        let conditions = eligible(trackers).flatMap(\.resolvedConditions)
        guard conditions.allSatisfy({ $0.location.isValid }) else { throw ConditionError("Choose a valid place for every condition.") }
        let result = Set(conditions.map { ConditionCenter($0.location) })
        guard result.count <= 20 else { throw ConditionError("Location reminders support up to 20 different places. Remove a place or disable a location reminder.") }
        return result
    }
    static func signature(_ tracker: Tracker) -> String {
        let groups = tracker.resolvedConditionGroups.map { group in
            let leaves = group.conditions.map { condition -> String in
                let payload: String
                switch condition.payload {
                case .place(let p): payload = "place:\(p.location.latitude):\(p.location.longitude):\(p.relation.rawValue)"
                case .time(let t): payload = "time:\(t.startMinute):\(t.endMinute)"
                case .weekdays(let days): payload = "weekdays:" + days.sorted().map(String.init).joined(separator: ",")
                case .steps(let t): payload = "steps:\(t.comparison.rawValue):\(t.threshold):\(t.window.rawValue)"
                case .sleep(let t): payload = "sleep:\(t.comparison.rawValue):\(t.threshold):\(t.window.rawValue)"
                }
                return condition.id.uuidString + ":" + payload
            }.sorted().joined(separator: "|")
            return group.id.uuidString + ":" + group.combination.rawValue + "[" + leaves + "]"
        }.sorted().joined(separator: "|")
        return ConditionCenter.hash("groups-v3:" + tracker.timeZoneID + ":" + tracker.resolvedOuterCombination.rawValue + "|" + groups)
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
