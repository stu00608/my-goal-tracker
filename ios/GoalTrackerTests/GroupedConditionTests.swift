import Foundation
import HealthKit
import Testing
@testable import GoalTracker

@MainActor private final class HistoryAuthorizationFixture: NSObject {
    let dates: NSDictionary?
    let error: NSError?
    var requested = Set<HKObjectType>()
    init(dates: NSDictionary?, error: NSError? = nil) { self.dates = dates; self.error = error }
    @objc(getEarliestAuthorizedSampleDateForTypes:completion:)
    func readHistory(_ types: NSSet, completion: @escaping @convention(block) (NSDictionary?, NSError?) -> Void) {
        requested = types as? Set<HKObjectType> ?? []
        completion(dates, error)
    }
}

@MainActor struct GroupedConditionTests {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func tracker(_ groups: [ConditionGroup], outer: ConditionCombination = .all, zone: String = "UTC") -> Tracker {
        var t = Tracker(name: "Grouped", kind: .daily)
        t.timeZoneID = zone; t.conditionGroups = groups; t.outerCombination = outer; t.gateSave = true
        return t
    }
    private func place(_ name: String = "Place", latitude: Double = 0) -> AchievementCondition {
        AchievementCondition(payload: .place(PlaceCondition(name: name, location: RecordedLocation(latitude: latitude, longitude: 0))))
    }
    private func health(_ metric: HealthMetric = .steps, comparison: ThresholdComparison = .greater,
                        threshold: String = "5000", window: HealthWindow = .day) -> AchievementCondition {
        let value = HealthThreshold(comparison: comparison, threshold: threshold, window: window)
        return AchievementCondition(payload: metric == .steps ? .steps(value) : .sleep(value))
    }

    @Test func nestedTruthTablesPreserveGroupPrecedenceAndUnknown() {
        let values: [ConditionState] = [.met, .unmet, .unknown]
        let all: [[ConditionState]] = [[.met, .unmet, .unknown], [.unmet, .unmet, .unmet], [.unknown, .unmet, .unknown]]
        let any: [[ConditionState]] = [[.met, .met, .met], [.met, .unmet, .unknown], [.met, .unknown, .unknown]]
        let a = place("A"), b = place("B"), c = place("C")
        for inner in ConditionCombination.allCases {
            for outer in ConditionCombination.allCases {
                let t = tracker([ConditionGroup(combination: inner, conditions: [a, b]), ConditionGroup(conditions: [c])], outer: outer)
                for i in 0..<3 { for j in 0..<3 { for k in 0..<3 {
                    let facts = ConditionFacts(places: [a.id: values[i], b.id: values[j], c.id: values[k]])
                    let first = (inner == .all ? all : any)[i][j]
                    let row = values.firstIndex(of: first)!
                    let expected = (outer == .all ? all : any)[row][k]
                    let result = RecordConditions.status(tracker: t, now: date("2026-10-05T12:00:00Z"), facts: facts)
                    #expect(result.state == expected)
                    #expect(result.groups[0].state == first && result.groups[1].state == values[k])
                    #expect(result.groups[0].leaves.count == 2)
                } } }
            }
        }
    }

    @Test func cheapDecisiveBranchesNeedNoHealthOrLocation() async throws {
        let clock = AchievementCondition(payload: .time(TimeCondition(startMinute: 0, endMinute: 0)))
        let t = tracker([ConditionGroup(combination: .any, conditions: [clock, health(), place()])])
        #expect(ConditionEvaluation.neededLeaves(tracker: t, facts: ConditionFacts(), now: Date()).isEmpty)
        try await RecordConditions.verify(tracker: t)
        let never = AchievementCondition(payload: .weekdays([]))
        let unknown = tracker([ConditionGroup(conditions: [never])])
        #expect(RecordConditions.status(tracker: unknown).state == .unknown)
    }

