import WidgetKit
import SwiftUI

nonisolated struct ProgressEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}
nonisolated struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> ProgressEntry { ProgressEntry(date: Date(), snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (ProgressEntry) -> Void) { completion(read()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ProgressEntry>) -> Void) {
        let entry = read()
        let next = entry.snapshot?.nextRefresh(after: entry.date) ?? entry.date.addingTimeInterval(3600)
        completion(Timeline(entries: [entry, ProgressEntry(date: next, snapshot: entry.snapshot)], policy: .after(next)))
    }
    private func read() -> ProgressEntry {
        let snapshot = WidgetSnapshot.url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(WidgetSnapshot.self, from: $0) }
        return ProgressEntry(date: Date(), snapshot: snapshot)
    }
}

struct GoalWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ProgressEntry
    private var locale: Locale { Locale(identifier: entry.snapshot?.language ?? Locale.current.identifier) }
    private func text(_ key: String) -> String {
        let language = entry.snapshot?.language ?? Locale.preferredLanguages.first ?? "en"
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
    var body: some View {
        ViewThatFits(in: .vertical) {
            content(limit: family == .systemSmall ? 1 : 3).fixedSize(horizontal: false, vertical: true)
            if family == .systemMedium { content(limit: 2).fixedSize(horizontal: false, vertical: true) }
            content(limit: 1, showGap: false).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "goaltracker://today"))
    }
    private func content(limit: Int, showGap: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 2) {
            Label(text("Your progress"), systemImage: "chart.xyaxis.line").font(.caption.weight(.semibold)).foregroundStyle(.teal).lineLimit(1)
            if let rows = entry.snapshot?.rows, !rows.isEmpty {
                ForEach(Array(rows.prefix(limit))) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(row.name).font(family == .systemSmall ? .headline : .subheadline.weight(.semibold)).lineLimit(1)
                            Spacer(minLength: 4)
                            if row.kind == .daily {
                                Image(systemName: row.completedDays.contains(row.tracker.day(entry.date)) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(.teal)
                                    .accessibilityLabel(text(row.completedDays.contains(row.tracker.day(entry.date)) ? "Completed" : "No record"))
                            }
                        }
                        Text(progress(row)).font((family == .systemSmall ? Font.subheadline : .caption).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        if showGap && family == .systemSmall, let gap = gap(row) {
                            Text(text("Distance to target") + ": " + gap).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }.privacySensitive()
                }
            } else { Text(text("Open the app to add your first tracker.")).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func gap(_ row: WidgetRow) -> String? {
        guard row.kind == .number, let target = row.tracker.rule(at: entry.date).flatMap({ Numbers.decimal($0.target) }), let value = row.value.flatMap(Numbers.decimal) else { return nil }
        return Numbers.display(abs(target - value), precision: row.precision, locale: locale)
    }
    private func progress(_ row: WidgetRow) -> String {
        if row.kind == .number {
            guard let value = row.value.flatMap(Numbers.decimal) else { return text("No snapshots yet") }
            let number = Numbers.display(value, precision: row.precision, locale: locale) + (row.unit.isEmpty ? "" : " " + row.unit)
            return family == .systemMedium ? number + (gap(row).map { " · " + text("Distance to target") + ": " + $0 } ?? "") : number
        }
        let t = row.tracker
        guard let rule = t.rule(at: entry.date) else { return text("Daily completion") }
        return "\(t.count(in: t.interval(entry.date, period: rule.period))) / \(rule.target) · " + text(rule.period == .monthly ? "This month" : "This week")
    }
}

@main struct GoalTrackerWidget: Widget {
    let kind = WidgetSnapshot.kind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in GoalWidgetView(entry: entry) }
            .configurationDisplayName("Your progress")
            .description("Numbers and completion records, at a glance.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
