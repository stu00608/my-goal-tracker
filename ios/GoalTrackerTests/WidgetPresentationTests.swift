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
        for key in ["background", "plot", "thumbnail", "locations", "progress", "axisLower", "axisUpper", "lastRecordedAt"] { rows[0].removeValue(forKey: key) }
        object["rows"] = rows
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.rows[0].id == tracker.id)
        #expect(decoded.rows[0].resolvedBackground == .plot)
        #expect(decoded.rows[0].plot == nil && decoded.rows[0].thumbnail == nil && decoded.rows[0].locations == nil)
        #expect(decoded.rows[0].progress == nil && decoded.rows[0].axisLower == nil && decoded.rows[0].axisUpper == nil && decoded.rows[0].lastRecordedAt == nil)
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

    @Test(arguments: [("-10", "0", "-5", Direction.up), ("10", "0", "5", .down), ("-10", "-20", "-15", .down)])
    func signedGoalProgressUsesEffectiveDateBaseline(_ input: (String, String, String, Direction)) throws {
        let (baseline, target, current, direction) = input
        var t = Tracker(name: "Ring", kind: .number)
        let effective = now.addingTimeInterval(-86400)
        t.rules = [GoalRule(period: .deadline, target: target, effectiveAt: effective, deadline: now.addingTimeInterval(86400), direction: direction)]
        t.entries = [Entry(occurredAt: effective.addingTimeInterval(-100), localDay: t.day(effective), value: direction == .up ? "-30" : "30"),
                     Entry(occurredAt: effective.addingTimeInterval(-10), localDay: t.day(effective), value: baseline),
                     Entry(occurredAt: now, localDay: t.day(now), value: current),
                     Entry(occurredAt: now.addingTimeInterval(10), localDay: t.day(now), value: target)]
        let progress = try #require(GoalProgress.current(for: t, now: now))
        #expect(progress.baseline == baseline && progress.current == current && progress.fraction == 0.5 && !progress.achieved)
        #expect(WidgetRow(t, now: now).value == current)
        t.entries.append(Entry(occurredAt: now.addingTimeInterval(-100), localDay: t.day(now), value: target))
        #expect(GoalProgress.current(for: t, now: now)?.fraction == 1)
        #expect(GoalProgress.current(for: t, now: now)?.current == current)
    }

    @Test func progressHandlesEmptyFirstBaselineDeadlineAndAchievedFallback() throws {
        var t = Tracker(name: "Ring", kind: .number, cardBackground: .progress)
        #expect(!GoalProgress.available(for: t, now: now) && GoalProgress.current(for: t, now: now) == nil)
        let effective = now.addingTimeInterval(-86400), deadline = now.addingTimeInterval(-10)
        t.rules = [GoalRule(period: .deadline, target: "20", effectiveAt: effective, deadline: deadline)]
        #expect(GoalProgress.available(for: t, now: now) && WidgetRow(t, now: now).progress == nil)
        t.entries = [Entry(occurredAt: effective.addingTimeInterval(10), localDay: t.day(effective), value: "10"),
                     Entry(occurredAt: deadline, localDay: t.day(deadline), value: "15"),
                     Entry(occurredAt: now, localDay: t.day(now), value: "21")]
        #expect(GoalProgress.current(for: t, now: now)?.fraction == 0.5)
        #expect(GoalProgress.current(for: t, now: now)?.current == "15")
        t.rules[0].target = "10"
        #expect(GoalProgress.current(for: t, now: now)?.fraction == 1)
        t.kind = .daily; t.rules = []
        t.setFrequency(.weekly, target: 2, now: effective)
        t.entries = [0, 1, 2].map { offset in
            let date = now.addingTimeInterval(-Double(offset) * 86400)
            return Entry(occurredAt: date, localDay: t.day(date))
        }
        let row = WidgetRow(t, now: now)
        let daily = try #require(row.progress)
        #expect(daily.current == "3" && daily.target == "2" && daily.fraction == 1)
        #expect(row.currentProgress(at: t.interval(now, period: .weekly).end)?.fraction == 0)
    }

    @Test func explicitBoundsClipWithoutRewritingAndPartialBoundsStayPositive() {
        let points = [CardPlotPoint(date: now, value: "5"), CardPlotPoint(date: now, value: "15")]
        #expect(CardPlotScale.domain(points: points, precision: 3, lower: "0", upper: "10") == 0...10)
        for bounds in [("20", "10"), ("10", "10")] {
            #expect(CardPlotScale.domain(points: points, precision: 3, lower: bounds.0, upper: bounds.1) == CardPlotScale.domain(points: points, precision: 3))
        }
        let lower = CardPlotScale.domain(points: points, precision: 3, lower: "100")
        let upper = CardPlotScale.domain(points: [], precision: 3, upper: "-100")
        #expect(lower.lowerBound == 100 && lower.upperBound > 100)
        #expect(upper.upperBound == -100 && upper.lowerBound < -100)
        let precise = CardPlotScale.domain(points: [], precision: 8, lower: "12345678901234567890.1", upper: "12345678901234567890.2")
        #expect(precise.lowerBound == 12345678901234567890 && precise.upperBound > precise.lowerBound)
        var t = Tracker(name: "Bounds", kind: .number, axisLower: "0", axisUpper: "10")
        t.entries = points.map { Entry(occurredAt: $0.date, localDay: t.day($0.date), value: $0.value) }
        let original = t.entries, row = WidgetRow(t, now: now)
        #expect(row.clippedPointCount == 1 && t.entries == original)
    }

    @Test func widgetCarriesArePresentationOnlyAndUseTimelineTime() throws {
        var t = Tracker(name: "Carry", kind: .number)
        for index in 0..<30 {
            let date = now.addingTimeInterval(-Double(30 - index) * 86400)
            t.entries.append(Entry(occurredAt: date, localDay: t.day(date), value: String(index)))
        }
        t.entries.append(Entry(occurredAt: now.addingTimeInterval(86400), localDay: t.day(now), value: "999"))
        let row = WidgetRow(t, now: now)
        #expect(row.plot?.count == 24 && row.value == "29" && row.lastRecordedAt == now.addingTimeInterval(-86400))
        let timelineDate = now.addingTimeInterval(3600)
        let carry = try #require(row.carries(at: timelineDate).first)
        #expect(carry.end.date == timelineDate && carry.end.value == "29")
        #expect(row.plot?.count == 24 && row.carries(at: timelineDate).count == 1)
        let decoded = try JSONDecoder().decode(WidgetRow.self, from: JSONEncoder().encode(row))
        #expect(decoded.plot?.allSatisfy { $0.date <= now && $0.value != "999" } == true)
    }

    @Test func trackerPhotoNeverFallsBackToRecordPhotoAndProgressRoundTrips() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let photo = try #require(image.jpegData(compressionQuality: 0.8))
        var t = Tracker(name: "Tracker photo", kind: .number, cardBackground: .trackerPhoto)
        t.entries = [Entry(occurredAt: now, localDay: t.day(now), value: "10", photos: [photo])]
        #expect(WidgetRow(t, now: now).thumbnail == nil)
        t.photos = [photo]
        #expect(WidgetRow(t, now: now).hasPhoto)
        t.cardBackground = .progress
        t.rules = [GoalRule(period: .deadline, target: "20", effectiveAt: now, deadline: now.addingTimeInterval(100))]
        let row = WidgetRow(t, now: now)
        let decoded = try JSONDecoder().decode(WidgetRow.self, from: JSONEncoder().encode(row))
        #expect(decoded.progress == row.progress && decoded.progress?.baseline == "10" && decoded.thumbnail == nil)
    }
}
