import Testing
import Foundation
import UIKit
import ImageIO
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

    func datedPhoto(_ timestamp: String?, offset: String? = nil) throws -> Data {
        var exif: [CFString: String] = [:]
        if let timestamp { exif[kCGImagePropertyExifDateTimeOriginal] = timestamp }
        if let offset { exif[kCGImagePropertyExifOffsetTimeOriginal] = offset }
        return try metadataPhoto([kCGImagePropertyExifDictionary: exif] as CFDictionary)
    }
    func metadataPhoto(_ properties: CFDictionary, type: CFString = "public.jpeg" as CFString) throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type, 1, nil))
        CGImageDestinationAddImage(destination, try #require(image.cgImage), properties)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
    @Test func photoDateUsesOriginalOffsetAndRejectsMissingInvalidOrFutureDates() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let now = date("2024-03-01T00:00:00Z")
        let photo = try datedPhoto("2024:02:29 23:30:05", offset: "+08:00")
        #expect(photoDate(photo, timeZone: zone, now: now) == date("2024-02-29T15:30:05Z"))
        #expect(photoDate(try datedPhoto("2024:02:29 23:30:05"), timeZone: zone, now: now) == date("2024-02-29T14:30:05Z"))
        #expect(photoDate(try datedPhoto("2024:02:29 23:30:05", offset: "+00:00"), timeZone: zone, now: now) == date("2024-02-29T23:30:05Z"))
        #expect(photoDate(try datedPhoto("2023:02:29 12:00:00"), timeZone: zone, now: now) == nil)
        #expect(photoDate(try datedPhoto("2024:02:29 23:30:05extra"), timeZone: zone, now: now) == nil)
        #expect(photoDate(try datedPhoto("2024:03:02 12:00:00"), timeZone: zone, now: now) == nil)
        #expect(photoDate(try datedPhoto(nil), timeZone: zone, now: now) == nil)
        #expect(photoDate(Data([1, 2, 3]), timeZone: zone, now: now) == nil)
        #expect(photoDate(try photoCopy(photo), timeZone: zone, now: now) == nil)
        let digitized = try metadataPhoto([kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeDigitized: "2024:02:29 23:30:05"]] as CFDictionary)
        let tiff = try metadataPhoto([kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: "2024:02:29 23:30:05"]] as CFDictionary, type: "public.tiff" as CFString)
        #expect(photoDate(digitized, timeZone: zone, now: now) == date("2024-02-29T14:30:05Z"))
        #expect(photoDate(tiff, timeZone: zone, now: now) == date("2024-02-29T14:30:05Z"))
        let png = try metadataPhoto([kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:02:29 23:30:05", kCGImagePropertyExifOffsetTimeOriginal: "+08:00"]] as CFDictionary, type: "public.png" as CFString)
        #expect(photoDate(png, timeZone: zone, now: now) == date("2024-02-29T15:30:05Z"))
    }
    @Test func tenPhotoBackupRoundTripsAndElevenPhotoSavePreservesData() throws {
        var t = tracker(.number)
        let event = date("2024-06-01T00:00:00Z")
        let photo = try photoCopy(datedPhoto(nil))
        t.put(Entry(occurredAt: event, localDay: t.day(event), value: "18.5", photos: Array(repeating: photo, count: 10)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try AppStore(url: directory.appendingPathComponent("store"))
        try store.save(t)
        let payload = try Backup(trackers: store.trackers).encoded()
        #expect(try Backup.decode(payload).trackers == [t])
        var excess = t; excess.entries[0].photos.append(photo)
        #expect(throws: (any Error).self) { try store.save(excess) }
        #expect(throws: (any Error).self) { try store.restore(JSONEncoder().encode(Backup(trackers: [excess]))) }
        #expect(store.trackers == [t])
        try store.restore(payload)
        #expect(try AppStore(url: directory.appendingPathComponent("store")).trackers == [t])
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
    @Test func widgetSummaryPreservesCalendarPrecisionAndPrivacy() throws {
        let now = date("2024-03-10T12:00:00Z")
        var daily = tracker(zone: "America/New_York")
        daily.setFrequency(.weekly, target: 2, now: date("2024-03-01T12:00:00Z"))
        daily.setFrequency(.monthly, target: 10, now: now)
        daily.put(Entry(occurredAt: now, localDay: daily.day(now), note: "private note", photos: [Data("private photo".utf8)]))
        var number = tracker(.number)
        number.put(Entry(occurredAt: now, localDay: number.day(now), value: "18.1234567890123456789"))
        number.put(Entry(occurredAt: now.addingTimeInterval(-86400), localDay: "2024-03-09", value: "20"))
        var hidden = tracker(); hidden.archived = true; hidden.name = "Archived secret"
        let snapshot = WidgetSnapshot([daily, number, hidden], language: "ja")
        let data = try JSONEncoder().encode(snapshot)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("private note") && !text.contains("private photo") && !text.contains("photos") && !text.contains("Archived secret"))
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        #expect(decoded.language == "ja" && decoded.rows.count == 2)
        #expect(decoded.rows[1].value == number.latest?.value)
        let summary = decoded.rows[0].tracker
        #expect(summary.count(in: summary.interval(now, period: .weekly)) == daily.count(in: daily.interval(now, period: .weekly)))
        #expect(summary.rule(at: now)?.target == "2")
        #expect(summary.rule(at: date("2024-04-01T04:00:00Z"))?.target == "10")
        #expect(snapshot.nextRefresh(after: now) == date("2024-03-10T15:00:00Z"))
        #expect(WidgetSnapshot([daily], language: "en").nextRefresh(after: now) == date("2024-03-11T04:00:00Z"))
        #expect(summary.count(in: summary.interval(date("2024-03-11T04:00:00Z"), period: .weekly)) == 0)
        #expect(WidgetSnapshot([], language: "en").rows.isEmpty)
    }

    @Test func locationAndCardBackupCompatibilityAndInvalidRestore() throws {
        var t = tracker(.number)
        let now = date("2024-06-01T00:00:00Z")
        t.cardBackground = .map
        t.put(Entry(occurredAt: now, localDay: t.day(now), value: "18.5000000001", location: RecordedLocation(latitude: 35.68, longitude: 139.76)))
        let payload = try Backup(trackers: [t]).encoded()
        #expect(try Backup.decode(payload).trackers == [t])
        #expect(Backup(trackers: [t]).csv().contains("latitude,longitude"))
        #expect(Backup(trackers: [t]).csv().contains("\"35.68\",\"139.76\""))
        var legacy = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        var trackers = try #require(legacy["trackers"] as? [[String: Any]])
        trackers[0].removeValue(forKey: "cardBackground")
        var entries = try #require(trackers[0]["entries"] as? [[String: Any]])
        entries[0].removeValue(forKey: "location")
        trackers[0]["entries"] = entries; legacy["trackers"] = trackers
        let old = try Backup.decode(JSONSerialization.data(withJSONObject: legacy)).trackers[0]
        #expect(old.cardBackground == nil && old.resolvedCardBackground == .plot && old.entries[0].location == nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppStore(url: directory.appendingPathComponent("store"))
        try store.save(t)
        var invalid = t; invalid.entries[0].location?.latitude = 91
        #expect(throws: (any Error).self) { try store.restore(JSONEncoder().encode(Backup(trackers: [invalid]))) }
        #expect(store.trackers == [t])
        #expect(!RecordedLocation(latitude: .nan, longitude: 0).isValid)
        #expect(!RecordedLocation(latitude: 0, longitude: .infinity).isValid)
    }

}
