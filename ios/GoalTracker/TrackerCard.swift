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

extension CardTextPosition {
    var isLeading: Bool { self == .topLeading || self == .bottomLeading }
    var isTop: Bool { self == .topLeading || self == .topTrailing }
    var alignment: Alignment {
        switch self {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing, .hidden: .bottomTrailing
        }
    }
    var horizontalAlignment: HorizontalAlignment { isLeading ? .leading : .trailing }
    var textAlignment: TextAlignment { isLeading ? .leading : .trailing }
    // Root overlays its independent 44pt Button on the outer recording Button, never its label.
    var dailyToggleAlignment: Alignment { .bottomTrailing }
    var gradientStart: UnitPoint {
        switch self {
        case .topLeading: .bottomTrailing
        case .topTrailing: .bottomLeading
        case .bottomLeading: .topTrailing
        case .bottomTrailing, .hidden: .topLeading
        }
    }
    var gradientEnd: UnitPoint {
        switch self {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing, .hidden: .bottomTrailing
        }
    }
}

enum CardLayout {
    static let plotInset: CGFloat = 14
    static let textInset: CGFloat = 14
    static let dailyControlInset: CGFloat = 6
}

/// Only the app adds a tile boundary. This surface contains no interactive controls.
struct TrackerCardSurface<Backdrop: View>: View {
    let row: WidgetRow
    let now: Date
    let locale: Locale
    let text: (String) -> String
    var minimumHeight: CGFloat = 120
    var fillsHeight = true
    var showsDailyStatus = true
    @ViewBuilder var backdrop: () -> Backdrop
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var accessibleRingHeight = 220

    var body: some View {
        TrackerCardLabel(row: row, now: now, locale: locale, text: text, showsDailyStatus: showsDailyStatus)
            .padding(CardLayout.textInset)
            .padding(.bottom, row.resolvedBackground == .map && !row.resolvedTextPosition.isTop ? 18 : 0)
            .padding(.trailing, row.kind == .daily && !showsDailyStatus && !row.resolvedTextPosition.isTop ? 44 : 0)
            .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: row.resolvedTextPosition.alignment)
            .fixedSize(horizontal: false, vertical: !fillsHeight)
            .frame(minHeight: row.resolvedBackground == .progress && dynamicTypeSize.isAccessibilitySize && !fillsHeight ? max(minimumHeight, accessibleRingHeight) : minimumHeight,
                   alignment: row.resolvedTextPosition.alignment)
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

/// Transparent corner text; a hidden group retains its semantic summary.
struct TrackerCardLabel: View {
    let row: WidgetRow
    let now: Date
    let locale: Locale
    let text: (String) -> String
    var compact = false
    var monochrome = false
    var showsDailyStatus = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    private var hasImage: Bool { !monochrome && (row.hasPhoto || row.resolvedBackground == .map && row.locations?.isEmpty == false) }
    private var position: CardTextPosition { row.resolvedTextPosition }

