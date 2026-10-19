import Foundation
import HealthKit
import Observation

nonisolated enum HealthMetric: String, Hashable { case steps, sleep }
nonisolated struct HealthFactKey: Hashable {
    let metric: HealthMetric
    let window: HealthWindow
}
nonisolated struct HealthFact {
    let start: Date
    let through: Date
    var value: Decimal? // Steps, or sleep seconds. Never rounded for comparison.
    var issue: String?
    var earliestAvailable: Date = .distantPast
}
nonisolated struct ConditionSleepSample {
    let start: Date
    let end: Date
    let category: Int
}
nonisolated enum HealthConditionEvaluation {
    static func start(window: HealthWindow, calendar: Calendar, now: Date) -> Date? {
        switch window {
        case .day: calendar.startOfDay(for: now)
        case .week: calendar.dateInterval(of: .weekOfYear, for: now)?.start
        case .month: calendar.dateInterval(of: .month, for: now)?.start
        }
    }
    static func compare(_ value: Decimal?, threshold: HealthThreshold, metric: HealthMetric) -> ConditionState {
        guard let value, !value.isNaN, value >= 0,
              Numbers.isCanonical(threshold.threshold), var target = Numbers.decimal(threshold.threshold), !target.isNaN, target >= 0 else { return .unknown }
        if metric == .sleep { target *= 3600 }
        return (threshold.comparison == .greater ? value > target : value < target) ? .met : .unmet
    }
    static func quantity(_ value: Double?) -> Decimal? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        let result = Decimal(value)
        return result.isNaN ? nil : result
    }
    static func sleepSeconds(_ samples: [ConditionSleepSample], start: Date, end: Date) -> Decimal? {
        guard start <= end else { return nil }
        let asleep = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))
        let intervals = samples.filter { sample in
            (asleep.contains(sample.category) || sample.category == HKCategoryValueSleepAnalysis.inBed.rawValue
                || sample.category == HKCategoryValueSleepAnalysis.awake.rawValue)
                && sample.start.timeIntervalSince1970.isFinite && sample.end.timeIntervalSince1970.isFinite
                && sample.start < sample.end
        }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        guard let first = intervals.first else { return nil }
        var sessionEnd = first.end
        var wake: Date?
        var seconds = Decimal.zero
        var total: Decimal?
        func include() {
            if let wake, wake >= start && wake <= end { total = (total ?? 0) + seconds }
        }
        for interval in intervals {
            if interval.start > sessionEnd {
                include()
                wake = nil; seconds = 0
            }
            sessionEnd = max(sessionEnd, interval.end)
            // inBed/awake can connect sleep stages, but never add to asleep duration.
            if asleep.contains(interval.category) {
                let uncoveredStart = max(interval.start, wake ?? interval.start)
                if interval.end > uncoveredStart { seconds += Decimal(interval.end.timeIntervalSince(uncoveredStart)) }
                wake = max(wake ?? interval.end, interval.end)
            }
        }
        include()
        return total
    }
}

nonisolated enum HealthAccessSetup: Equatable { case checking, requestNeeded, requested, unavailable }

nonisolated struct HealthConditionAccess {
    var steps = HealthAccessSetup.checking
    var sleep = HealthAccessSetup.checking
    var needsConnection: Bool {
        steps != .requested && sleep != .requested && (steps == .requestNeeded || sleep == .requestNeeded)
    }
}

// Read-only, foreground subscriptions. No background delivery or persisted health facts.
@MainActor @Observable final class HealthConditions {
    static let shared = HealthConditions()
    static let supportedKeys: Set<HealthFactKey> = [
        HealthFactKey(metric: .steps, window: .day), HealthFactKey(metric: .sleep, window: .day)
    ]
    private let store = HKHealthStore()
    private(set) var revision = 0
    @ObservationIgnored private var fixtureRequestedMetrics: Set<HealthMetric> = []
    @ObservationIgnored private var observers: [UUID: [HKObserverQuery]] = [:]

