import SwiftUI
import Charts

// Native semantic roles shared by the app and Widget, with a readable teal on light surfaces.
enum TrackerColors {
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.35, green: 0.83, blue: 0.83, alpha: 1)
            : UIColor(red: 0, green: 0.40, blue: 0.42, alpha: 1)
    })
    static var secondaryText: Color { Color.primary.opacity(0.72) }
}

// The app supplies a native Map; the Widget supplies a static snapshot.
struct TrackerCardSurface<Backdrop: View>: View {
    let row: WidgetRow
    let now: Date
    let locale: Locale
    let text: (String) -> String
    var compact = false
    var showGap = true
    var essential = false
    var minimumHeight: CGFloat = 120
    @ViewBuilder var backdrop: () -> Backdrop
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(row.name).font(essential ? .caption.weight(.semibold) : compact ? .subheadline.weight(.semibold) : .headline)
                    .lineLimit(essential ? 1 : compact ? 2 : nil)
                Spacer(minLength: 0)
                if row.kind == .daily {
                    Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(.primary)
                        .accessibilityLabel(text(completed ? "Today is recorded" : "No record today"))
                } else {
                    Image(systemName: "plus.circle").accessibilityHidden(true)
                }
            }.padding(essential ? 4 : 6).background(textProtection)
            Spacer(minLength: essential ? 4 : compact ? 8 : 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(progress).font((essential ? Font.caption : compact ? .subheadline : .title3).monospacedDigit())
                    .lineLimit(essential ? 1 : compact ? 2 : nil).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("progress." + row.id.uuidString)
                if compact && !essential, let completionPeriod {
                    Text(completionPeriod).font(.caption2).foregroundStyle(TrackerColors.secondaryText).lineLimit(1)
                }
                if showGap, let gap {
                    Text(compact ? gap + " · " + text("Distance to target") : text("Distance to target") + ": " + gap)
                        .font(compact ? .caption2 : .caption).foregroundStyle(TrackerColors.secondaryText).lineLimit(compact ? 1 : nil)
                        .accessibilityLabel(text("Distance to target") + ": " + gap)
                }
            }.padding(essential ? 4 : 6).frame(maxWidth: .infinity, alignment: .leading).background(textProtection)
        }
        .padding(.bottom, row.resolvedBackground == .map ? 24 : 0)
        .padding(essential ? 8 : compact ? 10 : 14)
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .topLeading)
        .foregroundStyle(.primary)
        .background {
            ZStack {
                GeometryReader { geometry in
                    backdrop().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }.allowsHitTesting(false).accessibilityHidden(true)
                Color(uiColor: .secondarySystemGroupedBackground).opacity(0.08)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.primary.opacity(contrast == .increased ? 0.4 : 0.08)) }
        .accessibilityElement(children: .combine)
        .accessibilityValue(text(backgroundDescription) + (essential ? completionPeriod.map { ", " + $0 } ?? "" : ""))
    }
    // Protection follows actual text bounds, including large type and very long names.
    // The backdrop still spans the entire surface and the space around both overlays.
    private var textProtection: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(reduceTransparency || contrast == .increased ? 1 : 0.94))
    }
    private var completed: Bool { row.completedDays.contains(row.tracker.day(now)) }
    private var backgroundDescription: String {
        switch row.resolvedBackground {
        case .plot: row.plot?.isEmpty == false ? "Recent records" : "No records yet"
        case .photo: row.thumbnail != nil ? "Photos" : "No photos yet"
        case .map: row.locations?.isEmpty == false ? "Recorded locations" : "No locations yet"
        }
    }
    private var completionPeriod: String? {
        guard row.kind == .daily, let rule = row.tracker.rule(at: now) else { return nil }
        return text(rule.period == .monthly ? "This month" : "This week")
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
        let count = "\(t.count(in: t.interval(now, period: rule.period))) / \(rule.target)"
        return compact ? count : count + " · " + text(rule.period == .monthly ? "This month" : "This week")
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
                .foregroundStyle(TrackerColors.accent).chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
                .chartYScale(domain: .automatic(includesZero: false)).padding(12)
            } else {
                Image(systemName: "chart.xyaxis.line").font(.title2).foregroundStyle(TrackerColors.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityHidden(true)
            }
        case .photo:
            if let data = row.thumbnail, let image = UIImage(data: data) {
                GeometryReader { geometry in
                    Image(uiImage: image).renderingMode(.original).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            } else { empty("No photos yet", symbol: "photo") }
        case .map:
            if let mapImage {
                GeometryReader { geometry in
                    Image(uiImage: mapImage).renderingMode(.original).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            } else { empty(row.locations?.isEmpty == false ? "Map preview unavailable" : "No locations yet", symbol: "map") }
        }
    }
    private func empty(_ key: String, symbol: String) -> some View {
        Label(text(key), systemImage: symbol).font(.caption).foregroundStyle(TrackerColors.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(8)
    }
}
