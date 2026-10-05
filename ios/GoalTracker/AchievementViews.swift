import SwiftUI
import Charts
import MapKit
import UIKit

struct CompletedTab: View {
    let trackers: [Tracker]
    let now: Date
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        NavigationStack {
            let snapshots = trackers.flatMap { CompletionEngine.snapshots(for: $0, until: now) }
                .sorted { ($0.achievedAt, $0.id) > ($1.achievedAt, $1.id) }
            Group {
                if snapshots.isEmpty {
                    ContentUnavailableView(L.text("No achievements yet."), systemImage: "sparkles")
                        .accessibilityIdentifier("achievements.empty")
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                            ForEach(snapshots) { snapshot in
                                NavigationLink { AchievementDetail(snapshot: snapshot) } label: {
                                    AchievementThumbnail(snapshot: snapshot)
                                }.buttonStyle(.plain)
                                    .accessibilityLabel(AchievementText.summary(snapshot))
                                    .accessibilityIdentifier("achievements.tracker." + snapshot.trackerID.uuidString + "." + snapshot.id)
                            }
                        }.padding(16)
                    }.accessibilityIdentifier("achievements.list")
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(L.text("Completed tab"))
        }
    }
}

private struct AchievementThumbnail: View {
    let snapshot: AchievementSnapshot
    @State private var mapImage: UIImage?
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        AchievementPoster(snapshot: snapshot, mapImage: mapImage, compact: true)
            .task(id: snapshot.id + String(describing: colorScheme)) {
                if snapshot.background == .map && !snapshot.locations.isEmpty {
                    mapImage = try? await AchievementMap.image(locations: snapshot.locations, dark: colorScheme == .dark)
                }
            }
    }
}

struct CompletionHistoryView: View {
    let tracker: Tracker
    let now: Date

    var body: some View {
        let snapshots = CompletionEngine.snapshots(for: tracker, until: now)
        Section {
            if snapshots.isEmpty {
                Text(L.text("No achievements yet.")).foregroundStyle(.secondary)
                    .accessibilityIdentifier("achievement.history.empty")
            } else {
                ForEach(snapshots) { snapshot in
                    NavigationLink {
                        AchievementDetail(snapshot: snapshot)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(AchievementText.value(snapshot)).font(.headline.monospacedDigit())
                            Text(AchievementText.date(snapshot)).font(.subheadline).foregroundStyle(.secondary)
                        }.foregroundStyle(.primary).padding(.vertical, 4)
                    }.accessibilityIdentifier("achievement.open." + snapshot.id)
                }
            }
        } header: {
            Text(L.text("Achievement history")).accessibilityIdentifier("achievement.history.header")
        }
    }
}

struct AchievementDetail: View {
    let snapshot: AchievementSnapshot
    @Environment(\.colorScheme) private var colorScheme
    @State private var exportImage: UIImage?
    @State private var error: String?
    @State private var mapImage: UIImage?
    @State private var mapLoading = false
    @State private var mapFailed = false
    @State private var posterVisible = false
    #if DEBUG && targetEnvironment(simulator)
    @State private var flatAlternative = false
    #endif

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    poster.onGeometryChange(for: Bool.self) { [height = viewport.size.height] proxy in
                        let frame = proxy.frame(in: .named("achievement.scroll"))
                        return frame.maxY > 0 && frame.minY < height
                    } action: { posterVisible = $0 }
                    if mapLoading {
                        HStack { ProgressView(); Text(L.text("Preparing map…")) }
                    }
                    if mapFailed {
                        Text(L.text("Could not prepare the map. Try again before exporting."))
                            .foregroundStyle(.red).accessibilityIdentifier("achievement.map.error")
                        Button(L.text("Retry")) { Task { await prepareMap() } }
                            .accessibilityIdentifier("achievement.map.retry")
                    }
                    #if DEBUG && targetEnvironment(simulator)
                    if ProcessInfo.processInfo.arguments.contains("--milestone-compare-layout") {
                        Toggle(L.text("Compare flat poster"), isOn: $flatAlternative)
                            .accessibilityIdentifier("achievement.debug.flat")
                    }
                    #endif
                }.padding(20)
            }.coordinateSpace(name: "achievement.scroll")
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(L.text("Achievement"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let exportImage {
                    ShareLink(item: Image(uiImage: exportImage), preview: SharePreview(snapshot.name, image: Image(uiImage: exportImage))) {
                        Label(L.text("Share image"), systemImage: "square.and.arrow.up")
                    }.accessibilityIdentifier("achievement.share")
                } else {
                    Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
                        .accessibilityLabel(L.text("Share image")).accessibilityIdentifier("achievement.share.loading")
                }
            }
        }
        .statusToast(message: $error, identifier: "achievement.export.error", autoDismiss: false)
        .sensoryFeedback(.error, trigger: error) { _, error in error != nil }
        .task(id: snapshot.id + String(describing: colorScheme)) { await prepareMap() }

    }

    @ViewBuilder private var poster: some View {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--milestone-compare-layout") && flatAlternative {
            AchievementPoster(snapshot: snapshot, mapImage: mapImage, alternateLayout: true)
        } else {
            relief
        }
        #else
        relief
        #endif
    }

    private var relief: some View {
        AchievementRelief(sensorEnabled: posterVisible) { offset in
            AchievementPoster(snapshot: snapshot, mapImage: mapImage, foregroundOffset: offset)
        }
    }

    private func prepareMap() async {
        exportImage = nil
        mapFailed = false
        if snapshot.background == .map && !snapshot.locations.isEmpty {
            mapLoading = true; mapImage = nil
            defer { mapLoading = false }
            do { mapImage = try await AchievementMap.image(locations: snapshot.locations, dark: colorScheme == .dark) }
            catch is CancellationError { return }
            catch { mapFailed = true; return }
        }
        exportImage = AchievementExport.image(snapshot: snapshot, mapImage: mapImage, colorScheme: colorScheme)
        if exportImage == nil { error = L.text("Could not create the image. Please try again.") }
    }

}