    func setup(keys: Set<HealthFactKey>) async throws -> HealthAccessSetup {
        guard !keys.isEmpty else { return .unavailable }
        #if DEBUG && targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--uitesting"), let flag = args.first(where: { $0.hasPrefix("--health-setup=") }) {
            var processed = fixtureRequestedMetrics
            if flag.hasSuffix("steps-only") { processed.insert(.steps) }
            if flag.hasSuffix("needed") || flag.hasSuffix("steps-only") {
                return Set(keys.map(\.metric)).isSubset(of: processed) ? .requested : .requestNeeded
            }
            return .requested
        }
        #endif
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let status = try await store.statusForAuthorizationRequest(toShare: [], read: types(keys))
        try Task.checkCancellation()
        switch status { case .shouldRequest: return .requestNeeded; case .unnecessary: return .requested; default: return .requestNeeded }
    }
    func conditionAccess() async throws -> HealthConditionAccess {
        // Each type fails independently so a sleep query error cannot hide configured steps.
        let steps = (try? await setup(keys: [HealthFactKey(metric: .steps, window: .day)])) ?? .requestNeeded
        try Task.checkCancellation()
        let sleep = (try? await setup(keys: [HealthFactKey(metric: .sleep, window: .day)])) ?? .requestNeeded
        return HealthConditionAccess(steps: steps, sleep: sleep)
    }
    func observe(keys: Set<HealthFactKey>, owner: UUID) {
        stopObserving(owner: owner)
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let queries = types(keys).compactMap { $0 as? HKSampleType }.map { type in
            HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                defer { completion() }
                guard error == nil else { return }
                Task { @MainActor in
                    guard let self, self.observers[owner] != nil else { return }
                    self.revision &+= 1
                }
            }
        }
        observers[owner] = queries
        for query in queries { store.execute(query) }
    }
    func stopObserving(owner: UUID) {
        for query in observers.removeValue(forKey: owner) ?? [] { store.stop(query) }
    }

    func connect(tracker: Tracker) async throws {
        try await connect(keys: Set(tracker.resolvedConditionGroups.flatMap(\.conditions).compactMap(\.healthKey)))
    }
    func connect(keys: Set<HealthFactKey>) async throws {
        guard !keys.isEmpty else { return }
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--uitesting"), ProcessInfo.processInfo.arguments.contains(where: { $0 == "--health-setup=needed" || $0 == "--health-setup=steps-only" }) {
            fixtureRequestedMetrics.formUnion(keys.map(\.metric)); revision &+= 1; return
        }
        #endif
        guard HKHealthStore.isHealthDataAvailable() else { throw ConditionError("Apple Health is unavailable on this device.") }
        try await store.requestAuthorization(toShare: [], read: types(keys))
        try Task.checkCancellation()
        revision &+= 1
        // Sheet processed does not mean reading was granted.
    }

    func read(keys: Set<HealthFactKey>, tracker: Tracker, now: Date) async throws -> [HealthFactKey: HealthFact] {
        try Task.checkCancellation()
        guard !keys.isEmpty else { return [:] }
        var facts: [HealthFactKey: HealthFact] = [:]
        for key in keys.sorted(by: { ($0.metric.rawValue, $0.window.rawValue) < ($1.metric.rawValue, $1.window.rawValue) }) {
            try Task.checkCancellation()
            guard let start = HealthConditionEvaluation.start(window: key.window, calendar: tracker.calendar, now: now) else { continue }
            var fact = HealthFact(start: start, through: now)
            guard HKHealthStore.isHealthDataAvailable() else {
                fact.issue = "Apple Health is unavailable on this device."; facts[key] = fact; continue
            }
            do {
                // This is a sheet-needed check, never a read-permission check. It cannot prompt.
                let request = try await store.statusForAuthorizationRequest(toShare: [], read: types([key]))
                guard request == .unnecessary else {
                    fact.issue = "Connect Apple Health in Settings."; facts[key] = fact; continue
                }
                try Task.checkCancellation()
                let type: HKObjectType = key.metric == .steps ? HKQuantityType(.stepCount) : HKCategoryType(.sleepAnalysis)
                fact.earliestAvailable = max(store.earliestPermittedSampleDate(),
                    try await Self.earliestAuthorizedDate(in: store, type: type))
                guard fact.earliestAvailable <= start else {
                    fact.issue = "Health data is unavailable for the full period."; facts[key] = fact; continue
                }
                try Task.checkCancellation()
                let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: [])
                switch key.metric {
                case .steps:
                    let descriptor = HKStatisticsQueryDescriptor(
                        predicate: .quantitySample(type: HKQuantityType(.stepCount), predicate: predicate), options: .cumulativeSum)
                    let statistics = try await descriptor.result(for: store)
                    fact.value = HealthConditionEvaluation.quantity(statistics?.sumQuantity()?.doubleValue(for: .count()))
                case .sleep:
                    var queryStart = start.addingTimeInterval(-1) // Include sleep ending exactly at midnight.
                    while true {
                        try Task.checkCancellation()
                        guard fact.earliestAvailable <= queryStart else {
                            fact.issue = "Health data is unavailable for the full period."; break
                        }
                        let sleepPredicate = HKQuery.predicateForSamples(withStart: queryStart, end: now, options: [])
                        let descriptor = HKSampleQueryDescriptor(
                            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: sleepPredicate)],
                            sortDescriptors: [SortDescriptor(\HKCategorySample.startDate)])
                        let samples = try await descriptor.result(for: store)
                        // Include earlier adjoining stages before assigning the whole sleep to its wake day.
                        if let earliest = samples.map(\.startDate).min(), earliest <= queryStart {
                            queryStart = earliest.addingTimeInterval(-1)
                            continue
                        }
                        let spans = samples.map { ConditionSleepSample(start: $0.startDate, end: $0.endDate, category: $0.value) }
                        fact.value = HealthConditionEvaluation.sleepSeconds(spans, start: start, end: now)
                        break
                    }
                }
                if fact.value == nil && fact.issue == nil { fact.issue = "No readable samples yet in this period. Apple Health does not distinguish an empty period from disabled read access." }
            } catch is CancellationError { throw CancellationError() }
            catch {
                fact.issue = (error as? HKError)?.code == .errorDatabaseInaccessible
                    ? "Unlock this iPhone to read Apple Health data."
                    : "Could not read Apple Health data. It will update automatically when available."
            }
            try Task.checkCancellation()
            facts[key] = fact
        }
        return facts
    }
    static func earliestAuthorizedDate(in store: NSObject, type: HKObjectType) async throws -> Date {
        // shortcut: Xcode 26 lacks this public iOS 27 API; use its typed call when the SDK is upgraded.
        let selector = NSSelectorFromString("getEarliestAuthorizedSampleDateForTypes:completion:")
        guard store.responds(to: selector) else {
            if #available(iOS 27, *) { throw ConditionError("Health data is unavailable for the full period.") }
            return .distantPast
        }
        return try await withCheckedThrowingContinuation { continuation in
            let completion: @convention(block) @Sendable (NSDictionary?, NSError?) -> Void = { dates, error in
                if let error { continuation.resume(throwing: error) }
                else if let dates = dates as? [HKObjectType: Date] {
                    // No entry means full OR denied access, never proof of permission.
                    continuation.resume(returning: dates[type] ?? .distantPast)
                } else { continuation.resume(throwing: ConditionError("Health data is unavailable for the full period.")) }
            }
            _ = store.perform(selector, with: Set([type]) as NSSet, with: completion)
        }
    }
    private func types(_ keys: Set<HealthFactKey>) -> Set<HKObjectType> {
        Set(keys.map { key -> HKObjectType in
            switch key.metric {
            case .steps: HKQuantityType(.stepCount)
            case .sleep: HKCategoryType(.sleepAnalysis)
            }
        })
    }
}
