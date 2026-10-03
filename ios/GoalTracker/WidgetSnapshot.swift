import Foundation
#if WIDGETS
import WidgetKit
#endif

// Only summary data crosses into the shared container; the app owns the database and photos.
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

    var tracker: Tracker {
        var t = Tracker(id: id, name: name, kind: kind, unit: unit, precision: precision, timeZoneID: timeZoneID)
        t.rules = rules
        t.entries = completedDays.map { Entry(occurredAt: .distantPast, localDay: $0) }
        return t
    }
}

nonisolated struct WidgetSnapshot: Codable {
    static let group = "group.com.stu00608.mygoaltracker"
    static let kind = "GoalTrackerProgress"
    var language: String
    var rows: [WidgetRow]

    init(_ trackers: [Tracker], language: String) {
        self.language = language
        rows = trackers.filter { !$0.archived }.map { t in
            WidgetRow(id: t.id, name: t.name, kind: t.kind, value: t.latest?.value,
                      unit: t.unit, precision: t.precision, timeZoneID: t.timeZoneID,
                      completedDays: t.kind == .daily ? t.entries.map(\.localDay) : [], rules: t.rules)
        }
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
