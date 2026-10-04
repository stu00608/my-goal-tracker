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

/// Separate series: these are drawing coordinates, never ledger records or selectable samples.
nonisolated struct CardCarrySegment: Identifiable, Equatable {
    var id: String
    var start: CardPlotPoint
    var end: CardPlotPoint

    static func segments(points: [CardPlotPoint], interval: DateInterval, now: Date) -> [Self] {
        let end = min(now, interval.end)
        guard end >= interval.start else { return [] }
        let known = points.filter {
            $0.date <= end && $0.date < interval.end && $0.plottedValue != nil
        }.sorted { $0.date < $1.date }
        let actual = known.filter { $0.date >= interval.start }
        var result: [Self] = []
        if let prior = known.last(where: { $0.date < interval.start }) {
            let stop = actual.first?.date ?? end
            if stop > interval.start {
                result.append(Self(id: "leading", start: CardPlotPoint(date: interval.start, value: prior.value),
                                   end: CardPlotPoint(date: stop, value: prior.value)))
            }
        }
        if let last = actual.last, last.date < end {
            result.append(Self(id: "trailing", start: last, end: CardPlotPoint(date: end, value: last.value)))
        }
        return result
    }
}

nonisolated struct GoalProgress: Codable, Equatable {
    var baseline: String
    var current: String
    var target: String
    var fraction: Double
    var achieved: Bool

    /// Picker eligibility depends on the goal configuration; an empty tracker can select it.
    static func available(for tracker: Tracker, now: Date = Date()) -> Bool {
        guard let rule = tracker.rule(at: now), let target = Numbers.decimal(rule.target), !target.isNaN else { return false }
        if tracker.kind == .daily { return rule.period != .deadline && (Int(rule.target) ?? 0) > 0 }
        return rule.period == .deadline && rule.deadline != nil
    }

    static func current(for tracker: Tracker, now: Date = Date()) -> Self? {
        guard available(for: tracker, now: now), let rule = tracker.rule(at: now) else { return nil }
        if tracker.kind == .daily {
            let count = tracker.count(in: tracker.interval(now, period: rule.period))
            guard let target = Int(rule.target), target > 0 else { return nil }
            return Self(baseline: "0", current: String(count), target: rule.target,
                        fraction: min(Double(count) / Double(target), 1), achieved: count >= target)
        }
        guard let deadline = rule.deadline, let target = Numbers.decimal(rule.target) else { return nil }
        let cutoff = min(now, deadline)
        let entries = tracker.resolvedEntries.filter { $0.occurredAt <= cutoff && $0.value.flatMap(Numbers.decimal)?.isNaN == false }
        guard let first = entries.first, let last = entries.last else { return nil }
        let baselineEntry = entries.last(where: { $0.occurredAt <= rule.effectiveAt }) ?? first
        guard let baselineString = baselineEntry.value, let currentString = last.value,
              let baseline = Numbers.decimal(baselineString), let current = Numbers.decimal(currentString) else { return nil }
        // Match deadline achievement, including a hit followed by rollback, excluding future events.
        let achieved = entries.contains {
            guard let value = $0.value.flatMap(Numbers.decimal) else { return false }
            return rule.direction == .up ? value >= target : value <= target
        }
        let fraction: Double
        if achieved || target == baseline { fraction = 1 }
        else {
            var a = current, b = baseline, c = target, numerator = Decimal(), denominator = Decimal(), ratio = Decimal()
            guard NSDecimalSubtract(&numerator, &a, &b, .plain) == .noError,
                  NSDecimalSubtract(&denominator, &c, &b, .plain) == .noError, denominator != 0,
                  NSDecimalDivide(&ratio, &numerator, &denominator, .plain) != .overflow, !ratio.isNaN else { return nil }
            let plotted = NSDecimalNumber(decimal: ratio).doubleValue
            guard plotted.isFinite else { return nil }
            fraction = min(max(plotted, 0), 1)
        }
        return Self(baseline: baselineString, current: currentString, target: rule.target, fraction: fraction, achieved: achieved)
    }
}