/// Content-only, flat export surface. Always includes name/value/date/duration,
/// regardless of dashboard label preferences; no controls or motion manager.
struct AchievementPoster: View {
    let snapshot: AchievementSnapshot
    var mapImage: UIImage?
    var foregroundOffset = CGSize.zero
    var alternateLayout = false
    var compact = false
    @Environment(\.colorSchemeContrast) private var contrast

    private var usesImage: Bool {
        snapshot.thumbnail != nil && [.photo, .trackerPhoto].contains(snapshot.background) || mapImage != nil
    }

    var body: some View {
        VStack(alignment: alternateLayout ? .leading : .trailing, spacing: compact ? 8 : 12) {
            Label(snapshot.manual ? L.text("Marked complete") : L.text("Goal reached"), systemImage: "checkmark.seal.fill")
                .font(compact ? .caption : .headline)
            Spacer(minLength: compact ? 24 : alternateLayout ? 40 : 130)
            Text(snapshot.name).font(compact ? .headline : .largeTitle.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(AchievementText.value(snapshot)).font((compact ? Font.title3 : Font.title).weight(.semibold).monospacedDigit())
                .fixedSize(horizontal: false, vertical: true)
            Text(AchievementText.date(snapshot)).font(compact ? .caption : .subheadline)
            if !compact { Text(L.text("Time to achieve") + " · " + AchievementText.duration(snapshot)).font(.subheadline) }
        }
        .multilineTextAlignment(alternateLayout ? .leading : .trailing)
        .foregroundStyle(usesImage ? Color.white : Color.primary)
        .shadow(color: usesImage ? .black.opacity(0.45) : Color(uiColor: .secondarySystemGroupedBackground), radius: 1)
        .shadow(color: usesImage ? .clear : Color(uiColor: .secondarySystemGroupedBackground), radius: 1)
        .offset(foregroundOffset)
        .padding(compact ? 16 : 24)
        .frame(maxWidth: .infinity, minHeight: compact ? 240 : 390, alignment: .bottomTrailing)
        .background {
            GeometryReader { geometry in
                AchievementBackdrop(snapshot: snapshot, mapImage: mapImage, compact: compact)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .overlay {
                        if usesImage {
                            LinearGradient(colors: [.black.opacity(contrast == .increased ? 0.55 : 0.2), .black.opacity(0.85)],
                                           startPoint: .top, endPoint: .bottom)
                        }
                    }
            }.accessibilityHidden(true)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.primary.opacity(contrast == .increased ? 0.5 : 0.1)) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AchievementText.summary(snapshot))
        .accessibilityIdentifier("achievement.poster")
    }
}

private struct AchievementBackdrop: View {
    let snapshot: AchievementSnapshot
    let mapImage: UIImage?
    let compact: Bool

    var body: some View {
        switch snapshot.background {
        case .photo, .trackerPhoto:
            if let data = snapshot.thumbnail, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else { empty("No photo") }
        case .map:
            if let mapImage { Image(uiImage: mapImage).resizable().scaledToFill() }
            else { empty(snapshot.locations.isEmpty ? "No recorded locations" : "Map") }
        case .progress:
            ZStack {
                if snapshot.target != nil {
                    Circle().stroke(.primary.opacity(0.1), lineWidth: compact ? 12 : 24)
                    Circle().trim(from: 0, to: 1).stroke(TrackerColors.accent.opacity(0.16), lineWidth: compact ? 12 : 24)
                }
            }.padding(compact ? 24 : 50)
        case .plot:
            if snapshot.plot.isEmpty { empty("No records") }
            else {
                Chart(Array(snapshot.plot.enumerated()), id: \.offset) { _, point in
                    if let value = Numbers.plottedValue(point.value) {
                        if snapshot.kind == .daily {
                            BarMark(x: .value("Date", point.date), y: .value("Value", value), width: .ratio(0.5))
                                .foregroundStyle(TrackerColors.accent.opacity(0.35))
                        } else {
                            LineMark(x: .value("Date", point.date), y: .value("Value", value))
                                .foregroundStyle(TrackerColors.accent.opacity(0.6))
                            PointMark(x: .value("Date", point.date), y: .value("Value", value))
                                .foregroundStyle(TrackerColors.accent.opacity(0.6))
                        }
                    }
                }
                .chartYScale(domain: CardPlotScale.domain(points: snapshot.plot.map { CardPlotPoint(date: $0.date, value: $0.value) },
                                                        precision: snapshot.precision, completion: snapshot.kind == .daily))
                .chartXAxis(.hidden).chartYAxis(.hidden).padding(20)
            }
        }
    }