    @Test func onlyUnresolvedGroupsAcquireDeduplicatedMetricWindows() {
        let allDay = AchievementCondition(payload: .time(TimeCondition(startMinute: 1, endMinute: 1)))
        let a = health(), b = health(comparison: .less, threshold: "10000"), week = health(window: .week)
        let t = tracker([ConditionGroup(combination: .any, conditions: [allDay, health(.sleep)]), ConditionGroup(conditions: [a, b, week])])
        let needed = ConditionEvaluation.neededLeaves(tracker: t, facts: ConditionFacts(), now: Date())
        #expect(Set(needed.map(\.id)) == Set([a.id, b.id, week.id]))
        #expect(Set(needed.compactMap(\.healthKey)).count == 2)
        let p = place(), h = health()
        let requiredHealth = tracker([ConditionGroup(conditions: [p, h])])
        #expect(!ConditionEvaluation.canVerifyWithLocation(tracker: requiredHealth, facts: ConditionFacts(), now: Date()))
        #expect(ConditionEvaluation.canVerifyWithLocation(tracker: requiredHealth, facts: ConditionFacts(), now: Date(), forSaving: true))
        let optionalHealth = tracker([ConditionGroup(combination: .any, conditions: [p, h])])
        #expect(ConditionEvaluation.canVerifyWithLocation(tracker: optionalHealth, facts: ConditionFacts(), now: Date()))
        #expect(!ConditionEvaluation.canVerifyWithLocation(tracker: optionalHealth, facts: ConditionFacts(), now: Date(), forSaving: true))
    }

    @Test func inclusiveMinutesAllDayAndOvernightUseCurrentWeekday() {
        let window = TimeCondition(startMinute: 22 * 60, endMinute: 2 * 60)
        let monday = AchievementCondition(payload: .weekdays([2]))
        let t = tracker([ConditionGroup(conditions: [AchievementCondition(payload: .time(window)), monday])])
        for instant in ["2026-10-05T22:00:00Z", "2026-10-05T23:59:59Z", "2026-10-05T02:00:59Z"] {
            #expect(RecordConditions.status(tracker: t, now: date(instant)).state == .met)
        }
        #expect(RecordConditions.status(tracker: t, now: date("2026-10-06T00:01:00Z")).state == .unmet)
        #expect(ConditionEvaluation.time(window, calendar: t.calendar, now: date("2026-10-05T02:01:00Z")) == .unmet)
        #expect(ConditionEvaluation.time(TimeCondition(startMinute: 500, endMinute: 500), calendar: t.calendar, now: date("2026-10-05T04:00:00Z")) == .met)
        #expect(ConditionEvaluation.time(TimeCondition(startMinute: -1, endMinute: 0), calendar: t.calendar, now: Date()) == .unknown)
    }

    @Test func trackerTimezoneAndDSTUseWallClockInsteadOfSecondsSinceMidnight() {
        let time = AchievementCondition(payload: .time(TimeCondition(startMinute: 540, endMinute: 540 + 1)))
        let tokyo = tracker([ConditionGroup(conditions: [time])], zone: "Asia/Tokyo")
        #expect(RecordConditions.status(tracker: tokyo, now: date("2026-10-05T00:00:00Z")).state == .met)
        let newYork = tracker([], zone: "America/New_York")
        let spring = TimeCondition(startMinute: 90, endMinute: 150)
        #expect(ConditionEvaluation.time(spring, calendar: newYork.calendar, now: date("2026-03-08T06:59:00Z")) == .met)
        #expect(ConditionEvaluation.time(spring, calendar: newYork.calendar, now: date("2026-03-08T07:00:00Z")) == .unmet)
        let fall = TimeCondition(startMinute: 90, endMinute: 91)
        for instant in ["2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z"] {
            #expect(ConditionEvaluation.time(fall, calendar: newYork.calendar, now: date(instant)) == .met)
        }
    }

    @Test func calendarWindowsRemainMondayBasedIndependentOfWeekdayDisplayOrder() {
        let t = tracker([], zone: "Asia/Tokyo"), now = date("2026-10-07T13:00:00Z")
        #expect(HealthConditionEvaluation.start(window: .day, calendar: t.calendar, now: now) == date("2026-10-06T15:00:00Z"))
        #expect(HealthConditionEvaluation.start(window: .week, calendar: t.calendar, now: now) == date("2026-10-04T15:00:00Z"))
        #expect(HealthConditionEvaluation.start(window: .month, calendar: t.calendar, now: now) == date("2026-09-30T15:00:00Z"))
        #expect(WeekdayOrder.days(starting: 1) == [1, 2, 3, 4, 5, 6, 7])
        #expect(WeekdayOrder.days(starting: 2) == [2, 3, 4, 5, 6, 7, 1])
        #expect(t.calendar.firstWeekday == 2)
    }

