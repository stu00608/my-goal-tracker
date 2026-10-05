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

    @Test(arguments: CardTextPosition.allCases) func optionalCardPreferencesRoundTripWithoutChangingLedger(position: CardTextPosition) throws {
        var tracker = Tracker(name: "精度 / Precision", kind: .number, timeZoneID: "Asia/Tokyo", cardBackground: .progress)
        tracker.cardTextPosition = position; tracker.showLastRecorded = false; tracker.ringStyle = .fraction
        tracker.entries = [Entry(occurredAt: now.addingTimeInterval(-1), localDay: "2024-03-09", value: "18.1234567890123456789"),
                           Entry(occurredAt: now, localDay: "2024-03-10", change: "0.0000000000000000001")]
        let original = tracker
        let row = try JSONDecoder().decode(WidgetRow.self, from: JSONEncoder().encode(WidgetRow(tracker, now: now)))
        #expect(row.resolvedTextPosition == position && !row.resolvedShowLastRecorded && row.resolvedRingStyle == .fraction)
        #expect(row.value == "18.123456789012345679" && tracker == original)
        #expect(row.lastRecordedDay == "2024-03-10" && row.tracker.timeZoneID == "Asia/Tokyo")
        #expect(row.tracker.cardTextPosition == position && row.tracker.showLastRecorded == false && row.tracker.ringStyle == .fraction)
    }

    @Test func oldSummaryDefaultsAndLegacyRecordedTimestampRemainReadable() throws {
        let tracker = Tracker(name: "Legacy", kind: .number, timeZoneID: "Asia/Tokyo")
        var row = WidgetRow(tracker, now: now); row.lastRecordedAt = now
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        for key in ["textPosition", "showLastRecorded", "ringStyle", "lastRecordedDay"] { object.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(WidgetRow.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.textPosition == nil && decoded.showLastRecorded == nil && decoded.ringStyle == nil && decoded.lastRecordedDay == nil)
        #expect(decoded.resolvedTextPosition == .bottomTrailing && decoded.resolvedShowLastRecorded && decoded.resolvedRingStyle == .percent)
        #expect(decoded.lastRecordedDate == now)
    }

    @Test(arguments: [1, 2]) func legacyBackupsWithoutCardPreferencesPreserveRawEntriesAndDates(version: Int) throws {
        var tracker = Tracker(name: "Legacy backup", kind: .number, timeZoneID: "America/New_York")
        tracker.entries = [Entry(occurredAt: now, localDay: "2024-03-09", value: "18.1234567890123456789")]
        if version == 2 {
            tracker.entries.append(Entry(occurredAt: now.addingTimeInterval(1), localDay: "2024-03-10", change: "0.0000000000000000001"))
        }
        var backup = Backup(trackers: [tracker]); backup.version = version
        let decoded = try Backup.decode(backup.encoded())
        let restored = try #require(decoded.trackers.first)
        #expect(restored.entries == tracker.entries && restored.timeZoneID == "America/New_York")
        #expect(restored.cardTextPosition == nil && restored.showLastRecorded == nil && restored.ringStyle == nil)
        let row = WidgetRow(restored, now: now.addingTimeInterval(1))
        #expect(row.resolvedTextPosition == .bottomTrailing && row.resolvedShowLastRecorded && row.resolvedRingStyle == .percent)
        #expect(row.lastRecordedDay == tracker.sortedEntries.last?.localDay)
    }

    @Test(arguments: [CardBackground.plot, .photo, .trackerPhoto, .map, .progress])
    func lastRecordedUsesRecordedLocalDayForBothKindsAcrossAllBackgrounds(background: CardBackground) throws {
        for kind in [TrackerKind.number, .daily] {
            var tracker = Tracker(name: "Recorded date", kind: kind, timeZoneID: "Asia/Tokyo", cardBackground: background)
            tracker.entries = [Entry(occurredAt: now, localDay: "2024-03-09", value: kind == .number ? "5" : nil),
                               Entry(occurredAt: now.addingTimeInterval(100), localDay: "2024-03-11", value: kind == .number ? "99" : nil)]
            let row = WidgetRow(tracker, now: now)
            #expect(row.lastRecordedAt == now && row.lastRecordedDay == "2024-03-09")
            #expect(row.lastRecordedDate == tracker.date(for: "2024-03-09") && row.resolvedShowLastRecorded)
            tracker.showLastRecorded = false
            #expect(!WidgetRow(tracker, now: now).resolvedShowLastRecorded)
        }
    }

    @Test func numericRingSharesAchievementEvidenceAfterRollbackAndFutureFiltering() throws {
        var tracker = Tracker(name: "Evidence", kind: .number, cardBackground: .progress)
        let rule = GoalRule(period: .deadline, target: "20", effectiveAt: now.addingTimeInterval(-100), deadline: now.addingTimeInterval(100))
        tracker.rules = [rule]
        tracker.entries = [Entry(occurredAt: now.addingTimeInterval(-200), localDay: tracker.day(now), value: "21"),
                           Entry(occurredAt: now, localDay: tracker.day(now), value: "10"),
                           Entry(occurredAt: now.addingTimeInterval(10), localDay: tracker.day(now), value: "50")]
        let result = try #require(GoalProgress.current(for: tracker, now: now))
        #expect(result.achieved == (tracker.achievement(for: rule, now: now) != nil) && result.fraction == 1 && result.current == "10")
        #expect(tracker.achievement(for: rule, now: now)?.achievedAt == rule.effectiveAt)
        tracker.entries.removeFirst()
        #expect(GoalProgress.current(for: tracker, now: now)?.achieved == (tracker.achievement(for: rule, now: now) != nil))
        #expect(GoalProgress.current(for: tracker, now: now)?.achieved == false)
        tracker.entries[0].value = "20"
        #expect(GoalProgress.current(for: tracker, now: now)?.achieved == true)
    }

    @Test func finiteAchievementRemainsSelectableAndClippingKeepsAccessibleValue() {
        var tracker = Tracker(name: "Finite", kind: .number, axisLower: "0", axisUpper: "10")
        tracker.lifecycle = .finite; tracker.cardTextPosition = .hidden; tracker.showLastRecorded = false
        tracker.rules = [GoalRule(period: .deadline, target: "15", effectiveAt: now.addingTimeInterval(-10), deadline: now.addingTimeInterval(10))]
        tracker.entries = [Entry(occurredAt: now, localDay: tracker.day(now), value: "15")]
        let snapshot = WidgetSnapshot([tracker], language: "en", now: now)
        #expect(snapshot.row(selectedID: tracker.id)?.id == tracker.id)
        #expect(snapshot.rows[0].accessibilityValue(at: now, locale: Locale(identifier: "en"), text: { $0 }).contains("1 records outside the chart bounds"))
        #expect(snapshot.rows[0].accessibilitySummary(at: now, locale: Locale(identifier: "en"), text: { $0 }).contains("Finite"))
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
        for key in ["background", "plot", "thumbnail", "locations", "progress", "ruleProgress", "axisLower", "axisUpper", "lastRecordedAt"] { rows[0].removeValue(forKey: key) }
        object["rows"] = rows
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.rows[0].id == tracker.id)
        #expect(decoded.rows[0].resolvedBackground == .plot)
        #expect(decoded.rows[0].plot == nil && decoded.rows[0].thumbnail == nil && decoded.rows[0].locations == nil)
        #expect(decoded.rows[0].progress == nil && decoded.rows[0].ruleProgress == nil && decoded.rows[0].axisLower == nil && decoded.rows[0].axisUpper == nil && decoded.rows[0].lastRecordedAt == nil)
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

    @Test func exactBoundsExcludeCollapsedDrawingValuesAndKeepMissingSidesOpen() throws {
        let values = ["12345678901234567890.1", "12345678901234567890.2", "12345678901234567890.3"]
        #expect(Set(values.compactMap(Numbers.plottedValue)).count == 1)
        #expect(!CardPlotScale.excludes(values[0], lower: values[0], upper: values[1]))
        #expect(!CardPlotScale.excludes(values[1], lower: values[0], upper: values[1]))
        #expect(CardPlotScale.excludes(values[2], lower: values[0], upper: values[1]))
        #expect(CardPlotScale.excludes(values[0], lower: values[1], upper: nil))
        #expect(CardPlotScale.excludes(values[2], lower: nil, upper: values[1]))
        #expect(!CardPlotScale.excludes(values[2], lower: values[1], upper: nil))
        #expect(!CardPlotScale.excludes(values[0], lower: nil, upper: values[1]))
        #expect(!CardPlotScale.excludes(values[2], lower: nil, upper: nil))
        #expect(!CardPlotScale.excludes(values[2], lower: "invalid", upper: "NaN"))
        #expect(!CardPlotScale.excludes(values[2], lower: values[1], upper: values[0]))
        var t = Tracker(name: "Exact bounds", kind: .number, axisLower: values[0], axisUpper: values[1])
        t.entries = values.enumerated().map { index, value in
            let date = now.addingTimeInterval(Double(index - 2))
            return Entry(occurredAt: date, localDay: t.day(date), value: value)
        }
        let original = t, row = WidgetRow(t, now: now)
        #expect(row.plot?.compactMap(\.plottedValue).allSatisfy { row.plotDomain.contains($0) } == true)
        #expect(row.clippedPointCount == 1 && t == original)
        let decoded = try JSONDecoder().decode(WidgetRow.self, from: JSONEncoder().encode(row))
        #expect(decoded.plot?.map(\.value) == values && decoded.value == values[2])
    }

    @Test func lineClippingKeepsExactBoundsWhenDrawingValuesCollapse() {
        let values = ["12345678901234567890.1", "12345678901234567890.2", "12345678901234567890.3"]
        let points = [CardPlotPoint(date: now, value: values[0]),
                      CardPlotPoint(date: now.addingTimeInterval(20), value: values[2])]
        let original = points
        #expect(Set(values.compactMap(Numbers.plottedValue)).count == 1)
        #expect(CardPlotScale.clippedSegments(points, lower: values[0], upper: values[1]) == [
            CardPlotSegment(id: 0, start: points[0],
                            end: CardPlotPoint(date: now.addingTimeInterval(10), value: values[1]))
        ])
        for value in values {
            let constant = points.map { CardPlotPoint(date: $0.date, value: value) }
            let segments = CardPlotScale.clippedSegments(constant, lower: values[0], upper: values[1])
            #expect(segments.isEmpty == (value == values[2]))
            if let segment = segments.first { #expect(segment.start == constant[0] && segment.end == constant[1]) }
        }
        #expect(points == original)
    }

    @Test func lineClippingPreservesCrossingsOpenSidesAndExcludedGaps() throws {
        let points = [CardPlotPoint(date: now, value: "-5"),
                      CardPlotPoint(date: now.addingTimeInterval(20), value: "15")]
        let low = CardPlotPoint(date: now.addingTimeInterval(5), value: "0")
        let high = CardPlotPoint(date: now.addingTimeInterval(15), value: "10")
        #expect(CardPlotScale.clippedSegments(points, lower: "0", upper: "10") == [CardPlotSegment(id: 0, start: low, end: high)])
        let falling = [CardPlotPoint(date: now, value: "15"), CardPlotPoint(date: points[1].date, value: "-5")]
        #expect(CardPlotScale.clippedSegments(falling, lower: "0", upper: "10") == [
            CardPlotSegment(id: 0, start: CardPlotPoint(date: low.date, value: "10"),
                            end: CardPlotPoint(date: high.date, value: "0"))
        ])
        #expect(CardPlotScale.clippedSegments(points, lower: "0") == [CardPlotSegment(id: 0, start: low, end: points[1])])
        #expect(CardPlotScale.clippedSegments(points, upper: "10") == [CardPlotSegment(id: 0, start: points[0], end: high)])
        let unbounded = [CardPlotSegment(id: 0, start: points[0], end: points[1])]
        #expect(CardPlotScale.clippedSegments(points) == unbounded)
        #expect(CardPlotScale.clippedSegments(points, lower: "invalid", upper: "NaN") == unbounded)
        for bounds in [("10", "0"), ("10", "10")] {
            #expect(CardPlotScale.clippedSegments(points, lower: bounds.0, upper: bounds.1) == unbounded)
        }
        for values in [["5", "15", "15", "5"], ["5", "-5", "-5", "5"]] {
            let gap = values.enumerated().map { CardPlotPoint(date: now.addingTimeInterval(Double($0.offset * 10)), value: $0.element) }
            let boundary = values[1] == "15" ? "10" : "0"
            #expect(CardPlotScale.clippedSegments(gap, lower: "0", upper: "10") == [
                CardPlotSegment(id: 0, start: gap[0], end: CardPlotPoint(date: now.addingTimeInterval(5), value: boundary)),
                CardPlotSegment(id: 2, start: CardPlotPoint(date: now.addingTimeInterval(25), value: boundary), end: gap[3])
            ])
        }
        let thirds = [CardPlotPoint(date: now, value: "-1"), CardPlotPoint(date: now.addingTimeInterval(30), value: "2")]
        let repeating = try #require(CardPlotScale.clippedSegments(thirds, lower: "0", upper: "1").first)
        #expect(repeating.start.value == "0" && repeating.end.value == "1")
        #expect(abs(repeating.start.date.timeIntervalSince(now) - 10) < 0.000001)
        #expect(abs(repeating.end.date.timeIntervalSince(now) - 20) < 0.000001)
    }

    @Test func lineClippingHandlesDuplicateDatesAndDropsUnsafeAdjacentPairs() {
        let vertical = [CardPlotPoint(date: now, value: "-5"), CardPlotPoint(date: now, value: "15")]
        #expect(CardPlotScale.clippedSegments(vertical, lower: "0", upper: "10") == [
            CardPlotSegment(id: 0, start: CardPlotPoint(date: now, value: "0"), end: CardPlotPoint(date: now, value: "10"))
        ])
        let invalid = [CardPlotPoint(date: now, value: "5"), CardPlotPoint(date: now, value: "invalid"),
                       CardPlotPoint(date: now, value: "5")]
        #expect(CardPlotScale.clippedSegments(invalid).isEmpty)
        let overflow = [CardPlotPoint(date: Date(timeIntervalSinceReferenceDate: -Double.greatestFiniteMagnitude), value: "-5"),
                        CardPlotPoint(date: Date(timeIntervalSinceReferenceDate: Double.greatestFiniteMagnitude), value: "15")]
        #expect(CardPlotScale.clippedSegments(overflow, lower: "0", upper: "10").isEmpty)
        #expect(CardPlotScale.clippedSegments([vertical[0]]).isEmpty)
        #expect(CardPlotScale.clippedSegments([]).isEmpty)
    }

    @Test func numericWidgetSelectsNextRuleAtExactBoundaryWithoutSharingLedger() throws {
        let effective = now.addingTimeInterval(-86400), next = now.addingTimeInterval(100)
        var t = Tracker(name: "Rule change", kind: .number, cardBackground: .progress)
        t.rules = [GoalRule(period: .deadline, target: "20", effectiveAt: effective, deadline: next),
                   GoalRule(period: .deadline, target: "30", effectiveAt: next, deadline: next.addingTimeInterval(100)),
                   GoalRule(period: .deadline, target: "40", effectiveAt: next.addingTimeInterval(200), deadline: next.addingTimeInterval(300))]
        t.entries = [Entry(occurredAt: effective, localDay: t.day(effective), value: "10", note: "private baseline"),
                     Entry(occurredAt: now, localDay: t.day(now), change: "5", note: "private delta"),
                     Entry(occurredAt: next, localDay: t.day(next), value: "30")]
        let original = t, row = WidgetRow(t, now: now)
        let before = try #require(row.currentProgress(at: next.addingTimeInterval(-1)))
        #expect(before.baseline == "10" && before.current == "15" && before.target == "20" && before.fraction == 0.5)
        let after = try #require(row.currentProgress(at: next))
        #expect(after.baseline == "15" && after.current == "15" && after.target == "30" && after.fraction == 0 && !after.achieved)
        #expect(row.currentProgress(at: next.addingTimeInterval(1)) == after)
        #expect(row.plotDomain(at: next.addingTimeInterval(-1)) == row.plotDomain)
        #expect(row.plotDomain(at: next).contains(30) && !row.plotDomain.contains(30))
        var bounded = row; bounded.axisLower = "0"; bounded.axisUpper = "10"
        #expect(bounded.plotDomain(at: next) == 0...10)
        #expect(row.rules.count == 2 && row.ruleProgress?.count == 2 && t == original)
        let data = try JSONEncoder().encode(row)
        let encoded = String(decoding: data, as: UTF8.self)
        #expect(!encoded.contains("private baseline") && !encoded.contains("private delta") && !encoded.contains("\"entries\"") && !encoded.contains("\"change\""))
        let decoded = try JSONDecoder().decode(WidgetRow.self, from: data)
        #expect(decoded.currentProgress(at: next) == after && decoded.plot == nil)
    }

    @Test func numericWidgetProjectionsRespectDeadlineAndHistoricalAchievement() throws {
        let effective = now.addingTimeInterval(-86400), deadline = now.addingTimeInterval(-10), next = now.addingTimeInterval(100)
        var t = Tracker(name: "Deadline", kind: .number, cardBackground: .progress)
        t.rules = [GoalRule(period: .deadline, target: "20", effectiveAt: effective, deadline: deadline),
                   GoalRule(period: .deadline, target: "100", effectiveAt: next, deadline: next.addingTimeInterval(100))]
        t.entries = [Entry(occurredAt: effective, localDay: t.day(effective), value: "10"),
                     Entry(occurredAt: deadline, localDay: t.day(deadline), value: "15"),
                     Entry(occurredAt: now, localDay: t.day(now), value: "99"),
                     Entry(occurredAt: next.addingTimeInterval(100), localDay: t.day(next), value: "100")]
        let row = WidgetRow(t, now: now)
        #expect(row.currentProgress(at: now)?.current == "15" && row.currentProgress(at: now)?.fraction == 0.5)
        let future = try #require(row.currentProgress(at: next.addingTimeInterval(100)))
        #expect(future.target == "100" && future.baseline == "99" && future.current == "99" && future.fraction == 0 && !future.achieved)
        t.entries.append(Entry(occurredAt: deadline.addingTimeInterval(-1), localDay: t.day(deadline), value: "100"))
        let achieved = WidgetRow(t, now: now)
        #expect(achieved.currentProgress(at: now)?.current == "15" && achieved.currentProgress(at: now)?.fraction == 1)
        #expect(achieved.currentProgress(at: next)?.current == "99" && achieved.currentProgress(at: next)?.fraction == 1)
    }

    @Test func legacyNumericProgressDecodesAndStopsAtRuleBoundary() throws {
        let next = now.addingTimeInterval(100)
        var t = Tracker(name: "Legacy progress", kind: .number, cardBackground: .progress)
        t.rules = [GoalRule(period: .deadline, target: "20", effectiveAt: now, deadline: next),
                   GoalRule(period: .deadline, target: "30", effectiveAt: next, deadline: next.addingTimeInterval(100))]
        t.entries = [Entry(occurredAt: now, localDay: t.day(now), value: "10")]
        let row = WidgetRow(t, now: now)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        object.removeValue(forKey: "ruleProgress")
        let decoded = try JSONDecoder().decode(WidgetRow.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.ruleProgress == nil && decoded.currentProgress(at: now) == row.progress)
        #expect(decoded.currentProgress(at: next.addingTimeInterval(-1))?.target == "20")
        #expect(decoded.currentProgress(at: next) == nil && decoded.currentProgress(at: next.addingTimeInterval(1)) == nil)
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
