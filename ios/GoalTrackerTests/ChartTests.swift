import Foundation
import Testing
@testable import GoalTracker

@MainActor struct ChartTests {
    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)!
    }
    private func tracker(zone: String = "America/New_York") -> Tracker {
        var tracker = Tracker(name: "Chart", kind: .number)
        tracker.timeZoneID = zone
        return tracker
    }
    private func entry(_ text: String, value: String? = "1", tracker: Tracker) -> Entry {
        let instant = date(text)
        return Entry(occurredAt: instant, localDay: tracker.day(instant), value: value)
    }

    @Test func carriedBaselineInEmptyHistoricalRangePreservesStatisticsAndRawLedger() throws {
        var t = tracker(zone: "UTC")
        let baseline = entry("2024-01-01T12:00:00Z", value: "-10.123456789", tracker: t)
        let outside = entry("2024-01-05T00:00:00Z", value: "99", tracker: t)
        t.entries = [baseline, outside]
        let raw = t.entries, best = t.best
        let snapshot = try #require(ChartRange.custom.snapshot(for: t, now: date("2024-02-01T00:00:00Z"),
                                                              customStart: date("2024-01-02T00:00:00Z"), customEnd: date("2024-01-03T00:00:00Z")))
        #expect(snapshot.entries.isEmpty && snapshot.periodChange == nil)
        let segment = try #require(snapshot.carries.first)
        #expect(snapshot.carries.count == 1 && segment.id == "leading")
        #expect(segment.start.date == snapshot.interval.start && segment.end.date == snapshot.interval.end)
        #expect(segment.start.value == baseline.value && segment.end.value == baseline.value)
        #expect(snapshot.lastRecordedAt == baseline.occurredAt)
        #expect(t.entries == raw && t.best == best && t.latest?.id == outside.id)
        t.entries = [outside]
        #expect(ChartRange.custom.snapshot(for: t, now: date("2024-02-01T00:00:00Z"),
                                          customStart: snapshot.interval.start, customEnd: date("2024-01-03T00:00:00Z"))?.carries.isEmpty == true)
    }

    @Test func carriesUsePriorLeadingBaselineAndNeverExtendIntoFuture() throws {
        var t = tracker(zone: "UTC")
        let now = date("2024-03-10T12:00:00Z")
        t.entries = [entry("2024-03-01T00:00:00Z", value: "10", tracker: t),
                     entry("2024-03-10T10:00:00Z", value: "12", tracker: t),
                     entry("2024-03-11T00:00:00Z", value: "99", tracker: t)]
        let snapshot = try #require(ChartRange.custom.snapshot(for: t, now: now, customStart: now, customEnd: now.addingTimeInterval(86400)))
        #expect(snapshot.carries.map(\.id) == ["leading", "trailing"])
        #expect(snapshot.carries[0].start.value == "10" && snapshot.carries[0].end.date == date("2024-03-10T10:00:00Z"))
        #expect(snapshot.carries[1].end.date == now && snapshot.carries[1].end.value == "12")
        #expect(snapshot.numericEntries.count == 2 && snapshot.periodChange == 87)
        let future = try #require(ChartRange.custom.snapshot(for: t, now: now, customStart: now.addingTimeInterval(86400), customEnd: now.addingTimeInterval(86400)))
        #expect(future.carries.isEmpty)
    }

    @Test func actualAtHistoricalExclusiveEndCannotReplaceLastKnownCarry() throws {
        var t = tracker(zone: "UTC")
        let now = date("2024-03-11T00:00:00Z")
        t.entries = [entry("2024-03-10T10:00:00Z", value: "12", tracker: t),
                     entry("2024-03-11T00:00:00Z", value: "99", tracker: t)]
        let day = date("2024-03-10T00:00:00Z")
        let snapshot = try #require(ChartRange.custom.snapshot(for: t, now: now, customStart: day, customEnd: day))
        #expect(snapshot.numericEntries.count == 1 && snapshot.carries.count == 1)
        #expect(snapshot.carries.last?.end.date == now && snapshot.carries.last?.end.value == "12")
    }

    @Test func exportNamesUseUTCAndRemainUniqueWhenClockRepeatsOrMovesBackwards() {
        var names = ExportNameGenerator()
        let instant = date("2024-01-02T03:04:05.123Z")
        let first = names.next(csv: false, now: instant)
        let second = names.next(csv: false, now: instant)
        let third = names.next(csv: true, now: instant.addingTimeInterval(-100))
        #expect(first == "Goalooker-backup-20240102-030405-123")
        #expect(second == "Goalooker-backup-20240102-030405-124")
        #expect(third == "Goalooker-export-20240102-030405-125")
        #expect(first != second)
    }

    @Test func chartsAndCarriesResolveDeltasWithoutChangingRawEvents() throws {
        var t = tracker(zone: "UTC")
        let now = date("2024-03-10T12:00:00Z")
        let anchor = Entry(occurredAt: now.addingTimeInterval(-100), localDay: t.day(now), value: "-10.123456789")
        let delta = Entry(occurredAt: now.addingTimeInterval(-10), localDay: t.day(now), change: "5")
        t.entries = [anchor, delta]
        let raw = t.entries
        let snapshot = try #require(ChartRange.all.snapshot(for: t, now: now, customStart: now, customEnd: now))
        #expect(snapshot.numericEntries.last?.value == "-5.123456789")
        #expect(snapshot.numericEntries.last?.change == "5" && snapshot.numericEntries.last?.id == delta.id)
        #expect(snapshot.periodChange == 5 && snapshot.carries.last?.end.value == "-5.123456789")
        #expect(t.entries == raw && t.sortedEntries.last?.value == nil)
    }

    @Test(arguments: [ChartRange.thirtyDays, .ninetyDays])
    func presetsUseWholeLocalStartDayAndExcludeFuture(_ range: ChartRange) throws {
        var tracker = tracker()
        let first = date(range == .thirtyDays ? "2024-02-10T05:00:00Z" : "2023-12-12T05:00:00Z")
        let now = date("2024-03-10T16:00:00Z")
        let included = Entry(occurredAt: first, localDay: tracker.day(first), value: "8.123456789012345")
        let latest = Entry(occurredAt: now, localDay: tracker.day(now), value: "7")
        tracker.entries = [
            Entry(occurredAt: now.addingTimeInterval(1), localDay: tracker.day(now), value: "99"), latest,
            Entry(occurredAt: first.addingTimeInterval(-1), localDay: tracker.day(first.addingTimeInterval(-1)), value: "0"), included
        ]
        let snapshot = try #require(range.snapshot(for: tracker, now: now, customStart: now, customEnd: now))
        #expect(snapshot.interval.start == first)
        #expect(snapshot.interval.end == date("2024-03-11T04:00:00Z"))
        #expect(snapshot.entries == [included, latest])
        #expect(snapshot.entries[0].value == "8.123456789012345")
    }

    @Test(arguments: ["2024-03-10", "2024-11-03"])
    func customDaysIncludeBothEdgesAcrossDST(_ day: String) throws {
        var tracker = tracker()
        let spring = day == "2024-03-10"
        let start = date(spring ? "2024-03-10T05:00:00Z" : "2024-11-03T04:00:00Z")
        let end = date(spring ? "2024-03-11T04:00:00Z" : "2024-11-04T05:00:00Z")
        let first = Entry(occurredAt: start, localDay: day, value: "10")
        let last = Entry(occurredAt: end.addingTimeInterval(-0.001), localDay: day, value: "9")
        tracker.entries = [
            Entry(occurredAt: start.addingTimeInterval(-1), localDay: tracker.day(start.addingTimeInterval(-1)), value: "0"),
            first, last, Entry(occurredAt: end, localDay: tracker.day(end), value: "100")
        ]
        let snapshot = try #require(ChartRange.custom.snapshot(for: tracker, now: start, customStart: start.addingTimeInterval(3600), customEnd: end.addingTimeInterval(-3600)))
        #expect(snapshot.interval.start == start && snapshot.interval.end == end)
        #expect(snapshot.interval.duration == Double(spring ? 23 : 25) * 3600)
        #expect(snapshot.entries == [first, last])
        #expect(snapshot.periodChange == -1)
    }

    @Test func customRangeUsesTrackerTimezoneAndRejectsInvertedDays() throws {
        var tracker = tracker(zone: "Asia/Tokyo")
        tracker.entries = [entry("2024-02-28T15:00:00Z", tracker: tracker), entry("2024-02-29T14:59:59Z", tracker: tracker), entry("2024-02-29T15:00:00Z", tracker: tracker)]
        let start = date("2024-02-29T00:00:00Z")
        let end = date("2024-02-29T12:00:00Z")
        let snapshot = try #require(ChartRange.custom.snapshot(for: tracker, now: start, customStart: start, customEnd: end))
        #expect(snapshot.interval.start == date("2024-02-28T15:00:00Z"))
        #expect(snapshot.interval.end == date("2024-02-29T15:00:00Z"))
        #expect(snapshot.entries.count == 2)
        #expect(ChartRange.custom.snapshot(for: tracker, now: start, customStart: end.addingTimeInterval(86400), customEnd: start) == nil)
        // Times within the same selected local day still describe a valid inclusive day.
        #expect(ChartRange.custom.snapshot(for: tracker, now: start, customStart: end, customEnd: start) != nil)
    }

    @Test(arguments: ChartRange.allCases)
    func emptyRangesRetainTheirDateDomainWithoutInventingValues(_ range: ChartRange) throws {
        let tracker = tracker()
        let now = date("2024-03-10T16:00:00Z")
        let snapshot = try #require(range.snapshot(for: tracker, now: now, customStart: now, customEnd: now))
        #expect(snapshot.interval.end > snapshot.interval.start)
        #expect(snapshot.entries.isEmpty && snapshot.numericEntries.isEmpty)
        #expect(snapshot.periodChange == nil)
    }

    @Test func onePointMissingValuesAndPrecisionArePreserved() throws {
        var tracker = tracker(zone: "Asia/Tokyo")
        let exact = "18.12345678901234567890123456"
        let only = entry("2024-02-29T03:00:00Z", value: exact, tracker: tracker)
        let missing = entry("2024-02-28T03:00:00Z", value: nil, tracker: tracker)
        let invalid = entry("2024-03-01T03:00:00Z", value: "NaN", tracker: tracker)
        // Malformed values cannot enter the strict numeric ledger. Projection filtering remains defensive.
        let malformed = ChartSnapshot(interval: DateInterval(start: missing.occurredAt, end: invalid.occurredAt), entries: [missing, only, invalid])
        #expect(malformed.numericEntries == [only] && malformed.periodChange == nil)
        tracker.entries = [only]
        let now = date("2024-03-02T03:00:00Z")
        let snapshot = try #require(ChartRange.all.snapshot(for: tracker, now: now, customStart: now, customEnd: now))
        #expect(snapshot.entries == [only])
        #expect(snapshot.numericEntries == [only])
        #expect(snapshot.numericEntries[0].value == exact)
        #expect(snapshot.periodChange == nil)
        let next = entry("2024-03-02T03:00:00Z", value: "17.12345678901234567890123456", tracker: tracker)
        tracker.entries.append(next)
        let two = try #require(ChartRange.all.snapshot(for: tracker, now: now, customStart: now, customEnd: now))
        #expect(two.numericEntries == [only, next])
        #expect(two.periodChange == -1)
        #expect(tracker.entries[0].value == exact)
    }

    @Test func allRangeIncludesOldRecordsButExcludesFutureEvenOnSameDay() throws {
        var tracker = tracker()
        let old = entry("2020-01-01T00:00:00Z", tracker: tracker)
        let now = date("2024-03-10T16:00:00Z")
        tracker.entries = [entry("2024-03-10T16:00:01Z", tracker: tracker), old]
        let snapshot = try #require(ChartRange.all.snapshot(for: tracker, now: now, customStart: now, customEnd: now))
        #expect(snapshot.entries == [old])
        #expect(snapshot.interval.start == date("2019-12-31T05:00:00Z"))
    }

    @Test(arguments: [(2024, 2, 29, 3), (2024, 4, 30, 0), (2024, 9, 30, 6), (2024, 12, 31, 6), (2025, 2, 28, 5), (2026, 10, 31, 3)])
    func calendarHasEveryDayAndUniqueIdentities(_ input: (Int, Int, Int, Int)) throws {
        let (year, month, dayCount, leadingBlanks) = input
        let tracker = tracker()
        let middle = try #require(tracker.calendar.date(from: DateComponents(year: year, month: month, day: 15)))
        let cells = CompletionCalendarCell.month(for: tracker, containing: middle)
        let dates = cells.compactMap { cell -> Date? in
            if case .day(let date, _) = cell { return date }
            return nil
        }
        #expect(Set(cells.map(\.id)).count == cells.count)
        #expect(cells.count == 7 + leadingBlanks + dayCount)
        #expect(dates.map { tracker.calendar.component(.day, from: $0) } == Array(1...dayCount))
        #expect(cells[7 + leadingBlanks].id == "calendar.day." + String(format: "%04d-%02d-01", year, month))
        #expect(cells.last?.id == "calendar.day." + String(format: "%04d-%02d-%02d", year, month, dayCount))
    }

    @Test func calendarDatesUseLocalMidnightAcrossDST() throws {
        let tracker = tracker()
        let cells = CompletionCalendarCell.month(for: tracker, containing: date("2024-03-15T00:00:00Z"))
        let dates = cells.compactMap { cell -> Date? in
            if case .day(let date, _) = cell { return date }
            return nil
        }
        #expect(dates.count == 31)
        #expect(dates[9] == date("2024-03-10T05:00:00Z"))
        #expect(dates[10] == date("2024-03-11T04:00:00Z"))
        #expect(dates.allSatisfy { tracker.calendar.startOfDay(for: $0) == $0 })
    }

    @Test func completionProgressKeepsOverachievementAndDistinctRecordedDays() throws {
        var tracker = tracker(zone: "Asia/Tokyo")
        tracker.kind = .daily
        tracker.createdAt = date("2024-01-01T00:00:00Z")
        tracker.setFrequency(.weekly, target: 2, now: tracker.createdAt)
        let now = date("2024-01-10T12:00:00Z")
        tracker.setFrequency(.monthly, target: 10, now: now)
        tracker.entries = ["2024-01-08T03:00:00Z", "2024-01-09T03:00:00Z", "2024-01-10T03:00:00Z", "2024-01-10T04:00:00Z"].map { entry($0, value: nil, tracker: tracker) }
        let current = try #require(CompletionProgressData.current(for: tracker, now: now))
        #expect(current.count == 3 && current.target == 2)
        #expect(current.fraction == 1)
        #expect(current.period == .weekly && !current.partial)
        #expect(current.interval.start == date("2024-01-07T15:00:00Z"))
        #expect(current.interval.end == date("2024-01-14T15:00:00Z"))
        let next = try #require(CompletionProgressData.current(for: tracker, now: date("2024-01-14T15:00:00Z")))
        #expect(next.count == 0 && next.target == 2 && next.fraction == 0)
    }

    @Test func completionBarsPreserveThenEffectiveGoalsAndPartialPeriods() throws {
        var tracker = tracker()
        tracker.kind = .daily
        tracker.createdAt = date("2024-01-03T12:00:00Z")
        tracker.setFrequency(.weekly, target: 2, now: tracker.createdAt)
        tracker.setFrequency(.monthly, target: 3, now: date("2024-01-10T12:00:00Z"))
        tracker.entries = ["2024-01-29T12:00:00Z", "2024-01-30T12:00:00Z", "2024-02-01T12:00:00Z", "2024-02-02T12:00:00Z", "2024-02-02T13:00:00Z"].map { entry($0, value: nil, tracker: tracker) }
        let now = date("2024-02-10T12:00:00Z")
        let periods = CompletionProgressData.history(for: tracker, now: now)
        #expect(periods.first?.partial == true)
        #expect(periods.first?.target == 2)
        let weekly = try #require(periods.first { $0.interval.start == date("2024-01-29T05:00:00Z") })
        #expect(weekly.interval.end == date("2024-02-01T05:00:00Z"))
        #expect(weekly.partial && weekly.count == 2 && weekly.target == 2 && weekly.period == .weekly)
        let monthly = try #require(periods.last)
        #expect(monthly.interval.start == date("2024-02-01T05:00:00Z"))
        #expect(monthly.interval.end == date("2024-03-01T05:00:00Z"))
        #expect(monthly.count == 2 && monthly.target == 3 && monthly.period == .monthly && !monthly.partial)
        #expect(monthly.fraction == 2.0 / 3.0)
        #expect(CompletionProgressData.history(for: tracker, now: now, limit: 1).map(\.id) == [monthly.id])
    }

    @Test func completionWithoutGoalShowsWeeklyRecordsAcrossDSTWithoutInventingTargets() {
        var tracker = tracker()
        tracker.kind = .daily
        tracker.createdAt = date("2024-03-01T12:00:00Z")
        let now = date("2024-03-10T16:00:00Z")
        tracker.entries = ["2024-03-04T12:00:00Z", "2024-03-10T12:00:00Z", "2024-03-10T13:00:00Z", "2024-03-11T12:00:00Z"].map { entry($0, value: nil, tracker: tracker) }
        let periods = CompletionProgressData.history(for: tracker, now: now, limit: 2)
        #expect(CompletionProgressData.current(for: tracker, now: now) == nil)
        #expect(periods.map(\.count) == [0, 2])
        #expect(periods.allSatisfy { $0.target == nil && $0.period == .weekly })
        #expect(periods.first?.partial == true)
        #expect(periods.last?.interval.end == date("2024-03-11T04:00:00Z"))
        // Backfilled recorded days remain visible even when they precede tracker creation.
        tracker.createdAt = now
        tracker.entries.append(entry("2024-03-03T12:00:00Z", value: nil, tracker: tracker))
        let backfilled = CompletionProgressData.history(for: tracker, now: now, limit: 2)
        #expect(backfilled.map(\.count) == [1, 2])
        #expect(backfilled.first?.partial == false && backfilled.last?.partial == true)
        tracker.rules = [GoalRule(period: .weekly, target: "2", effectiveAt: now.addingTimeInterval(3600))]
        #expect(CompletionProgressData.current(for: tracker, now: now) == nil)
        #expect(CompletionProgressData.history(for: tracker, now: now).allSatisfy { $0.target == nil })
        #expect(CompletionProgressData.history(for: tracker, now: now, limit: 0).isEmpty)
    }
}