    var body: some View {
        Group {
            if position == .hidden { Color.clear.frame(width: 1, height: 1) }
            else { visibleGroup }
        }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.name + ", " + row.valueText(at: now, locale: locale, text: text))
            .accessibilityValue(row.accessibilityValue(at: now, locale: locale, text: text))
            .accessibilityIdentifier("card.summary." + row.id.uuidString)
    }
    private var visibleGroup: some View {
        VStack(alignment: position.horizontalAlignment, spacing: 4) {
            Text(row.name).font(compact ? .subheadline.weight(.semibold) : .headline)
                .lineLimit(row.resolvedBackground == .progress ? compact ? 1 : 2 : dynamicTypeSize.isAccessibilitySize && !compact ? nil : compact ? 2 : 3)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
            // A ring owns its centered number; corners retain only title/date and daily state.
            if row.resolvedBackground != .progress {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.valueText(at: now, locale: locale, text: text)).font((compact ? Font.subheadline : .title3).monospacedDigit())
                        .lineLimit(dynamicTypeSize.isAccessibilitySize && !compact ? nil : 2).minimumScaleFactor(0.6)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("progress." + row.id.uuidString)
                    if row.kind == .daily && showsDailyStatus { dailyStatus }
                }
            } else if row.kind == .daily && showsDailyStatus { dailyStatus }
            if row.resolvedBackground == .plot && row.clippedPointCount > 0 {
                Text(text("Some records are outside chart bounds")).font(.caption2).lineLimit(compact ? 1 : 2)
            }
            if row.resolvedShowLastRecorded, let date = row.lastRecordedDate {
                Text(date.formatted(Date.FormatStyle(locale: locale, calendar: row.tracker.calendar, timeZone: row.tracker.calendar.timeZone).month().day()))
                    .font(.caption2).lineLimit(compact ? 1 : row.resolvedBackground == .progress ? 2 : nil)
            }
        }
        .multilineTextAlignment(position.textAlignment)
        .foregroundStyle(foreground)
        .shadow(color: hasImage ? (foregroundIsLight ? Color.black.opacity(0.45) : Color.white.opacity(0.5)) : .clear, radius: 1, y: 1)
        .shadow(color: hasImage || monochrome ? .clear : Color(uiColor: .secondarySystemGroupedBackground), radius: 0, x: -1.5)
        .shadow(color: hasImage || monochrome ? .clear : Color(uiColor: .secondarySystemGroupedBackground), radius: 0, x: 1.5)
        .shadow(color: hasImage || monochrome ? .clear : Color(uiColor: .secondarySystemGroupedBackground), radius: 0, y: -1.5)
        .shadow(color: hasImage || monochrome ? .clear : Color(uiColor: .secondarySystemGroupedBackground), radius: 0, y: 1.5)
    }
    private var dailyStatus: some View {
        Image(systemName: completed ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(!hasImage && !monochrome && completed ? TrackerColors.accent : foreground)
    }
    private var foregroundIsLight: Bool {
        if row.resolvedBackground == .map { return colorScheme == .dark }
        if row.hasPhoto, let data = row.thumbnail { return CardImageContrast.prefersLightText(data, position: position) }
        return false
    }
    private var foreground: Color { hasImage ? (foregroundIsLight ? .white : .black) : .primary }
    private var completed: Bool { row.completedDays.contains(row.tracker.day(now)) }
}

/// Widget accented/clear modes flatten the same corner fade into a bounded, display-only image.
enum CardAccentedPhoto {
    static func make(_ image: UIImage, size: CGSize, position: CardTextPosition, increasedContrast: Bool) -> UIImage {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              image.size.width > 0, image.size.height > 0 else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 320 / max(size.width, size.height)
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            let bounds = CGRect(origin: .zero, size: size)
            let scale = max(size.width / image.size.width, size.height / image.size.height)
            let cropSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (size.width - cropSize.width) / 2, y: (size.height - cropSize.height) / 2,
                                  width: cropSize.width, height: cropSize.height))
            context.setBlendMode(.saturation)
            context.setFillColor(UIColor.black.cgColor)
            context.fill(bounds)
            context.setBlendMode(.normal)
            guard position != .hidden else { return }
            let colors = [UIColor.clear.cgColor, UIColor.clear.cgColor,
                          UIColor.black.withAlphaComponent(0.12).cgColor,
                          UIColor.black.withAlphaComponent(increasedContrast ? 0.82 : 0.66).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                         locations: [0, 0.3, 0.6, 1]) {
                let start = position.gradientStart, end = position.gradientEnd
                context.drawLinearGradient(gradient,
                    start: CGPoint(x: size.width * start.x, y: size.height * start.y),
                    end: CGPoint(x: size.width * end.x, y: size.height * end.y), options: [])
            }
        }
    }
}

