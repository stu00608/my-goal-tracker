import WidgetKit
import SwiftUI
import MapKit
import AppIntents

nonisolated struct CardMapImages {
    let light: Data?
    let dark: Data?
}
nonisolated struct TrackerChoice: AppEntity {
    let id: UUID
    let name: String
    var detail: String?
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tracker"
    static let defaultQuery = TrackerChoiceQuery()
    var displayRepresentation: DisplayRepresentation {
        // The Home Screen's compact picker omits subtitles, so duplicate names need a distinct title.
        if let detail { DisplayRepresentation(title: "\(name) · \(detail)") }
        else { DisplayRepresentation(title: "\(name)") }
    }
}

nonisolated struct TrackerChoiceQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [TrackerChoice] {
        let snapshot = WidgetSnapshot.read()
        let choices = snapshot.map(makeChoices) ?? []
        return identifiers.map { id in
            choices.first { $0.id == id } ?? TrackerChoice(id: id, name: String(localized: "Unavailable tracker"))
        }
    }
    func suggestedEntities() async throws -> [TrackerChoice] {
        WidgetSnapshot.read().map(makeChoices) ?? []
    }
    private func makeChoices(_ snapshot: WidgetSnapshot) -> [TrackerChoice] {
        let locale = Locale(identifier: snapshot.language)
        func summary(_ row: WidgetRow) -> String {
            let type = String(localized: row.kind == .number ? "Number snapshot" : "Completion record")
            if row.kind == .number {
                let value = row.value.flatMap(Numbers.decimal).map { Numbers.display($0, precision: row.precision, locale: locale) }
                return [type, value, row.unit.isEmpty ? nil : row.unit].compactMap { $0 }.joined(separator: " · ")
            }
            let tracker = row.tracker, now = Date()
            let count = tracker.rule(at: now).map { "\(tracker.count(in: tracker.interval(now, period: $0.period))) / \($0.target)" }
            return [type, count].compactMap { $0 }.joined(separator: " · ")
        }
        return snapshot.rows.map { row in
            let duplicates = snapshot.rows.filter { $0.name == row.name }
            guard duplicates.count > 1 else { return TrackerChoice(id: row.id, name: row.name) }
            let description = summary(row)
            let identical = duplicates.filter { summary($0) == description }
            var detail = description
            if identical.count > 1 {
                var length = 8
                while identical.contains(where: { $0.id != row.id && $0.id.uuidString.prefix(length) == row.id.uuidString.prefix(length) }) { length += 1 }
                detail = row.id.uuidString.prefix(length) + " · " + description
            }
            return TrackerChoice(id: row.id, name: row.name, detail: detail)
        }
    }
    func defaultResult() async -> TrackerChoice? { try? await suggestedEntities().first }
}

struct SelectTrackerIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Select tracker"
    static let description = IntentDescription("Choose the tracker shown in this widget.")
    @Parameter(title: "Tracker") var tracker: TrackerChoice?
}

nonisolated struct ProgressEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    var selectedID: UUID?
    var mapImages: [UUID: CardMapImages] = [:]
    var row: WidgetRow? { snapshot?.row(selectedID: selectedID) }
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ProgressEntry { ProgressEntry(date: Date(), snapshot: nil) }
    func snapshot(for configuration: SelectTrackerIntent, in context: Context) async -> ProgressEntry {
        await readWithMaps(selectedID: configuration.tracker?.id)
    }
    func timeline(for configuration: SelectTrackerIntent, in context: Context) async -> Timeline<ProgressEntry> {
        let entry = await readWithMaps(selectedID: configuration.tracker?.id)
        let next = entry.snapshot?.nextRefresh(after: entry.date) ?? entry.date.addingTimeInterval(3600)
        return Timeline(entries: [entry, ProgressEntry(date: next, snapshot: entry.snapshot, selectedID: entry.selectedID, mapImages: entry.mapImages)], policy: .after(next))
    }
    @MainActor private func readWithMaps(selectedID: UUID?) async -> ProgressEntry {
        var entry = ProgressEntry(date: Date(), snapshot: WidgetSnapshot.read(), selectedID: selectedID)
        if let row = entry.row, row.resolvedBackground == .map {
            let locations = Array((row.locations ?? []).filter(\.isValid).suffix(24))
            if !locations.isEmpty {
                async let light = mapImage(locations, dark: false)
                async let dark = mapImage(locations, dark: true)
                entry.mapImages[row.id] = await CardMapImages(light: light, dark: dark)
            }
        }
        return entry
    }
    @MainActor private func mapImage(_ locations: [RecordedLocation], dark: Bool) async -> Data? {
        let options = MKMapSnapshotter.Options()
        options.size = CGSize(width: 320, height: 320)
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: ProgressEntry
    private var locale: Locale { Locale(identifier: entry.snapshot?.language ?? Locale.current.identifier) }
    private var monochrome: Bool { renderingMode != .fullColor }
    private func text(_ key: String) -> String {
        let language = entry.snapshot?.language ?? Locale.preferredLanguages.first ?? "en"
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                if let row = entry.row {
                    backdrop(row).frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        .allowsHitTesting(false).accessibilityHidden(true)
                    TrackerCardLabel(row: row, now: entry.date, locale: locale, text: text, compact: true, monochrome: monochrome)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .padding(16).padding(.bottom, row.resolvedBackground == .map && !monochrome ? 18 : 0)
                } else {
                    Text(text(entry.selectedID == nil ? "Open the app to add your first tracker." : "This tracker is unavailable. Edit the widget to choose another."))
                        .font(.caption).foregroundStyle(.primary).padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .containerBackground(Color(uiColor: .secondarySystemGroupedBackground), for: .widget)
        .widgetURL(entry.row?.recordURL ?? URL(string: "goaltracker://today"))
        .privacySensitive()
    }
    @ViewBuilder private func backdrop(_ row: WidgetRow) -> some View {
        if row.resolvedBackground == .plot {
            TrackerCardBackdrop(row: row, text: text, monochrome: monochrome)
                .opacity(monochrome ? 0.45 : 1)
        } else {
            let images = entry.mapImages[row.id]
            let data = row.resolvedBackground == .photo ? row.thumbnail : colorScheme == .dark ? images?.dark : images?.light
            if let data, let image = UIImage(data: data) {
                if #available(iOS 18, *) {
                    Image(uiImage: image).resizable().widgetAccentedRenderingMode(.desaturated).scaledToFill()
                        .opacity(monochrome ? 0.22 : 1)
                } else { Image(uiImage: image).resizable().scaledToFill() }
            } else { TrackerCardBackdrop(row: row, text: text, monochrome: monochrome).opacity(monochrome ? 0.45 : 1) }
        }
    }
}

@main struct GoalTrackerWidget: Widget {
    let kind = WidgetSnapshot.kind
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectTrackerIntent.self, provider: Provider()) { entry in GoalWidgetView(entry: entry) }
            .configurationDisplayName("Your progress")
            .description("Numbers and completion records, at a glance.")
            .supportedFamilies([.systemSmall])
            .contentMarginsDisabled()
    }
}
