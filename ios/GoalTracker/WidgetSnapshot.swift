import Foundation
import ImageIO
#if WIDGETS
import WidgetKit
#endif

nonisolated struct CardPlotPoint: Codable, Equatable {
    var date: Date
    // Source precision stays intact; Double is used only to draw the chart.
    var value: String
    var plottedValue: Double? {
        guard let decimal = Numbers.decimal(value) else { return nil }
        let number = NSDecimalNumber(decimal: decimal).doubleValue
        return number.isFinite ? number : nil
    }
}

// Bounded presentation data only; original photos, notes and the database stay in the app.
nonisolated struct WidgetRow: Codable, Identifiable {
    var id: UUID
    var name: String
    var kind: TrackerKind
    var value: String?
    var unit: String
    var precision: Int
    var timeZoneID: String
    var completedDays: [String]
    var rules: [GoalRule]
    // Optional additions allow older published summaries to decode.
    var background: CardBackground?
    var plot: [CardPlotPoint]?
    var thumbnail: Data?
    var locations: [RecordedLocation]?

    init(_ t: Tracker, now: Date) {
        let sorted = t.sortedEntries
        id = t.id; name = t.name; kind = t.kind; value = sorted.last?.value
        unit = t.unit; precision = t.precision; timeZoneID = t.timeZoneID
        background = t.resolvedCardBackground
        let week = t.interval(now, period: .weekly)
        let month = t.interval(now, period: .monthly)
        completedDays = t.kind == .daily ? Array(Set(t.entries.compactMap { entry -> String? in
            guard let date = t.date(for: entry.localDay),
                  date >= min(week.start, month.start), date < max(week.end, month.end) else { return nil }
            return entry.localDay
        })).sorted() : []
        rules = [t.rule(at: now), t.rules.filter { $0.effectiveAt > now }.min { $0.effectiveAt < $1.effectiveAt }].compactMap { $0 }
        let entries = sorted.filter { $0.occurredAt <= now }
        if t.resolvedCardBackground == .plot {
            if t.kind == .number {
                plot = Array(entries.compactMap { entry -> CardPlotPoint? in
                    guard let value = entry.value, Numbers.decimal(value) != nil else { return nil }
                    return CardPlotPoint(date: entry.occurredAt, value: value)
                }.suffix(24))
            } else {
                plot = Array(Set(entries.map(\.localDay))).sorted().suffix(14).compactMap {
                    t.date(for: $0).map { CardPlotPoint(date: $0, value: "1") }
                }
            }
        }
        if t.resolvedCardBackground == .photo,
           let data = sorted.reversed().first(where: { !$0.photos.isEmpty })?.photos.first {
            thumbnail = Self.makeThumbnail(data)
        }
        if t.resolvedCardBackground == .map {
            locations = Array(sorted.compactMap(\.location).filter(\.isValid).suffix(24))
        }
    }
    var resolvedBackground: CardBackground { background ?? .plot }
    var recordURL: URL { URL(string: "goaltracker://record/" + id.uuidString)! }

    var tracker: Tracker {
        var t = Tracker(id: id, name: name, kind: kind, unit: unit, precision: precision, timeZoneID: timeZoneID)
        t.rules = rules
        t.cardBackground = background
        t.entries = completedDays.map { Entry(occurredAt: .distantPast, localDay: $0) }
        return t
    }
    static func makeThumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 320
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.65] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= 60_000 else { return nil }
        return output as Data
    }
}

nonisolated struct WidgetSnapshot: Codable {
    static let group = "group.com.stu00608.mygoaltracker"
    static let kind = "GoalTrackerProgress"
    var language: String
    var rows: [WidgetRow]

    init(_ trackers: [Tracker], language: String, now: Date = Date()) {
        self.language = language
        rows = trackers.filter { !$0.archived }.prefix(3).map { WidgetRow($0, now: now) }
    }
    static var url: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("widget-snapshot.json") }
    func nextRefresh(after date: Date) -> Date {
        let boundaries = rows.compactMap { row in
            let c = row.tracker.calendar
            return c.date(byAdding: .day, value: 1, to: c.startOfDay(for: date))
        } + rows.flatMap { $0.rules.map(\.effectiveAt).filter { $0 > date } }
        return boundaries.min() ?? date.addingTimeInterval(3600)
    }
    #if WIDGETS
    @MainActor static func publish(_ trackers: [Tracker]) throws {
        guard let url else { throw DataError.saveFailed }
        try JSONEncoder().encode(WidgetSnapshot(trackers, language: L.language)).write(to: url, options: .atomic)
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }
    #endif
}
