import Testing
import SwiftUI
import UIKit
import MapKit
@testable import GoalTracker

@MainActor struct PresentationTests {
    private let now = ISO8601DateFormatter().date(from: "2024-03-10T12:00:00Z")!

    @Test func mapPositionsResolveLegacyBottomWithoutMutatingSavedPreference() {
        #expect(CardTextPosition.available(for: .map) == [.topLeading, .topTrailing, .hidden])
        var tracker = Tracker(name: "MAP", kind: .daily, cardBackground: .map)
        for (saved, expected) in [(CardTextPosition.bottomLeading, CardTextPosition.topLeading), (.bottomTrailing, .topTrailing), (.hidden, .hidden)] {
            tracker.cardTextPosition = saved
            #expect(WidgetRow(tracker, now: now).resolvedTextPosition == expected)
            #expect(tracker.cardTextPosition == saved)
            tracker.cardBackground = .plot
            #expect(WidgetRow(tracker, now: now).resolvedTextPosition == saved)
            tracker.cardBackground = .map
        }
    }

    @Test func mapFramingKeepsPinsBelowCopyAndRetainsEveryLocation() throws {
        let locations = [RecordedLocation(latitude: 35.68, longitude: 139.76),
                         RecordedLocation(latitude: 35.69, longitude: 139.77)]
        let hidden = try #require(CardMapFraming.rect(locations: locations, textPosition: .hidden))
        for position in [CardTextPosition.topLeading, .topTrailing] {
            let frame = try #require(CardMapFraming.rect(locations: locations, textPosition: position))
            for location in locations {
                #expect(frame.contains(MKMapPoint(CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude))))
            }
            let y = (hidden.midY - frame.minY) / frame.height
            let x = (hidden.midX - frame.minX) / frame.width
            #expect(y > 0.65 && y < 0.75)
            #expect(position == .topLeading ? x > 0.6 : x < 0.4)
        }
        #expect(CardMapFraming.rect(locations: [], textPosition: .topLeading) == nil)
    }

    @Test(arguments: ["en", "ja", "zh-Hant"])
    func ringCenterKeepsTrueFractionAndHiddenTextKeepsFullSummary(language: String) throws {
        let locale = Locale(identifier: language)
        var tracker = Tracker(name: String(repeating: "Very long 名稱 名前 ", count: 6), kind: .daily, timeZoneID: "Asia/Tokyo", cardBackground: .progress)
        tracker.rules = [GoalRule(period: .weekly, target: "2", effectiveAt: now.addingTimeInterval(-86400 * 7))]
        tracker.entries = (0..<3).map { offset in
            let date = now.addingTimeInterval(-Double(offset) * 86400)
            return Entry(occurredAt: date, localDay: tracker.day(date))
        }
        var row = WidgetRow(tracker, now: now)
        row.ringStyle = .fraction
        #expect(row.ringText(at: now, locale: locale) == "3 / 2")
        row.ringStyle = .percent
        #expect(row.ringText(at: now, locale: locale) == 1.0.formatted(.percent.precision(.fractionLength(0)).locale(locale)))
        let summary = row.accessibilitySummary(at: now, locale: locale, text: { $0 })
        for position in CardTextPosition.allCases {
            row.textPosition = position; row.showLastRecorded = false
            #expect(row.accessibilitySummary(at: now, locale: locale, text: { $0 }) == summary)
            #expect(summary.contains(tracker.name) && summary.contains("3 / 2") && summary.contains("Today is recorded") && summary.contains("Last recorded"))
        }
    }

