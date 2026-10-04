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

nonisolated struct CompletionPeriodProgress: Identifiable {
    let interval: DateInterval
    let count: Int
    let target: Int?
    let period: Period
    let partial: Bool
    var id: Date { interval.start }
    var fraction: Double {
        guard let target, target > 0 else { return 0 }
        return min(Double(count) / Double(target), 1)
    }
}

nonisolated enum CompletionProgressData {
    static func current(for tracker: Tracker, now: Date) -> CompletionPeriodProgress? {
        guard tracker.kind == .daily, let rule = tracker.rule(at: now), rule.period != .deadline,
              let target = Int(rule.target), target > 0 else { return nil }
        let interval = tracker.interval(now, period: rule.period)
        return CompletionPeriodProgress(interval: interval, count: tracker.count(in: interval), target: target,
                                        period: rule.period, partial: tracker.calendar.startOfDay(for: tracker.createdAt) > interval.start || rule.effectiveAt > interval.start)
    }

    static func history(for tracker: Tracker, now: Date, limit: Int = 12) -> [CompletionPeriodProgress] {
        guard tracker.kind == .daily, limit > 0 else { return [] }
        let history = tracker.rule(at: now) == nil ? [] : tracker.frequencyHistory(until: now)
        if !history.isEmpty {
            let initial = tracker.rules.map(\.effectiveAt).min() ?? tracker.createdAt
            return history.suffix(limit).map { interval, count, target, partial in
                CompletionPeriodProgress(interval: interval, count: count, target: target,
                                         period: tracker.rule(at: max(interval.start, initial))?.period ?? .weekly, partial: partial)
            }
        }
        let currentWeek = tracker.interval(now, period: .weekly)
        let calendar = tracker.calendar
        guard let oldest = calendar.date(byAdding: .weekOfYear, value: -(limit - 1), to: currentWeek.start) else { return [] }
        var cursor = oldest
        var result: [CompletionPeriodProgress] = []
        while cursor <= now {
            let interval = tracker.interval(cursor, period: .weekly)
            result.append(CompletionPeriodProgress(interval: interval, count: tracker.count(in: interval), target: nil,
                                                   period: .weekly, partial: calendar.startOfDay(for: tracker.createdAt) > interval.start && tracker.createdAt < interval.end))
            cursor = interval.end
        }
        return result
    }
}
