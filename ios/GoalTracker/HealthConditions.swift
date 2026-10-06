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
        guard start < end else { return nil }
        let asleep = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))
        let intervals = samples.compactMap { sample -> DateInterval? in
            guard asleep.contains(sample.category), sample.start.timeIntervalSince1970.isFinite,
                  sample.end.timeIntervalSince1970.isFinite, sample.start < sample.end else { return nil }
            let a = max(start, sample.start), b = min(end, sample.end)
            return a < b ? DateInterval(start: a, end: b) : nil
        }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        guard var current = intervals.first else { return nil } // Empty/hidden is unknown, never zero.
        var total = Decimal.zero
        for interval in intervals.dropFirst() {
            if interval.start <= current.end {
                current = DateInterval(start: current.start, end: max(current.end, interval.end))
            } else {
                total += Decimal(current.duration)
                current = interval
            }
        }
        return total + Decimal(current.duration)
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
                let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: [])
                switch key.metric {
                case .steps:
                    let descriptor = HKStatisticsQueryDescriptor(
                        predicate: .quantitySample(type: HKQuantityType(.stepCount), predicate: predicate), options: .cumulativeSum)
                    let statistics = try await descriptor.result(for: store)
                    fact.value = HealthConditionEvaluation.quantity(statistics?.sumQuantity()?.doubleValue(for: .count()))
                case .sleep:
                    let descriptor = HKSampleQueryDescriptor(
                        predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
                        sortDescriptors: [SortDescriptor(\HKCategorySample.startDate)])
                    let samples = try await descriptor.result(for: store)
                    let spans = samples.map { ConditionSleepSample(start: $0.startDate, end: $0.endDate, category: $0.value) }
                    fact.value = HealthConditionEvaluation.sleepSeconds(spans, start: start, end: now)
                }
                if fact.value == nil { fact.issue = "No readable samples yet in this period. Apple Health does not distinguish an empty period from disabled read access." }
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
    private func types(_ keys: Set<HealthFactKey>) -> Set<HKObjectType> {
        Set(keys.map { key -> HKObjectType in
            switch key.metric {
            case .steps: HKQuantityType(.stepCount)
            case .sleep: HKCategoryType(.sleepAnalysis)
            }
        })
    }
}