/// Sample the chosen corner of the same aspect-fill crop used by the card.
enum CardImageContrast {
    static func prefersLightText(_ data: Data, position: CardTextPosition = .bottomTrailing) -> Bool {
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
            let rows = position.isTop ? 8..<16 : 0..<8
            let columns = position.isLeading ? 0..<10 : 6..<16
            let luminances = rows.flatMap { y in columns.map { x in
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
    var now = Date()
    var locale = Locale.current
    var mapImage: UIImage?
    var monochrome = false
    var body: some View {
        switch row.resolvedBackground {
        case .progress:
            if let progress = row.currentProgress(at: now) {
                GeometryReader { geometry in
                    let edge = max(0, min(geometry.size.width, geometry.size.height) - CardLayout.plotInset * 2)
                    GoalProgressRing(fraction: progress.fraction, monochrome: monochrome,
                                     value: row.ringText(at: now, locale: locale))
                        .frame(width: edge, height: edge)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else { empty("Goal progress unavailable", symbol: "circle.dashed") }
        case .plot:
            if let points = row.plot, !points.isEmpty {
                Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    if let value = point.plottedValue {
                        if !CardPlotScale.excludes(point.value, lower: row.axisLower, upper: row.axisUpper) {
                            PointMark(x: .value(text("Date"), point.date), y: .value(text("Value"), value)).symbolSize(22)
                        }
                    }
                }
                if row.kind == .number {
                    ForEach(CardPlotScale.clippedSegments(points, lower: row.axisLower, upper: row.axisUpper)) { segment in
                        ForEach(Array([segment.start, segment.end].enumerated()), id: \.offset) { _, point in
                            if let value = point.plottedValue {
                                LineMark(x: .value(text("Date"), point.date), y: .value(text("Value"), value), series: .value("Series", "actual-\(segment.id)"))
                                    .lineStyle(StrokeStyle(lineWidth: 2))
                            }
                        }
                    }
                }
                ForEach(row.carries(at: now).filter { !CardPlotScale.excludes($0.start.value, lower: row.axisLower, upper: row.axisUpper) }) { segment in
                    ForEach([segment.start, segment.end], id: \.date) { point in
                        if let value = point.plottedValue {
                            LineMark(x: .value(text("Date"), point.date), y: .value(text("Value"), value), series: .value("Series", segment.id))
                                .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        }
                    }
                }
                }
                .foregroundStyle(monochrome ? Color.primary.opacity(0.45) : TrackerColors.accent).chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
                .chartYScale(domain: row.plotDomain(at: now)).chartPlotStyle { $0.clipped() }
                .padding(CardLayout.plotInset)
            } else {
                Image(systemName: "chart.xyaxis.line").font(.title2).foregroundStyle(TrackerColors.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16).accessibilityHidden(true)
            }
        case .photo, .trackerPhoto:
            if let data = row.thumbnail, let image = UIImage(data: data) {
                GeometryReader { geometry in
                    Image(uiImage: image).renderingMode(.original).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        .overlay {
                            CardPhotoReadabilityGradient(position: row.resolvedTextPosition, monochrome: monochrome,
                                                         lightText: CardImageContrast.prefersLightText(data, position: row.resolvedTextPosition))
                        }
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

struct GoalProgressRing: View {
    let fraction: Double
    var monochrome = false
    var value: String?
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 12)
            Circle().trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(monochrome ? Color.primary.opacity(0.35) : TrackerColors.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(6)
        .overlay {
            if let value {
                GeometryReader { geometry in
                    Text(value).font(.title2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary).multilineTextAlignment(.center)
                        .lineLimit(1).minimumScaleFactor(0.35)
                        .frame(width: geometry.size.width * 0.70, height: geometry.size.height * 0.28)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A subtle corner fade preserves the full photo and follows the chosen text position.
struct CardPhotoReadabilityGradient: View {
    var position: CardTextPosition = .bottomTrailing
    var monochrome = false
    var lightText = true
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        let color = monochrome ? Color(uiColor: .systemBackground) : lightText ? Color.black : Color.white
        if position != .hidden {
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .clear, location: 0.3),
                                   .init(color: color.opacity(0.12), location: 0.6),
                                   .init(color: color.opacity(contrast == .increased ? 0.82 : 0.66), location: 1)],
                           startPoint: position.gradientStart, endPoint: position.gradientEnd)
        }
    }
}
