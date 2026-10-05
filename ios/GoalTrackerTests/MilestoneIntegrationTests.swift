import Foundation
import SwiftData
import Testing
@testable import GoalTracker

@MainActor struct MilestoneIntegrationTests {
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    @Test func displayWeekOrderDoesNotChangeHistoricalFrequencyOrLocalDates() {
        var tracker = Tracker(name: "Office", kind: .daily)
        tracker.timeZoneID = "Asia/Tokyo"
        let start = date("2026-09-01T00:00:00Z")
        tracker.createdAt = start
        tracker.rules = [GoalRule(period: .weekly, target: "2", effectiveAt: start)]
        let recorded = date("2026-10-04T12:00:00Z")
        tracker.put(Entry(occurredAt: recorded, localDay: tracker.day(recorded)))
        let now = date("2026-10-05T03:00:00Z")
        let history = tracker.frequencyHistory(until: now).map { "\($0.0.start):\($0.0.end):\($0.1):\($0.2):\($0.3)" }
        let sunday = CompletionCalendarCell.month(for: tracker, containing: now, firstWeekday: 1)
        let monday = CompletionCalendarCell.month(for: tracker, containing: now, firstWeekday: 2)
        #expect(WeekdayOrder.days(starting: 1) == [1, 2, 3, 4, 5, 6, 7])
        #expect(WeekdayOrder.days(starting: 2) == [2, 3, 4, 5, 6, 7, 1])
        #expect(sunday.prefix(7).map(\.id) == (1...7).map { "calendar.weekday.\($0)" })
        #expect(monday.prefix(7).map(\.id) == [2, 3, 4, 5, 6, 7, 1].map { "calendar.weekday.\($0)" })
        let sundayDates = sunday.compactMap { cell -> String? in if case .day(_, let key) = cell { return key }; return nil }
        let mondayDates = monday.compactMap { cell -> String? in if case .day(_, let key) = cell { return key }; return nil }
        #expect(sundayDates == mondayDates && sundayDates.count == 31)
        #expect(Set(sunday.map(\.id)).count == sunday.count)
        #expect(tracker.calendar.firstWeekday == 2)
        #expect(history == tracker.frequencyHistory(until: now).map { "\($0.0.start):\($0.0.end):\($0.1):\($0.2):\($0.3)" })
        #expect(tracker.entries[0].localDay == "2026-10-04")
    }

    @Test func legacyTwentyLocationsMigrateWithoutLosingIdentityOrCombination() throws {
        var legacy = Tracker(name: "Office", kind: .daily)
        legacy.conditions = (0..<20).map { PlaceCondition(name: "Office \($0)", location: RecordedLocation(latitude: 35, longitude: 139 + Double($0) / 1000)) }
        legacy.conditionCombination = .all; legacy.gateSave = true
        let originalIDs = legacy.resolvedConditions.map(\.id)
        let source = try Backup(version: 2, trackers: [legacy]).encoded()
        let old = try Backup.decode(source)
        #expect(old.trackers == [legacy])
        let migrated = try Backup.decode(Backup(trackers: old.trackers).encoded()).trackers[0]
        #expect(migrated.conditions == nil && migrated.conditionCombination == nil)
        #expect(migrated.resolvedConditionGroups.count == 2)
        #expect(migrated.resolvedConditionGroups.allSatisfy { $0.conditions.count == 10 && $0.combination == .all })
        #expect(migrated.resolvedOuterCombination == .all)
        #expect(migrated.resolvedConditions.map(\.id) == originalIDs)
        #expect(migrated.requiresConditionGate)
        #expect(try Backup.decode(Backup(trackers: [migrated]).encoded()).trackers == [migrated])
    }

    @Test func legacyDormantFlagRestoresInactiveAndPrivateSafetyCopyPrecedesFirstNewSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.store")
        var legacy = Tracker(name: "Dormant", kind: .daily)
        legacy.gateSave = true
        let payload = try Backup(version: 2, trackers: [legacy]).encoded()
        let container = try ModelContainer(for: Ledger.self, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        let context = ModelContext(container); context.autosaveEnabled = false
        context.insert(Ledger(payload: payload)); try context.save()
        let store = try AppStore(url: url)
        #expect(store.trackers[0].gateSave == false && !store.trackers[0].requiresConditionGate)
        #expect(try Data(contentsOf: directory.appendingPathComponent("Ledger-v2-premigration.json")) == payload)
        #expect(try context.fetch(FetchDescriptor<Ledger>()).first?.payload == payload)
        try store.save(store.trackers[0])
        #expect(try Data(contentsOf: directory.appendingPathComponent("Ledger-v2-premigration.json")) == payload)
        let restored = try AppStore(url: directory.appendingPathComponent("restore.store"))
        try restored.restore(payload)
        #expect(!restored.trackers[0].requiresConditionGate && restored.trackers[0].gateSave == false)
        #expect(throws: DataError.self) { try Backup(trackers: [legacy]).validate() }
    }

    @Test func malformedGroupsUnknownTypesAndOverCapacityDoNotReplaceExistingData() throws {
        var tracker = Tracker(name: "Office", kind: .daily)
        let condition = AchievementCondition(payload: .weekdays([2, 3, 4, 5, 6]))
        tracker.conditionGroups = [ConditionGroup(conditions: [condition])]; tracker.gateSave = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppStore(url: directory.appendingPathComponent("store"))
        try store.save(tracker)
        var invalid = tracker
        invalid.conditionGroups = [ConditionGroup()]
        #expect(throws: DataError.self) { try store.save(invalid) }
        invalid.conditionGroups = (0..<11).map { _ in ConditionGroup(conditions: [AchievementCondition(payload: .weekdays([2]))]) }
        #expect(throws: DataError.self) { try store.save(invalid) }
        invalid.conditionGroups = [ConditionGroup(conditions: (0..<11).map { _ in AchievementCondition(payload: .weekdays([2])) })]
        #expect(throws: DataError.self) { try store.save(invalid) }
        let encoded = try Backup(trackers: [tracker]).encoded()
        let unknown = String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "weekdays", with: "futureUnknown")
        #expect(throws: (any Error).self) { try store.restore(Data(unknown.utf8)) }
        #expect(store.trackers == [tracker])
    }

    @Test func numericGoalEvidenceAgreesWithDeadlineAndExcludesFuturePoints() {
        var tracker = Tracker(name: "Score", kind: .number)
        let first = date("2026-10-01T00:00:00Z"), effective = date("2026-10-03T00:00:00Z")
        let now = date("2026-10-05T00:00:00Z"), due = date("2026-10-10T00:00:00Z")
        let historical = Entry(occurredAt: first, localDay: tracker.day(first), value: "100")
        tracker.entries = [historical, Entry(occurredAt: effective, localDay: tracker.day(effective), value: "90")]
        let rule = GoalRule(period: .deadline, target: "100", effectiveAt: effective, deadline: due)
        tracker.rules = [rule]
        #expect(tracker.achievement(for: rule, now: now)?.evidenceEntryID == historical.id)
        #expect(tracker.achievement(for: rule, now: now)?.achievedAt == effective)
        tracker.entries.removeFirst()
        tracker.put(Entry(occurredAt: due, localDay: tracker.day(due), value: "110"))
        #expect(tracker.achievement(for: rule, now: now) == nil)
        #expect(tracker.achievement(for: rule, now: due)?.value == "110")
    }
}