    @Test func sleepUnionsOverlapsAdjacencyAndSourcesBeforeWakeDayAssignment() {
        let start = date("2026-10-05T00:00:00Z"), end = date("2026-10-05T05:00:00Z")
        func sample(_ a: Double, _ b: Double, _ category: HKCategoryValueSleepAnalysis) -> ConditionSleepSample {
            ConditionSleepSample(start: start.addingTimeInterval(a * 3600), end: start.addingTimeInterval(b * 3600), category: category.rawValue)
        }
        let spans = [sample(-2, 1, .asleepUnspecified), sample(0.5, 1.5, .asleepCore), sample(1.5, 2, .asleepDeep),
                     sample(1.75, 4, .asleepREM), sample(-2, 5, .inBed), sample(2, 3, .awake)]
        #expect(HealthConditionEvaluation.sleepSeconds(spans, start: start, end: end) == Decimal(21_600))
        #expect(HealthConditionEvaluation.sleepSeconds(Array(spans.reversed()), start: start, end: end) == Decimal(21_600))
        #expect(HealthConditionEvaluation.sleepSeconds(spans, start: start, end: start.addingTimeInterval(3 * 3600)) == nil)
        #expect(HealthConditionEvaluation.sleepSeconds([sample(-2, 0, .asleepCore)], start: start, end: end) == 7200)
        #expect(HealthConditionEvaluation.sleepSeconds([sample(-2, 0, .asleepCore)], start: start, end: start) == 7200)
        #expect(HealthConditionEvaluation.sleepSeconds([sample(-2, -1, .asleepCore)], start: start, end: end) == nil)
        #expect(HealthConditionEvaluation.sleepSeconds([sample(0, 3, .inBed), sample(0, 3, .awake)], start: start, end: end) == nil)
        #expect(HealthConditionEvaluation.sleepSeconds([], start: start, end: end) == nil)
    }

    @Test func overnightAndNapBelongToWakeDay() {
        let start = date("2026-10-05T00:00:00Z"), end = date("2026-10-05T18:00:00Z")
        let night = ConditionSleepSample(start: date("2026-10-04T23:00:00Z"), end: date("2026-10-05T07:00:00Z"), category: HKCategoryValueSleepAnalysis.asleepCore.rawValue)
        let nap = ConditionSleepSample(start: date("2026-10-05T13:00:00Z"), end: date("2026-10-05T14:00:00Z"), category: HKCategoryValueSleepAnalysis.asleepDeep.rawValue)
        #expect(HealthConditionEvaluation.sleepSeconds([night], start: start, end: end) == 28_800)
        #expect(HealthConditionEvaluation.sleepSeconds([night, nap], start: start, end: end) == 32_400)
        #expect(HealthConditionEvaluation.sleepSeconds([night], start: start.addingTimeInterval(-86_400), end: start.addingTimeInterval(-1)) == nil)
    }

    @Test func sleepStagesAcrossMidnightKeepAwakeAndInBedOutOfDuration() {
        let start = date("2026-10-05T00:00:00Z"), end = date("2026-10-05T12:00:00Z")
        let a = ConditionSleepSample(start: date("2026-10-04T23:00:00Z"), end: date("2026-10-04T23:30:00Z"), category: HKCategoryValueSleepAnalysis.asleepCore.rawValue)
        let b = ConditionSleepSample(start: date("2026-10-04T23:45:00Z"), end: date("2026-10-05T07:00:00Z"), category: HKCategoryValueSleepAnalysis.asleepREM.rawValue)
        for bridge in [HKCategoryValueSleepAnalysis.inBed, .awake] {
            let gap = ConditionSleepSample(start: a.end, end: b.start, category: bridge.rawValue)
            #expect(HealthConditionEvaluation.sleepSeconds([a, gap, b], start: start, end: end) == 27_900)
        }
    }

