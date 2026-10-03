import Testing
import Foundation
import UIKit
@testable import GoalTracker

@MainActor struct DomainTests {
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func tracker(_ kind: TrackerKind = .daily, zone: String = "Asia/Tokyo") -> Tracker {
        var t = Tracker(name: "Test", kind: kind); t.timeZoneID = zone; t.createdAt = date("2024-01-01T00:00:00Z"); return t
    }
    @Test func duplicateAndPeriodBoundaries() throws {
        var t = tracker()
        let monday = date("2024-01-08T03:00:00Z")
        t.put(Entry(occurredAt: monday, localDay: t.day(monday)))
        t.put(Entry(occurredAt: monday, localDay: t.day(monday), note: "updated"))
        #expect(t.entries.count == 1)
        #expect(t.count(in: t.interval(monday, period: .weekly)) == 1)
        #expect(t.count(in: t.interval(date("2024-01-07T03:00:00Z"), period: .weekly)) == 0)
        #expect(t.entries.first?.note == "updated")
        let leap = t.interval(date("2024-02-10T00:00:00Z"), period: .monthly)
        #expect(t.calendar.dateComponents([.day], from: leap.start, to: leap.end).day == 29)
    }
    @Test func recordedDaySurvivesTravelAndDST() {
        var t = tracker(zone: "America/New_York")
        let event = date("2024-03-11T03:30:00Z")
        let day = t.day(event)
        #expect(day == "2024-03-10")
        t.put(Entry(occurredAt: event, localDay: day))
        let window = t.interval(date("2024-03-10T12:00:00Z"), period: .weekly)
        #expect(window.duration != 7 * 86400)
        #expect(t.count(in: window) == 1)
        #expect(t.entries[0].localDay == day)
    }
    @Test func precisionAndBackfillAndAchievement() throws {
        var t = tracker(.number)
        let newest = date("2024-06-01T00:00:00Z")
        let older = date("2024-05-01T00:00:00Z")
        let exact = try Numbers.parse("18.12345678901234567890123456", locale: Locale(identifier: "en"))
        t.put(Entry(occurredAt: newest, localDay: t.day(newest), value: exact))
        t.put(Entry(occurredAt: older, localDay: t.day(older), value: "20"))
        #expect(t.latest?.value == exact)
        let rule = GoalRule(period: .deadline, target: "19", effectiveAt: newest, deadline: date("2024-07-01T00:00:00Z"))
        #expect(t.achieved(rule))
        t.entries.removeAll { $0.value == "20" }
        #expect(!t.achieved(rule))
        #expect(throws: (any Error).self) { try Numbers.parse("1e5") }
        #expect(try Numbers.parse("18,500", locale: Locale(identifier: "de_DE")) == "18.5")
    }
    @Test func frequencyChangesAndPartialPeriods() {
        var t = tracker()
        t.createdAt = date("2024-01-03T00:00:00Z")
        t.setFrequency(.weekly, target: 2, now: t.createdAt)
        let now = date("2024-01-10T00:00:00Z")
        t.setFrequency(.monthly, target: 10, now: now)
        #expect(t.rules.last?.effectiveAt == t.interval(now, period: .monthly).end)
        let history = t.frequencyHistory(until: date("2024-02-15T00:00:00Z"))
        #expect(history.first?.3 == true)
        #expect(history.contains { $0.2 == 2 && !$0.3 })
        #expect(history.last?.2 == 10)
        #expect(history.last?.3 == false)
        #expect(history.contains { $0.0.end == t.rules.last?.effectiveAt && $0.3 })
    }
    @Test func backupRoundTripAndFailedRestorePreservesData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store")
        let store = try AppStore(url: url)
        var t = tracker(.number)
        let event = date("2024-06-01T00:00:00Z")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4)) }.jpegData(compressionQuality: 0.8)!
        t.put(Entry(occurredAt: event, localDay: t.day(event), value: "18.123456789012345", note: "繁中、日本語, \"English\"\nline", photos: [image]))
        t.rules = [GoalRule(period: .deadline, target: "20", effectiveAt: event, deadline: event.addingTimeInterval(86400))]
        try store.save(t)
        let payload = try Backup(trackers: store.trackers).encoded()
        #expect(try Backup.decode(payload).trackers == [t])
        #expect(throws: (any Error).self) { try store.restore(Data("broken".utf8)) }
        #expect(store.trackers == [t])
        var damaged = t; damaged.entries[0].photos = [Data([1, 2, 3])]
        #expect(throws: (any Error).self) { try store.restore(JSONEncoder().encode(Backup(trackers: [damaged]))) }
        #expect(store.trackers == [t])
        try store.restore(payload)
        #expect(store.trackers == [t])
        let reopened = try AppStore(url: url)
        #expect(reopened.trackers == [t])
        #expect(Backup(trackers: [t]).csv().contains("\"\"English\"\""))
    }
    @Test func duplicateBackupIsRejectedAndOverachievementIsKept() throws {
        var t = tracker(); let now = date("2024-01-10T00:00:00Z")
        for offset in 0..<3 { let d = t.calendar.date(byAdding: .day, value: offset, to: now)!; t.put(Entry(occurredAt: d, localDay: t.day(d))) }
        #expect(t.count(in: t.interval(now, period: .weekly)) == 3)
        t.entries.append(t.entries[0])
        #expect(throws: (any Error).self) { try Backup(trackers: [t]).encoded() }
    }
    @Test func ownedPhotoCopyHasBoundedPixelsAndRejectsUnreadableInput() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 3200, height: 800), format: format).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3200, height: 800))
        }.pngData()!
        let copy = try photoCopy(source)
        let image = try #require(UIImage(data: copy))
        #expect(image.size == CGSize(width: 1600, height: 400))
        #expect(Backup.validPhoto(copy))
        #expect(throws: (any Error).self) { try photoCopy(Data([1, 2, 3])) }
    }
    @Test func extremeBackupDatesAreRejected() throws {
        var t = tracker()
        t.createdAt = Date(timeIntervalSince1970: .greatestFiniteMagnitude)
        let store = try AppStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        #expect(throws: (any Error).self) { try store.restore(JSONEncoder().encode(Backup(trackers: [t]))) }
        #expect(store.trackers.isEmpty)
    }
    @Test func csvKeepsNumericValuesAndProtectsUserText() {
        var t = tracker(.number); let event = date("2024-06-01T00:00:00Z")
        t.name = " =HYPERLINK(1)"
        t.put(Entry(occurredAt: event, localDay: t.day(event), value: "-18.5", note: "  +SUM(1,2)"))
        let csv = Backup(trackers: [t]).csv()
        #expect(csv.contains("\"-18.5\""))
        #expect(csv.contains("\"' =HYPERLINK(1)\""))
        #expect(csv.contains("\"'  +SUM(1,2)\""))
    }
    @Test func firstGoalCreatedAfterTrackerStillHasHistory() {
        var t = tracker()
        t.createdAt = date("2024-01-03T00:00:00Z")
        t.setFrequency(.weekly, target: 2, now: t.createdAt.addingTimeInterval(60))
        let history = t.frequencyHistory(until: date("2024-01-15T00:00:00Z"))
        #expect(history.count == 3)
        #expect(history.first?.3 == true)
        #expect(history[1].3 == false)
    }
    @Test func deadlineDirectionAndNotificationPlan() throws {
        var t = tracker(.number); let now = date("2024-06-01T00:00:00Z")
        t.reminder = Reminder(hour: 9, minute: 0, weekdays: [2, 3])
        t.rules = [GoalRule(period: .deadline, target: "10", effectiveAt: now, deadline: now.addingTimeInterval(86400 * 10), direction: .down)]
        #expect(try Reminders.requests([t], now: now).count == 3)
        t.put(Entry(occurredAt: now, localDay: t.day(now), value: "9"))
        #expect(t.achieved(t.rules[0]))
        #expect(try Reminders.requests([t], now: now).count == 2)
    }
}
