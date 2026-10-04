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

/// Only the app adds a tile boundary. WidgetKit already owns the Widget boundary.
struct TrackerCardSurface<Backdrop: View>: View {
    let row: WidgetRow
    let now: Date
    let locale: Locale
    let text: (String) -> String
    var minimumHeight: CGFloat = 120
    var fillsHeight = true
    @ViewBuilder var backdrop: () -> Backdrop
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        TrackerCardLabel(row: row, now: now, locale: locale, text: text)
            .padding(14).padding(.bottom, row.resolvedBackground == .map ? 18 : 0)
            .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .bottomTrailing)
            .fixedSize(horizontal: false, vertical: !fillsHeight)
            .frame(minHeight: minimumHeight, alignment: .bottomTrailing)
            .background {
                GeometryReader { geometry in
                    backdrop().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.primary.opacity(contrast == .increased ? 0.4 : 0.08)) }
    }
}

/// One transparent text group, shared with the small Widget; no text plates or plus button.
struct TrackerCardLabel: View {
    let row: WidgetRow
    let now: Date
    let locale: Locale
    let text: (String) -> String
    var compact = false
    var monochrome = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    private var hasImage: Bool { !monochrome && (row.resolvedBackground == .photo && row.thumbnail != nil || row.resolvedBackground == .map && row.locations?.isEmpty == false) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(row.name).font(compact ? .subheadline.weight(.semibold) : .headline)
                .lineLimit(dynamicTypeSize.isAccessibilitySize && !compact ? nil : compact ? 2 : 3)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(progress).font((compact ? Font.subheadline : .title3).monospacedDigit())
                    .lineLimit(dynamicTypeSize.isAccessibilitySize && !compact ? nil : 2).minimumScaleFactor(0.6)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("progress." + row.id.uuidString)
                if row.kind == .daily {
                    Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(!hasImage && !monochrome && completed ? TrackerColors.accent : foreground)
                        .accessibilityLabel(text(completed ? "Today is recorded" : "No record today"))
                }
            }
        }
        .multilineTextAlignment(.trailing)
        .foregroundStyle(foreground)
        .shadow(color: hasImage ? (foregroundIsLight ? Color.black.opacity(0.45) : Color.white.opacity(0.5)) : .clear, radius: 1, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityValue(text(backgroundDescription) + (completionPeriod.map { ", " + $0 } ?? ""))
    }
    private var foregroundIsLight: Bool {
        if row.resolvedBackground == .map { return colorScheme == .dark }
        return row.resolvedBackground == .photo && row.thumbnail.map(CardImageContrast.prefersLightText) == true
    }
    private var foreground: Color { hasImage ? (foregroundIsLight ? .white : .black) : .primary }
    private var completionPeriod: String? {
        guard row.kind == .daily, let rule = row.tracker.rule(at: now) else { return nil }
        return text(rule.period == .monthly ? "This month" : "This week")
    }
    private var completed: Bool { row.completedDays.contains(row.tracker.day(now)) }
    private var backgroundDescription: String {
        switch row.resolvedBackground {
        case .plot: row.plot?.isEmpty == false ? "Recent records" : "No records yet"
        case .photo: row.thumbnail != nil ? "Photos" : "No photos yet"
        case .map: row.locations?.isEmpty == false ? "Recorded locations" : "No locations yet"
        }
    }
    private var progress: String {
        if row.kind == .number {
            guard let value = row.value.flatMap(Numbers.decimal) else { return text("No snapshots yet") }
            return Numbers.display(value, precision: row.precision, locale: locale) + (row.unit.isEmpty ? "" : " " + row.unit)
        }
        let t = row.tracker
        guard let rule = t.rule(at: now) else { return text("Completion record") }
        return "\(t.count(in: t.interval(now, period: rule.period))) / \(rule.target)"
    }
}

/// Choose an unboxed text color from the actual lower-right crop, not the app theme.
enum CardImageContrast {
    static func prefersLightText(_ data: Data) -> Bool {
        guard let image = UIImage(data: data)?.cgImage else { return false }
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let bytes = buffer.baseAddress,
                  let context = CGContext(data: bytes, width: 16, height: 16, bitsPerComponent: 8,
                                          bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // The centered square matches aspect-fill. CGContext y=0 is the lower edge.
            let edge = min(image.width, image.height)
            let rect = CGRect(x: (image.width - edge) / 2, y: (image.height - edge) / 2, width: edge, height: edge)
            guard let crop = image.cropping(to: rect) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            func linear(_ channel: UInt8) -> Double {
                let value = Double(channel) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            let luminances = (0..<8).flatMap { y in (6..<16).map { x in
                let offset = (y * 16 + x) * 4
                return 0.2126 * linear(buffer[offset]) + 0.7152 * linear(buffer[offset + 1]) + 0.0722 * linear(buffer[offset + 2])
            }}
            return luminances.reduce(0, +) / Double(luminances.count) < 0.179
        }
    }
}

struct TrackerCardBackdrop: View {
    let row: WidgetRow
    let text: (String) -> String
    var mapImage: UIImage?
    var monochrome = false
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
                .foregroundStyle(monochrome ? Color.primary : TrackerColors.accent).chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
                .chartYScale(domain: CardPlotScale.domain(points: points, precision: row.precision, completion: row.kind == .daily))
                .padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 28)
            } else {
                Image(systemName: "chart.xyaxis.line").font(.title2).foregroundStyle(TrackerColors.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16).accessibilityHidden(true)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16)
    }
}