    @Test func sleepWakeDateRespectsWeekMonthTimezoneAndDST() {
        for (zone, wakeText, expectedHours) in [
            ("UTC", "2026-06-01T07:00:00Z", 8), // Monday and month boundary.
            ("Asia/Tokyo", "2026-05-31T22:00:00Z", 8),
            ("America/New_York", "2026-03-08T11:00:00Z", 7)
        ] {
            let t = tracker([], zone: zone), wake = date(wakeText)
            let sleep = ConditionSleepSample(start: wake.addingTimeInterval(Double(-expectedHours * 3600)), end: wake, category: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue)
            for window in HealthWindow.allCases {
                let start = HealthConditionEvaluation.start(window: window, calendar: t.calendar, now: wake)!
                #expect(HealthConditionEvaluation.sleepSeconds([sleep], start: start, end: wake) == Decimal(expectedHours * 3600))
            }
        }
        let wake = date("2026-10-05T00:30:00Z")
        let sleep = ConditionSleepSample(start: wake.addingTimeInterval(-28_800), end: wake, category: HKCategoryValueSleepAnalysis.asleepCore.rawValue)
        let now = date("2026-10-05T12:00:00Z")
        for (zone, expected) in [("UTC", Optional(Decimal(28_800))), ("America/Los_Angeles", nil)] {
            let start = HealthConditionEvaluation.start(window: .day, calendar: tracker([], zone: zone).calendar, now: now)!
            #expect(HealthConditionEvaluation.sleepSeconds([sleep], start: start, end: now) == expected)
        }
    }

    @Test func unavailableHealthAllowsSavingWithoutChangingDisplayedState() throws {
        let now = date("2026-10-05T12:00:00Z")
        for metric in [HealthMetric.steps, .sleep] {
            for window in HealthWindow.allCases {
                let h = health(metric, comparison: .less, threshold: "10", window: window)
                let t = tracker([ConditionGroup(conditions: [h])]), key = h.healthKey!
                let start = HealthConditionEvaluation.start(window: window, calendar: t.calendar, now: now)!
                let unavailable = [HealthFact(start: start, through: now),
                    HealthFact(start: start, through: now, issue: "Could not read Apple Health data."),
                    HealthFact(start: start, through: now.addingTimeInterval(-301), value: 1),
                    HealthFact(start: start, through: now, value: 1, earliestAvailable: start.addingTimeInterval(1))]
                for fact in unavailable {
                    let facts = ConditionFacts(health: [key: fact])
                    let displayed = ConditionEvaluation.status(tracker: t, facts: facts, now: now)
                    #expect(displayed.state == .unknown)
                    #expect(displayed.groups[0].leaves[0].measurement == nil)
                    try ConditionEvaluation.requireMet(ConditionEvaluation.saveState(tracker: t, facts: facts, now: now))
                }
                try ConditionEvaluation.requireMet(ConditionEvaluation.saveState(tracker: t, facts: ConditionFacts(), now: now))
            }
        }
    }

    @Test func limitedHistoryUsesTheRequestedTypeAndEmptyDoesNotAssertPermission() async throws {
        let steps = HKQuantityType(.stepCount), sleep = HKCategoryType(.sleepAnalysis)
        let boundary = date("2026-10-03T00:00:00Z")
        let store = HistoryAuthorizationFixture(dates: [steps: boundary] as NSDictionary)
        #expect(try await HealthConditions.earliestAuthorizedDate(in: store, type: steps) == boundary)
        #expect(store.requested == Set([steps]))
        #expect(try await HealthConditions.earliestAuthorizedDate(in: store, type: sleep) == .distantPast)
        let empty = HistoryAuthorizationFixture(dates: [:])
        #expect(try await HealthConditions.earliestAuthorizedDate(in: empty, type: steps) == .distantPast)
    }

    @Test func historyAuthorizationFailureNeverBecomesFullCoverage() async {
        let steps = HKQuantityType(.stepCount)
        for store in [HistoryAuthorizationFixture(dates: nil),
                      HistoryAuthorizationFixture(dates: [:], error: NSError(domain: HKErrorDomain, code: HKError.Code.errorDatabaseInaccessible.rawValue)),
                      HistoryAuthorizationFixture(dates: [steps: "invalid"])] {
            do {
                _ = try await HealthConditions.earliestAuthorizedDate(in: store, type: steps)
                Issue.record("Missing or failed history coverage must be unavailable")
            } catch { }
        }
    }