/// Overview charts keep context: at least 10% of the value magnitude and ten precision ticks.
/// Extrema still fit with 25% range padding; near-flat growth is never enlarged corner-to-corner.
nonisolated enum CardPlotScale {
    static func domain(points: [CardPlotPoint], precision: Int, completion: Bool = false,
                       lower: String? = nil, upper: String? = nil) -> ClosedRange<Double> {
        if completion { return 0...2 }
        let values = points.compactMap(\.plottedValue)
        let low = values.min() ?? 0, high = values.max() ?? 1
        let quantum = pow(10.0, -Double(max(0, min(8, precision))))
        let span = max(high - low, max(abs(low), abs(high)) * 0.1, quantum * 10)
        let midpoint = low / 2 + high / 2
        let automatic = values.isEmpty ? 0...1 : (midpoint - span * 0.75)...(midpoint + span * 0.75)
        func bound(_ string: String?) -> Double? {
            guard let value = string.flatMap(Numbers.decimal), !value.isNaN else { return nil }
            let number = NSDecimalNumber(decimal: value).doubleValue
            return number.isFinite ? number : nil
        }
        let lowerDecimal = lower.flatMap(Numbers.decimal), upperDecimal = upper.flatMap(Numbers.decimal)
        let lower = bound(lower), upper = bound(upper)
        if let lower, let upper, let lowerDecimal, let upperDecimal {
            guard lowerDecimal < upperDecimal else { return automatic }
            return lower...max(upper, lower.nextUp)
        }
        // At large magnitudes a precision tick may round away; require a representable positive span.
        if let lower { return lower...max(automatic.upperBound, lower + quantum, lower.nextUp) }
        if let upper { return min(automatic.lowerBound, upper - quantum, upper.nextDown)...upper }
        return automatic
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
    var progress: GoalProgress?
    var axisLower: String?
    var axisUpper: String?
    var lastRecordedAt: Date?

    init(_ t: Tracker, now: Date) {
        let sorted = t.resolvedEntries.filter { $0.occurredAt <= now }
        id = t.id; name = t.name; kind = t.kind; value = sorted.last?.value
        unit = t.unit; precision = t.precision; timeZoneID = t.timeZoneID
        background = t.resolvedCardBackground
        axisLower = t.axisLower; axisUpper = t.axisUpper
        progress = GoalProgress.current(for: t, now: now)
        lastRecordedAt = sorted.last(where: { $0.value.flatMap(Numbers.decimal)?.isNaN == false })?.occurredAt
        let week = t.interval(now, period: .weekly)
        let month = t.interval(now, period: .monthly)
        completedDays = t.kind == .daily ? Array(Set(t.entries.compactMap { entry -> String? in
            guard let date = t.date(for: entry.localDay),
                  date >= min(week.start, month.start), date < max(week.end, month.end) else { return nil }
            return entry.localDay
        })).sorted() : []
        rules = [t.rule(at: now), t.rules.filter { $0.effectiveAt > now }.min { $0.effectiveAt < $1.effectiveAt }].compactMap { $0 }
        let entries = sorted
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
        if t.resolvedCardBackground == .trackerPhoto, let data = t.photos?.first {
            thumbnail = Self.makeThumbnail(data)
        }
        if t.resolvedCardBackground == .map {
            locations = Array(sorted.compactMap(\.location).filter(\.isValid).suffix(24))
        }
    }
    var resolvedBackground: CardBackground { background ?? .plot }
    func currentProgress(at date: Date) -> GoalProgress? {
        kind == .daily ? GoalProgress.current(for: tracker, now: date) : progress
    }
    var hasPhoto: Bool { (resolvedBackground == .photo || resolvedBackground == .trackerPhoto) && thumbnail != nil }
    var plotDomain: ClosedRange<Double> {
        let target = progress.map { CardPlotPoint(date: .distantPast, value: $0.target) }
        return CardPlotScale.domain(points: (plot ?? []) + [target].compactMap { $0 }, precision: precision,
                                    completion: kind == .daily, lower: axisLower, upper: axisUpper)
    }
    var clippedPointCount: Int { (plot ?? []).compactMap(\.plottedValue).filter { !plotDomain.contains($0) }.count }
    func carries(at now: Date) -> [CardCarrySegment] {
        guard kind == .number, let points = plot, let start = points.first?.date else { return [] }
        // A half-open display window includes an actual sample exactly at the timeline instant.
        return CardCarrySegment.segments(points: points, interval: DateInterval(start: start, end: max(start, now).addingTimeInterval(1)), now: now)
    }
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
        rows = trackers.filter { !$0.archived }.map { WidgetRow($0, now: now) }
    }
    // A configured deleted/archived tracker stays unavailable instead of silently switching goals.
    func row(selectedID: UUID?) -> WidgetRow? {
        guard let selectedID else { return rows.first }
        return rows.first { $0.id == selectedID }
    }
    static func read() -> WidgetSnapshot? {
        url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
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
