import Foundation

nonisolated enum ChartRange: String, CaseIterable {
    case thirtyDays, ninetyDays, all, custom

    var title: String {
        switch self {
        case .thirtyDays: "30 days"
        case .ninetyDays: "90 days"
        case .all: "All"
        case .custom: "Custom"
        }
    }

    func snapshot(for tracker: Tracker, now: Date, customStart: Date, customEnd: Date) -> ChartSnapshot? {
        let calendar = tracker.calendar
        let today = calendar.startOfDay(for: now)
        let start: Date
        let end: Date
        switch self {
        case .thirtyDays, .ninetyDays:
            guard let first = calendar.date(byAdding: .day, value: self == .thirtyDays ? -29 : -89, to: today),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
            start = first
            end = nextDay
        case .all:
            let first = tracker.sortedEntries.first { $0.occurredAt <= now }?.occurredAt ?? today
            start = calendar.startOfDay(for: first)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
            end = nextDay
        case .custom:
            start = calendar.startOfDay(for: customStart)
            let lastDay = calendar.startOfDay(for: customEnd)
            guard start <= lastDay, let nextDay = calendar.date(byAdding: .day, value: 1, to: lastDay) else { return nil }
            end = nextDay
        }
        let entries = tracker.sortedEntries.filter {
            $0.occurredAt >= start && $0.occurredAt < end && (self == .custom || $0.occurredAt <= now)
        }
        return ChartSnapshot(interval: DateInterval(start: start, end: end), entries: entries)
    }
}

nonisolated struct ChartSnapshot {
    let interval: DateInterval
    let entries: [Entry]

    var numericEntries: [Entry] {
        entries.filter { entry in
            guard let value = entry.value.flatMap(Numbers.decimal) else { return false }
            return !value.isNaN
        }
    }
    var periodChange: Decimal? {
        let values = numericEntries.compactMap { $0.value.flatMap(Numbers.decimal) }
        guard values.count > 1, let first = values.first, let last = values.last else { return nil }
        return last - first
    }
}

nonisolated enum CompletionCalendarCell: Identifiable {
    case weekday(Int)
    case padding(Int)
    case day(Date, localDay: String)

    var id: String {
        switch self {
        case .weekday(let index): "calendar.weekday.\(index)"
        case .padding(let index): "calendar.padding.\(index)"
        case .day(_, let localDay): "calendar.day." + localDay
        }
    }

    static func month(for tracker: Tracker, containing date: Date) -> [Self] {
        let calendar = tracker.calendar
        guard let window = calendar.dateInterval(of: .month, for: date),
              let days = calendar.range(of: .day, in: .month, for: date) else { return [] }
        let offset = (calendar.component(.weekday, from: window.start) + 5) % 7
        return (0..<7).map { .weekday($0) } + (0..<offset).map { .padding($0) } + days.compactMap { day in
            guard let instant = calendar.date(byAdding: .day, value: day - 1, to: window.start) else { return nil }
            return .day(instant, localDay: tracker.day(instant))
        }
    }
}