    @Test func absentHistoryAPIFailsClosedOnlyOnSystemsWithLimitedAuthorization() async throws {
        if #available(iOS 27, *) {
            do {
                _ = try await HealthConditions.earliestAuthorizedDate(in: NSObject(), type: HKQuantityType(.stepCount))
                Issue.record("A missing iOS 27 history API must not imply full history")
            } catch { }
        } else {
            #expect(try await HealthConditions.earliestAuthorizedDate(in: NSObject(), type: HKQuantityType(.stepCount)) == .distantPast)
        }
    }

    @Test func unavailableHealthPreservesNestedLogicAndExplicitUnmetGate() throws {
        let now = date("2026-10-05T12:00:00Z"), h = health(), p = place()
        for inner in ConditionCombination.allCases {
            for outer in ConditionCombination.allCases {
                let t = tracker([ConditionGroup(combination: inner, conditions: [h, p]), ConditionGroup(conditions: [health(.sleep)])], outer: outer)
                for state: ConditionState in [.met, .unmet, .unknown] {
                    let facts = ConditionFacts(places: [p.id: state])
                    let expected: ConditionState = inner == .any || outer == .any ? .met : state
                    #expect(ConditionEvaluation.saveState(tracker: t, facts: facts, now: now) == expected)
                }
            }
        }
        let t = tracker([ConditionGroup(conditions: [h, health(.sleep)])])
        let facts = ConditionFacts(health: [h.healthKey!: HealthFact(start: t.calendar.startOfDay(for: now), through: now, value: 100)])
        #expect(ConditionEvaluation.status(tracker: t, facts: facts, now: now).state == .unmet)
        #expect(throws: ConditionError.self) {
            try ConditionEvaluation.requireMet(ConditionEvaluation.saveState(tracker: t, facts: facts, now: now))
        }
    }

    @Test func healthThresholdsAreStrictDecimalAndEmptyNeverBecomesZero() {
        let equal = HealthThreshold(comparison: .greater, threshold: "5000", window: .day)
        #expect(HealthConditionEvaluation.compare(Decimal(5000), threshold: equal, metric: .steps) == .unmet)
        #expect(HealthConditionEvaluation.compare(Decimal(5001), threshold: equal, metric: .steps) == .met)
        let less = HealthThreshold(comparison: .less, threshold: "5000", window: .day)
        #expect(HealthConditionEvaluation.compare(Decimal(5000), threshold: less, metric: .steps) == .unmet)
        #expect(HealthConditionEvaluation.compare(nil, threshold: less, metric: .steps) == .unknown)
        #expect(HealthConditionEvaluation.compare(Decimal.zero, threshold: less, metric: .steps) == .met)
        let sleep = HealthThreshold(comparison: .less, threshold: "8.000000000000001", window: .week)
        #expect(HealthConditionEvaluation.compare(Decimal(28_800), threshold: sleep, metric: .sleep) == .met)
        for bad in [Double.nan, .infinity, -1] { #expect(HealthConditionEvaluation.quantity(bad) == nil) }
        #expect(HealthConditionEvaluation.quantity(nil) == nil)
        #expect(HealthConditionEvaluation.quantity(0) == Decimal.zero)
    }

    @Test func rolloverStaleAndFutureHealthFactsRemainUnknown() {
        for window in HealthWindow.allCases {
            let leaf = health(window: window), t = tracker([ConditionGroup(conditions: [leaf])])
            let before = date("2026-11-01T23:59:59Z"), after = date("2026-11-02T00:00:00Z")
            let key = leaf.healthKey!, start = HealthConditionEvaluation.start(window: window, calendar: t.calendar, now: before)!
            let facts = ConditionFacts(health: [key: HealthFact(start: start, through: before, value: 6000)])
            #expect(RecordConditions.status(tracker: t, now: before, facts: facts).state == .met)
            #expect(RecordConditions.status(tracker: t, now: after, facts: facts).state == (window == .month ? .met : .unknown))
            #expect(RecordConditions.status(tracker: t, now: before.addingTimeInterval(301), facts: facts).state == .unknown)
            #expect(RecordConditions.status(tracker: t, now: before.addingTimeInterval(-1), facts: facts).state == .unknown)
        }
        let leaf = health(window: .month), t = tracker([ConditionGroup(conditions: [leaf])]), before = date("2026-10-31T23:59:59Z")
        let key = leaf.healthKey!, start = HealthConditionEvaluation.start(window: .month, calendar: t.calendar, now: before)!
        #expect(RecordConditions.status(tracker: t, now: date("2026-11-01T00:00:00Z"),
            facts: ConditionFacts(health: [key: HealthFact(start: start, through: before, value: 6000)])).state == .unknown)
    }

    @Test func everyLeafReportsUnknownOrLoadingEvenWhenAnotherBranchIsMet() {
        let a = place(), b = health()
        let t = tracker([ConditionGroup(combination: .any, conditions: [a, b])])
        let facts = ConditionFacts(places: [a.id: .met], loadingHealth: [b.healthKey!])
        let result = RecordConditions.status(tracker: t, facts: facts)
        #expect(result.state == .met && !result.loading)
        #expect(result.groups[0].leaves[1].state == .unknown && result.groups[0].leaves[1].loading)
    }

    #if DEBUG && targetEnvironment(simulator)
    @Test func explicitPreviewFixturesEvaluateEveryGroupAndLeafWithoutNativeFacts() {
        let groups = [ConditionGroup(combination: .any, conditions: [place(), health()]),
                      ConditionGroup(conditions: [AchievementCondition(payload: .weekdays([2])), health(.sleep)])]
        for value: ConditionState in [.met, .unmet, .unknown] {
            var facts = ConditionFacts()
            for leaf in groups.flatMap(\.conditions) { facts.fixtureStates[leaf.id] = value }
            let result = ConditionEvaluation.status(tracker: tracker(groups), facts: facts, now: Date())
            #expect(result.state == value)
            #expect(result.groups.allSatisfy { $0.state == value && $0.leaves.allSatisfy { $0.state == value } })
        }
    }
    #endif

    @Test func hundredSaveOnlyPlacesDoNotConsumeNativeMonitorCapacity() throws {
        let groups = (0..<10).map { index in
            ConditionGroup(conditions: (0..<10).map { place("Place \(index)-\($0)", latitude: Double(index * 10 + $0) / 10) })
        }
        var t = tracker(groups)
        try Backup(trackers: [t]).validate()
        #expect(try ConditionPlan.centers([t]).isEmpty)
        t.remindWhenMet = true
        #expect(throws: ConditionError.self) { try ConditionPlan.centers([t]) }
        t.conditionGroups?[0].conditions.append(place("Eleventh"))
        #expect(throws: DataError.self) { try Backup(trackers: [t]).validate() }
    }

    @Test func reminderEligibilityRejectsHealthAndRequiresAPlaceEvenInAnyBranch() throws {
        var t = tracker([ConditionGroup(combination: .any, conditions: [place(), health()])])
        t.remindWhenMet = true
        #expect(!t.supportsConditionReminders && ConditionPlan.eligible([t]).isEmpty)
        #expect(throws: ConditionError.self) { try ConditionPlan.centers([t]) }
        t.conditionGroups = [ConditionGroup(conditions: [AchievementCondition(payload: .weekdays([2]))])]
        #expect(!t.supportsConditionReminders)
        #expect(throws: ConditionError.self) { try ConditionPlan.centers([t]) }
    }

    @Test func nativePlaceFactsRespectFullGroupsAndCurrentTimeFilters() {
        let a = place(), b = place("B", latitude: 1), time = AchievementCondition(payload: .time(TimeCondition(startMinute: 540, endMinute: 600)))
        let t = tracker([ConditionGroup(combination: .any, conditions: [a, b]), ConditionGroup(conditions: [time])])
        let facts = ConditionFacts(places: [a.id: .unmet, b.id: .met])
        #expect(t.supportsConditionReminders)
        #expect(RecordConditions.status(tracker: t, now: date("2026-10-05T09:30:00Z"), facts: facts).state == .met)
        #expect(RecordConditions.status(tracker: t, now: date("2026-10-05T10:01:00Z"), facts: facts).state == .unmet)
        #expect(RecordConditions.status(tracker: t, now: date("2026-10-05T09:30:00Z"), facts: ConditionFacts()).state == .unknown)
        let instant = date("2026-10-05T09:30:00Z")
        let regions = [ConditionCenter(a.place!.location).identifier: ConditionRegionFact(inside: .unmet, date: instant),
                       ConditionCenter(b.place!.location).identifier: ConditionRegionFact(inside: .met, date: instant)]
        #expect(RecordConditions.status(tracker: t, now: instant, facts: ConditionPlan.facts(t, regions: regions, now: instant)).state == .met)
        let old = instant.addingTimeInterval(43_201)
        #expect(ConditionPlan.facts(t, regions: regions, now: old).places.values.allSatisfy { $0 == .unknown })
    }

    @Test func configurationSignaturesIncludeParametersStructureTimezoneButNotNames() {
        let a = place(), b = health(), time = AchievementCondition(payload: .time(TimeCondition(startMinute: 0, endMinute: 1)))
        let original = tracker([ConditionGroup(conditions: [a, b, time])]), signature = ConditionPlan.signature(original)
        var t = original; t.conditionGroups?[0].name = "Renamed"; t.conditionGroups?[0].conditions.reverse()
        #expect(ConditionPlan.signature(t) == signature)
        t = original; t.conditionGroups?[0].combination = .any; #expect(ConditionPlan.signature(t) != signature)
        t = original; t.outerCombination = .any; #expect(ConditionPlan.signature(t) != signature)
        t = original; t.timeZoneID = "Asia/Tokyo"; #expect(ConditionPlan.signature(t) != signature)
        t = original; t.conditionGroups?[0].conditions[2].payload = .time(TimeCondition(startMinute: 1, endMinute: 2))
        #expect(ConditionPlan.signature(t) != signature)
        t = original; t.conditionGroups?[0].conditions[1] = health(window: .week); #expect(ConditionPlan.signature(t) != signature)
        t = original; t.conditionGroups = [ConditionGroup(conditions: [a]), ConditionGroup(conditions: [b, time])]
        #expect(ConditionPlan.signature(t) != signature)
    }

    @Test func legacyTwentyPlacesMigrateWithCombinationAndStableLeafIdentity() throws {
        var t = Tracker(name: "Legacy", kind: .daily)
        t.conditions = (0..<20).map { PlaceCondition(name: "\($0)", location: RecordedLocation(latitude: Double($0), longitude: 0)) }
        t.conditionCombination = .any; t.gateSave = true
        let ids = t.conditions!.map(\.id)
        t.migrateConditions()
        #expect(t.conditions == nil && t.conditionCombination == nil)
        #expect(t.resolvedConditionGroups.count == 2 && t.resolvedOuterCombination == .any)
        #expect(t.resolvedConditionGroups.allSatisfy { $0.combination == .any })
        #expect(t.resolvedConditionGroups.flatMap(\.conditions).map(\.id) == ids)
        #expect(try Backup.decode(Backup(trackers: [t]).encoded()).trackers == [t])
    }
    @Test @MainActor func healthConditionChoicesFollowGlobalSetup() {
        for state in [HealthAccessSetup.checking, .requestNeeded, .unavailable] {
            let access = HealthConditionAccess(steps: state, sleep: state)
            #expect(ConditionLeafKind.available(healthAccess: access) == [.place, .time, .weekdays])
            #expect(access.needsConnection == (state == .requestNeeded))
        }
        let ready = HealthConditionAccess(steps: .requested, sleep: .requested)
        #expect(ConditionLeafKind.available(healthAccess: ready) == ConditionLeafKind.allCases)
        for access in [HealthConditionAccess(steps: .requested, sleep: .requestNeeded), HealthConditionAccess(steps: .requestNeeded, sleep: .requested)] {
            #expect(!access.needsConnection)
            #expect(ConditionLeafKind.available(healthAccess: access) == [.place, .time, .weekdays, access.steps == .requested ? .steps : .sleep])
        }
    }

}
