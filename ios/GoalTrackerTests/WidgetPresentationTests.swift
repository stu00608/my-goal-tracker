import Testing
import Foundation
import UIKit
import ImageIO
@testable import GoalTracker

@MainActor struct WidgetPresentationTests {
    private let now = ISO8601DateFormatter().date(from: "2024-03-10T12:00:00Z")!

    @Test func boundedCardsKeepOrderPrecisionAndOriginalRecords() throws {
        var number = Tracker(name: "Number", kind: .number, timeZoneID: "Asia/Tokyo")
        for index in 0..<50 {
            let date = now.addingTimeInterval(Double(index - 49) * 86400)
            number.put(Entry(occurredAt: date, localDay: number.day(date), value: "18.1234567890123456789", note: "private note", photos: [Data("full photo".utf8)]))
        }
        var hidden = Tracker(name: "Archived secret", kind: .daily); hidden.archived = true
        let next = Tracker(name: "Next", kind: .daily)
        let third = Tracker(name: "Third", kind: .daily)
        let fourth = Tracker(name: "Fourth", kind: .daily)
        let original = number
        let snapshot = WidgetSnapshot([hidden, number, next, third, fourth], language: "ja", now: now)
        #expect(snapshot.rows.map(\.id) == [number.id, next.id, third.id, fourth.id])
        let row = try #require(snapshot.rows.first)
        #expect(row.plot?.count == 24)
        #expect(row.plot?.first?.date == now.addingTimeInterval(-23 * 86400))
        #expect(row.plot?.last?.value == "18.1234567890123456789")
        #expect(row.value == number.latest?.value)
        #expect(row.thumbnail == nil && row.locations == nil)
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(!encoded.contains("private note") && !encoded.contains("full photo") && !encoded.contains("photos") && !encoded.contains("Archived secret"))
        #expect(number == original)
        #expect(row.recordURL.absoluteString == "goaltracker://record/" + number.id.uuidString)
    }

