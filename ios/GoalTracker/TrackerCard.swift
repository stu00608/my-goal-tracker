import SwiftUI
import Charts

// The app supplies a native Map; the Widget supplies a static snapshot.
struct TrackerCardSurface<Backdrop: View>: View {
    let row: WidgetRow
    let now: Date
    let locale: Locale
    let text: (String) -> String
    var compact = false
    var showGap = true
    @ViewBuilder var backdrop: () -> Backdrop
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(row.name).font(.headline).lineLimit(compact ? 1 : 2)
                    Spacer(minLength: 0)
                    if row.kind == .daily {
                        Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(completed ? Color.teal : Color.secondary)
                            .accessibilityLabel(text(completed ? "Today is recorded" : "No record today"))
                    }
                }
                Text(progress).font((compact ? Font.subheadline : .title3).monospacedDigit())
                    .lineLimit(compact ? 1 : 2)
                    .accessibilityIdentifier("progress." + row.id.uuidString)
                if showGap, let gap {
                    Text(compact ? gap + " · " + text("Distance to target") : text("Distance to target") + ": " + gap)
                        .font(compact ? .caption2 : .caption).foregroundStyle(.secondary).lineLimit(compact ? 1 : 2)
                        .accessibilityLabel(text("Distance to target") + ": " + gap)
                }
            }
            .padding(compact ? 10 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if reduceTransparency || contrast == .increased { Color(uiColor: .secondarySystemGroupedBackground) }
                else { Rectangle().fill(.regularMaterial) }
            }
            backdrop().frame(maxWidth: .infinity).frame(height: compact ? 44 : 88).clipped().accessibilityHidden(true)
        }
        .foregroundStyle(.primary)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.primary.opacity(contrast == .increased ? 0.4 : 0.08)) }
        .accessibilityElement(children: .combine)
        .accessibilityValue(text(backgroundDescription))
    }
    private var completed: Bool { row.completedDays.contains(row.tracker.day(now)) }
    private var backgroundDescription: String {
        switch row.resolvedBackground {
        case .plot: row.plot?.isEmpty == false ? "Recent records" : "No records yet"
        case .photo: row.thumbnail != nil ? "Photos" : "No photos yet"
        case .map: row.locations?.isEmpty == false ? "Recorded locations" : "No locations yet"
        }
    }
    private var gap: String? {
        guard row.kind == .number, let target = row.tracker.rule(at: now).flatMap({ Numbers.decimal($0.target) }),
              let value = row.value.flatMap(Numbers.decimal) else { return nil }
        return Numbers.display(abs(target - value), precision: row.precision, locale: locale)
    }
    private var progress: String {
        if row.kind == .number {
            guard let value = row.value.flatMap(Numbers.decimal) else { return text("No snapshots yet") }
            return Numbers.display(value, precision: row.precision, locale: locale) + (row.unit.isEmpty ? "" : " " + row.unit)
        }
        let t = row.tracker
        guard let rule = t.rule(at: now) else { return text("Completion record") }
        return "\(t.count(in: t.interval(now, period: rule.period))) / \(rule.target) · " + text(rule.period == .monthly ? "This month" : "This week")
    }
}

struct TrackerCardBackdrop: View {
    let row: WidgetRow
    let text: (String) -> String
    var mapImage: UIImage?
    var body: some View {
        switch row.resolvedBackground {
        case .plot:
            if let points = row.plot, !points.isEmpty {
                Chart(Array(points.enumerated()), id: \.offset) { _, point in
                    if let value = point.plottedValue {
                        if row.kind == .number && points.count > 1 {
                            LineMark(x: .value(text("Date"), point.date), y: .value(text("Value"), value)).lineStyle(StrokeStyle(lineWidth: 2))
                        }
                        PointMark(x: .value(text("Date"), point.date), y: .value(text("Value"), value)).symbolSize(22)
                    }
                }
                .foregroundStyle(.teal).chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
                .chartYScale(domain: .automatic(includesZero: false)).padding(12)
            } else { empty("No records yet", symbol: "chart.xyaxis.line") }
        case .photo:
            if let data = row.thumbnail, let image = UIImage(data: data) {
                GeometryReader { geometry in
                    Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            } else { empty("No photos yet", symbol: "photo") }
        case .map:
            if let mapImage {
                GeometryReader { geometry in
                    Image(uiImage: mapImage).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            } else { empty(row.locations?.isEmpty == false ? "Map preview unavailable" : "No locations yet", symbol: "map") }
        }
    }
    private func empty(_ key: String, symbol: String) -> some View {
        Label(text(key), systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(8)
    }
}
