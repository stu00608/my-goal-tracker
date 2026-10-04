import WidgetKit
import SwiftUI
import MapKit

nonisolated struct CardMapImages {
    let light: Data?
    let dark: Data?
}
nonisolated struct ProgressEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    var mapImages: [UUID: CardMapImages] = [:]
}
nonisolated struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> ProgressEntry { ProgressEntry(date: Date(), snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping @Sendable (ProgressEntry) -> Void) {
        let limit = context.family == .systemSmall ? 1 : 3
        Task { @MainActor in completion(await readWithMaps(limit: limit)) }
    }
    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<ProgressEntry>) -> Void) {
        let limit = context.family == .systemSmall ? 1 : 3
        Task { @MainActor in
            let entry = await readWithMaps(limit: limit)
            let next = entry.snapshot?.nextRefresh(after: entry.date) ?? entry.date.addingTimeInterval(3600)
            completion(Timeline(entries: [entry, ProgressEntry(date: next, snapshot: entry.snapshot, mapImages: entry.mapImages)], policy: .after(next)))
        }
    }
    @MainActor private func readWithMaps(limit: Int) async -> ProgressEntry {
        let snapshot = WidgetSnapshot.url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(WidgetSnapshot.self, from: $0) }
        var entry = ProgressEntry(date: Date(), snapshot: snapshot)
        for row in snapshot?.rows.prefix(limit) ?? [].prefix(limit) where row.resolvedBackground == .map {
            let locations = Array((row.locations ?? []).filter(\.isValid).suffix(24))
            guard !locations.isEmpty else { continue }
            async let light = mapImage(locations, dark: false)
            async let dark = mapImage(locations, dark: true)
            entry.mapImages[row.id] = await CardMapImages(light: light, dark: dark)
        }
        return ProgressEntry(date: Date(), snapshot: snapshot, mapImages: entry.mapImages)
    }
    @MainActor private func mapImage(_ locations: [RecordedLocation], dark: Bool) async -> Data? {
        let options = MKMapSnapshotter.Options()
        options.size = CGSize(width: 320, height: 140)
        options.traitCollection = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        options.pointOfInterestFilter = .excludingAll
        var rect = MKMapRect.null
        for location in locations {
            let point = MKMapPoint(CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude))
            guard point.x.isFinite && point.y.isFinite else { return nil }
            let radius = 500 / max(MKMetersPerMapPointAtLatitude(location.latitude), 0.01)
            rect = rect.union(MKMapRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        }
        options.mapRect = rect.insetBy(dx: -rect.width * 0.15, dy: -rect.height * 0.15)
        let snapshotter = MKMapSnapshotter(options: options)
        // A failed/offline preview must not hold up the entire Widget timeline.
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { snapshotter.cancel() }
        }
        defer { timeout.cancel() }
        guard let snapshot = try? await snapshotter.start() else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: options.size, format: format).image { _ in
            snapshot.image.draw(in: CGRect(origin: .zero, size: options.size))
            let marker = UIImage(systemName: "mappin.circle.fill")?.withTintColor(.systemTeal, renderingMode: .alwaysOriginal)
            for location in locations {
                let point = snapshot.point(for: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude))
                marker?.draw(in: CGRect(x: point.x - 9, y: point.y - 18, width: 18, height: 18))
            }
        }
        return image.jpegData(compressionQuality: 0.7)
    }
}

struct GoalWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    let entry: ProgressEntry
    private var locale: Locale { Locale(identifier: entry.snapshot?.language ?? Locale.current.identifier) }
    private func text(_ key: String) -> String {
        let language = entry.snapshot?.language ?? Locale.preferredLanguages.first ?? "en"
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
    var body: some View {
        ViewThatFits(in: .vertical) {
            content(limit: family == .systemSmall || dynamicTypeSize.isAccessibilitySize ? 1 : 3, compact: family != .systemSmall)
            if family == .systemMedium { content(limit: 2, compact: true) }
            content(limit: 1, compact: true, showGap: family != .systemSmall)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(family == .systemSmall ? entry.snapshot?.rows.first?.recordURL : URL(string: "goaltracker://today"))
    }
    private func content(limit: Int, compact: Bool, showGap: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if family == .systemSmall {
                Label(text("Your progress"), systemImage: "chart.xyaxis.line").font(.caption.weight(.semibold)).foregroundStyle(.teal).lineLimit(1)
            }
            if let rows = entry.snapshot?.rows, !rows.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(Array(rows.prefix(limit))) { row in
                        Link(destination: row.recordURL) {
                            TrackerCardSurface(row: row, now: entry.date, locale: locale, text: text, compact: compact, showGap: showGap) {
                                let images = entry.mapImages[row.id]
                                let data = colorScheme == .dark ? images?.dark : images?.light
                                TrackerCardBackdrop(row: row, text: text, mapImage: data.flatMap(UIImage.init(data:)))
                            }
                        }.buttonStyle(.plain).privacySensitive()
                    }
                }
            } else { Text(text("Open the app to add your first tracker.")).font(.caption).foregroundStyle(.secondary) }
        }.fixedSize(horizontal: false, vertical: true)
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