    @Test(arguments: CardTextPosition.allCases)
    func tintedPhotoFadeProtectsChosenCornerAndHiddenRetainsImage(position: CardTextPosition) throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80), format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        let display = CardAccentedPhoto.make(source, size: CGSize(width: 160, height: 160), position: position, increasedContrast: false)
        let image = try #require(display.cgImage)
        #expect(image.width == 320 && image.height == 320)
        let corner = position.gradientEnd, opposite = position.gradientStart
        let chosen = try brightness(image, x: corner.x < 0.5 ? 20 : 299, y: corner.y < 0.5 ? 20 : 299)
        let other = try brightness(image, x: opposite.x < 0.5 ? 20 : 299, y: opposite.y < 0.5 ? 20 : 299)
        if position == .hidden { #expect(chosen > 0.95 && other > 0.95) }
        else {
            #expect(chosen < 0.55 && other > 0.95)
            let stronger = CardAccentedPhoto.make(source, size: CGSize(width: 160, height: 160), position: position, increasedContrast: true)
            let strong = try brightness(#require(stronger.cgImage), x: corner.x < 0.5 ? 20 : 299, y: corner.y < 0.5 ? 20 : 299)
            #expect(strong < chosen)
        }
    }

    /// Source render fixtures for Master to execute; these do not replace real Widget/AX screenshots.
    @Test(arguments: CardTextPosition.allCases, [CardBackground.plot, .photo, .map, .progress])
    func nativeCardRenderFixtures(position: CardTextPosition, background: CardBackground) throws {
        var tracker = Tracker(name: "Very long card title 很長的標題 とても長いタイトル", kind: .number,
                              unit: "kg", precision: 3, timeZoneID: "Asia/Tokyo", cardBackground: background)
        tracker.cardTextPosition = position
        tracker.rules = [GoalRule(period: .deadline, target: "20", effectiveAt: now.addingTimeInterval(-200), deadline: now.addingTimeInterval(200))]
        tracker.entries = [Entry(occurredAt: now.addingTimeInterval(-200), localDay: tracker.day(now), value: "10"),
                           Entry(occurredAt: now, localDay: tracker.day(now), change: "5")]
        let source = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { renderer in
            UIColor.systemYellow.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            UIColor.systemBlue.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let original = tracker
        var row = WidgetRow(tracker, now: now)
        if background == .photo {
            let thumbnail = source.jpegData(compressionQuality: 0.8)
            let photoData: Data = try #require(thumbnail)
            row.thumbnail = photoData
        }
        if background == .map { row.locations = [RecordedLocation(latitude: 35, longitude: 139)] }
        for style in RingProgressStyle.allCases {
            row.ringStyle = style
            for monochrome in [false, true] {
                for language in ["en", "ja", "zh-Hant"] {
                    let locale = Locale(identifier: language)
                    // Compact Widget-sized fixture; the real Widget still owns its native container.
                    let compact = ZStack {
                        TrackerCardBackdrop(row: row, text: { $0 }, now: now, locale: locale, mapImage: source, monochrome: monochrome)
                        if background == .progress {
                            TrackerCardLabel(row: row, now: now, locale: locale, text: { $0 }, compact: true, monochrome: monochrome)
                                .frame(width: CardLayout.ringTextWidth(in: CGSize(width: 172, height: 172)))
                                .frame(width: 172, height: 172)
                        } else {
                            TrackerCardLabel(row: row, now: now, locale: locale, text: { $0 }, compact: true, monochrome: monochrome)
                                .padding(CardLayout.textInset)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: row.resolvedTextPosition.alignment)
                        }
                    }.frame(width: 172, height: 172)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .environment(\.colorScheme, monochrome ? .dark : .light)
                        .environment(\.dynamicTypeSize, .xxxLarge)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    let widgetRenderer = ImageRenderer(content: compact); widgetRenderer.scale = 1
                    let widgetImage = try #require(widgetRenderer.uiImage)
                    #expect(widgetImage.size == CGSize(width: 172, height: 172))
                    let fixtureName = "\(background.rawValue)-\(position.rawValue)-\(style.rawValue)-\(language)-\(monochrome ? "mono" : "color")"
                    Attachment.record(widgetImage, named: "widget-sized-" + fixtureName + ".png", as: .png)
                    // Unbounded-height app list fixture at AX max must fit its full text vertically.
                    let app = TrackerCardSurface(row: row, now: now, locale: locale, text: { $0 }, minimumHeight: 164, fillsHeight: false) {
                        TrackerCardBackdrop(row: row, text: { $0 }, now: now, locale: locale, mapImage: source)
                    }.frame(width: 320).environment(\.dynamicTypeSize, .accessibility5)
                    let appRenderer = ImageRenderer(content: app); appRenderer.scale = 1
                    let appImage = try #require(appRenderer.uiImage)
                    #expect(appImage.size.width == 320 && appImage.size.height >= 164)
                    Attachment.record(appImage, named: "app-AX-" + fixtureName + ".png", as: .png)
                }
            }
        }
        #expect(tracker == original && tracker.entries[1].value == nil && tracker.entries[1].change == "5")
    }

    private func brightness(_ image: CGImage, x: Int, y: Int) throws -> Double {
        let pixel = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        return try bytes.withUnsafeMutableBytes { storage in
            let context = try #require(CGContext(data: storage.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return (Double(storage[0]) + Double(storage[1]) + Double(storage[2])) / (3 * 255)
        }
    }
}