    private func empty(_ key: String) -> some View {
        Color.clear
    }
}

enum AchievementText {
    static func value(_ snapshot: AchievementSnapshot) -> String {
        guard let rawValue = snapshot.value else { return L.text("No recorded value") }
        let value = Numbers.decimal(rawValue).map {
            Numbers.display($0, precision: snapshot.kind == .daily ? 0 : snapshot.precision, locale: L.locale)
        } ?? rawValue
        if snapshot.kind == .daily {
            let unit = (snapshot.target ?? rawValue) == "1" ? L.text("day") : L.text("days")
            return value + (snapshot.target.map { " / " + $0 } ?? "") + " " + unit
        }
        return value + (snapshot.unit.isEmpty ? "" : " " + snapshot.unit)
    }

    static func date(_ snapshot: AchievementSnapshot) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: snapshot.timeZoneID) ?? .gmt
        return DetailStyle.date(snapshot.achievedAt, calendar: calendar)

    }

    static func duration(_ snapshot: AchievementSnapshot) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = L.locale
        calendar.timeZone = TimeZone(identifier: snapshot.timeZoneID) ?? .gmt
        formatter.calendar = calendar
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated; formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        let seconds = max(0, snapshot.achievedAt.timeIntervalSince(snapshot.startedAt))
        return seconds < 60 ? L.text("Less than a minute") : formatter.string(from: seconds) ?? L.text("Less than a minute")
    }

    static func summary(_ snapshot: AchievementSnapshot) -> String {
        [snapshot.name, value(snapshot), date(snapshot), L.text("Time to achieve"), duration(snapshot),
         snapshot.manual ? L.text("Marked complete") : L.text("Goal reached")].joined(separator: ", ")
    }
}

@MainActor enum AchievementExport {
    static func image(snapshot: AchievementSnapshot, mapImage: UIImage? = nil,
                      colorScheme: ColorScheme = .light) -> UIImage? {
        if snapshot.background == .map && !snapshot.locations.isEmpty && mapImage == nil { return nil }
        let renderer = ImageRenderer(content: AchievementPoster(snapshot: snapshot, mapImage: mapImage)
            .frame(width: 600).frame(minHeight: 750)
            .environment(\.locale, L.locale).environment(\.colorScheme, colorScheme)
            .environment(\.dynamicTypeSize, .large))
        renderer.scale = 2
        renderer.isOpaque = true
        return renderer.uiImage
    }

    static func png(snapshot: AchievementSnapshot, mapImage: UIImage? = nil) -> Data? {
        image(snapshot: snapshot, mapImage: mapImage)?.pngData()
    }
}

@MainActor private enum AchievementMap {
    static func image(locations: [RecordedLocation], dark: Bool) async throws -> UIImage {
        let points = locations.filter(\.isValid).prefix(50).map {
            MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude))
        }
        guard let first = points.first else { throw DataError.photoFailed }
        let rect = points.reduce(MKMapRect(origin: first, size: MKMapSize(width: 0, height: 0))) {
            $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 1, height: 1)))
        }
        let width = max(rect.width, 2_000), height = max(rect.height, 2_000)
        let options = MKMapSnapshotter.Options()
        options.mapRect = MKMapRect(x: rect.midX - width * 0.7, y: rect.midY - height * 0.7,
                                   width: width * 1.4, height: height * 1.4)
        options.size = CGSize(width: 600, height: 750)
        options.scale = 1
        options.traitCollection = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let request = AchievementMapRequest(options: options)
        let snapshot = try await withTaskCancellationHandler {
            try await request.snapshotter.start()
        } onCancel: { Task { @MainActor in request.snapshotter.cancel() } }
        try Task.checkCancellation()
        return UIGraphicsImageRenderer(size: options.size).image { context in
            snapshot.image.draw(at: .zero)
            for point in points {
                let pixel = snapshot.point(for: point.coordinate)
                UIColor(TrackerColors.accent).setFill()
                context.cgContext.fillEllipse(in: CGRect(x: pixel.x - 5, y: pixel.y - 5, width: 10, height: 10))
                UIColor.white.setStroke()
                context.cgContext.strokeEllipse(in: CGRect(x: pixel.x - 5, y: pixel.y - 5, width: 10, height: 10))
            }
        }
    }
}

/// Cancellation enters the same actor as MapKit's snapshotter instead of sharing it across threads.
@MainActor private final class AchievementMapRequest {
    let snapshotter: MKMapSnapshotter
    init(options: MKMapSnapshotter.Options) { snapshotter = MKMapSnapshotter(options: options) }
}