    @Test func photoTextContrastFollowsImageRatherThanSystemAppearance() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        for (color, light) in [(UIColor.white, false), (.black, true), (.systemTeal, false)] {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24), format: format).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
            }
            #expect(CardImageContrast.prefersLightText(try #require(image.pngData())) == light)
        }
    }

    @Test func configuredWidgetSelectsFourthAndDoesNotReplaceMissingGoal() {
        let trackers = (1...5).map { _ in Tracker(name: "Same name", kind: .number) }
        var snapshot = WidgetSnapshot(trackers, language: "en", now: now)
        #expect(snapshot.row(selectedID: trackers[3].id)?.id == trackers[3].id)
        #expect(snapshot.row(selectedID: nil)?.id == trackers[0].id)
        snapshot.rows.removeAll { $0.id == trackers[3].id }
        #expect(snapshot.row(selectedID: trackers[3].id) == nil)
        #expect(snapshot.row(selectedID: nil)?.id == trackers[0].id)
    }

    @Test func overviewPlotPreservesSmallChangesAndFiniteContext() {
        func points(_ values: [String]) -> [CardPlotPoint] { values.map { CardPlotPoint(date: now, value: $0) } }
        let narrow = CardPlotScale.domain(points: points(["21.530", "21.536"]), precision: 3)
        #expect(narrow.lowerBound < 21.530 && narrow.upperBound > 21.536)
        #expect((21.536 - 21.530) / (narrow.upperBound - narrow.lowerBound) < 0.01)
        for values in [["0"], ["-4", "-3"], ["-0.001", "0.001"], ["12345678901234567890.12345678"]] {
            let domain = CardPlotScale.domain(points: points(values), precision: 8)
            #expect(domain.lowerBound.isFinite && domain.upperBound.isFinite && domain.lowerBound < domain.upperBound)
            #expect(points(values).compactMap(\.plottedValue).allSatisfy { domain.contains($0) })
        }
        #expect(CardPlotScale.domain(points: points(["0", "1"]), precision: 0, completion: true) == 0...2)
    }

    @Test func legacySummaryDecodesWithoutNewPresentationFields() throws {
        let tracker = Tracker(name: "Legacy", kind: .number)
        let data = try JSONEncoder().encode(WidgetSnapshot([tracker], language: "en", now: now))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var rows = try #require(object["rows"] as? [[String: Any]])
        for key in ["background", "plot", "thumbnail", "locations"] { rows[0].removeValue(forKey: key) }
        object["rows"] = rows
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.rows[0].id == tracker.id)
        #expect(decoded.rows[0].resolvedBackground == .plot)
        #expect(decoded.rows[0].plot == nil && decoded.rows[0].thumbnail == nil && decoded.rows[0].locations == nil)
    }

    @Test func dailyProjectionKeepsRecordedDaysAndCalendarProgressBounded() {
        var tracker = Tracker(name: "Daily", kind: .daily, timeZoneID: "America/New_York")
        tracker.setFrequency(.weekly, target: 2, now: now.addingTimeInterval(-20 * 86400))
        tracker.setFrequency(.monthly, target: 10, now: now)
        for index in 0..<300 {
            let date = now.addingTimeInterval(-Double(index) * 86400)
            tracker.put(Entry(occurredAt: date, localDay: tracker.day(date)))
        }
        let row = WidgetRow(tracker, now: now)
        #expect(row.completedDays.count <= 37)
        #expect(row.plot?.count == 14)
        #expect(row.plot?.allSatisfy { $0.value == "1" } == true)
        #expect(row.tracker.count(in: tracker.interval(now, period: .weekly)) == tracker.count(in: tracker.interval(now, period: .weekly)))
        #expect(row.tracker.count(in: tracker.interval(now, period: .monthly)) == tracker.count(in: tracker.interval(now, period: .monthly)))
        #expect(row.rules.count == 2)
        #expect(WidgetSnapshot([tracker], language: "en", now: now).nextRefresh(after: now) == ISO8601DateFormatter().date(from: "2024-03-11T04:00:00Z"))
    }

    @Test func photoProjectionUsesLatestOwnedCopyAndBoundsThumbnail() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 1200), format: format).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
        }
        let photo = try #require(image.jpegData(compressionQuality: 0.9))
        var tracker = Tracker(name: "Photo", kind: .daily, cardBackground: .photo)
        tracker.put(Entry(occurredAt: now, localDay: tracker.day(now), note: "private note", photos: [photo]))
        tracker.put(Entry(occurredAt: now.addingTimeInterval(86400), localDay: tracker.day(now.addingTimeInterval(86400))))
        let original = tracker
        let row = WidgetRow(tracker, now: now)
        let thumbnail = try #require(row.thumbnail)
        #expect(thumbnail.count <= 60_000 && thumbnail != photo)
        let source = try #require(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        #expect((properties[kCGImagePropertyPixelWidth as String] as? Int ?? 9999) <= 320)
        #expect((properties[kCGImagePropertyPixelHeight as String] as? Int ?? 9999) <= 320)
        #expect(row.plot == nil && row.locations == nil && tracker == original)
    }

    @Test func mapProjectionFiltersInvalidCoordinatesAndEmptyBackgroundsStayEmpty() {
        var tracker = Tracker(name: "Map", kind: .daily, cardBackground: .map)
        for index in 0..<50 {
            let date = now.addingTimeInterval(-Double(49 - index) * 86400)
            tracker.put(Entry(occurredAt: date, localDay: tracker.day(date), location: RecordedLocation(latitude: 35 + Double(index) / 1000, longitude: 139)))
        }
        let row = WidgetRow(tracker, now: now)
        #expect(row.locations?.count == 24 && row.locations?.first?.latitude == 35.026)
        #expect(row.plot == nil && row.thumbnail == nil)
        tracker.entries = [Entry(occurredAt: now, localDay: tracker.day(now), location: RecordedLocation(latitude: 91, longitude: 139))]
        #expect(WidgetRow(tracker, now: now).locations?.isEmpty == true)
        tracker.entries = []
        #expect(WidgetRow(tracker, now: now).locations?.isEmpty == true)
        tracker.cardBackground = .photo
        #expect(WidgetRow(tracker, now: now).thumbnail == nil)
        tracker.cardBackground = nil
        #expect(WidgetRow(tracker, now: now).plot?.isEmpty == true)
    }
}
