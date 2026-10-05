import Foundation
import HealthKit

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

// Read-only, on-demand Health access. No observers, background delivery, disk cache or shared data.
@MainActor final class HealthConditions {
    static let shared = HealthConditions()
    private let store = HKHealthStore()

    func connect(tracker: Tracker) async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw ConditionError("Apple Health is unavailable on this device.")
        }
        let keys = Set(tracker.resolvedConditionGroups.flatMap(\.conditions).compactMap(\.healthKey))
        guard !keys.isEmpty else { return }
        try await store.requestAuthorization(toShare: [], read: types(keys))
        try Task.checkCancellation()
        // Successful request means the permission sheet was processed, not that reading was granted.
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
                    fact.issue = "Connect Apple Health to read the data used by this condition."; facts[key] = fact; continue
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
                if fact.value == nil { fact.issue = "No readable data for this period. Check access in Apple Health." }
            } catch is CancellationError { throw CancellationError() }
            catch {
                fact.issue = (error as? HKError)?.code == .errorDatabaseInaccessible
                    ? "Unlock this iPhone to read Apple Health data."
                    : "Could not read Apple Health data. Try refreshing."
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
