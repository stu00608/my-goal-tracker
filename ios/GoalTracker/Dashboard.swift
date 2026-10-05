import SwiftUI
import MapKit

struct DashboardView: View {
    let trackers: [Tracker]
    let now: Date
    let onRecord: (Tracker) -> Void
    // Move the source to the target's original index; adjacent targets implement move up/down.
    let onDetails: (Tracker) -> Void
    let onEdit: (Tracker) -> Void
    let onArchive: (Tracker) -> Void
    let onReorder: (UUID, UUID) -> Void
    var cancelForPresentation = false
    var onBegin: () -> Void = {}
    var onFailure: (String) -> Void = { _ in }
    @AppStorage("recordLocationByDefault", store: L.defaults) private var recordLocationByDefault = false
    @AppStorage("homeLayout") private var homeLayout = "grid"
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var dailyControlTextInset = 32
    private var active: [Tracker] { trackers.filter { !$0.archived } }
    private var grid: Bool { homeLayout != "list" && !dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        GeometryReader { geometry in
            let edge = max(0, (geometry.size.width - CardLayout.screenInset * 2 - CardLayout.gridSpacing) / 2)
            ScrollView {
                LazyVGrid(columns: grid ? Array(repeating: GridItem(.fixed(edge), spacing: CardLayout.gridSpacing), count: 2) : [GridItem(.flexible())], spacing: CardLayout.gridSpacing) {
                    ForEach(active) { tracker in card(tracker, edge: grid ? edge : nil) }
                }.padding(CardLayout.screenInset)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityIdentifier(grid ? "dashboard.grid" : "dashboard.list")
        .navigationTitle(L.text("Today"))
    }
    private func card(_ tracker: Tracker, edge: CGFloat?) -> some View {
        let row = WidgetRow(tracker, now: now)
        return Button { onRecord(tracker) } label: {
            TrackerCardSurface(row: row, now: now, locale: L.locale, text: L.text, minimumHeight: grid ? 0 : CardLayout.listHeight, fillsHeight: grid, showsDailyStatus: false) {
                if row.resolvedBackground == .map, let locations = row.locations, !locations.isEmpty {
                    Map(position: .constant(.rect(CardMapFraming.rect(locations: locations, textPosition: row.resolvedTextPosition) ?? .world)), interactionModes: []) {
                        ForEach(Array(locations.enumerated()), id: \.offset) { _, location in
                            Marker(tracker.name, coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)).annotationTitles(.hidden).tint(TrackerColors.accent)
                        }
                    }.mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                        .overlay { CardPhotoReadabilityGradient(position: row.resolvedTextPosition, lightText: colorScheme == .dark) }
                } else { TrackerCardBackdrop(row: row, text: L.text, now: now, locale: L.locale) }
            }
            .modifier(DashboardTileSize(edge: edge))
            .contentShape(RoundedRectangle(cornerRadius: CardLayout.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint(L.text("Record progress"))
        .accessibilityIdentifier("card." + tracker.id.uuidString)
        .overlayPreferenceValue(DailyControlAnchor.self) { anchor in
            if tracker.kind == .daily {
                GeometryReader { geometry in
                    let bounds = anchor.map { geometry[$0] }
                    let fallbackY: CGFloat = row.resolvedBackground == .map ? CardLayout.hiddenControlInset : geometry.size.height - CardLayout.hiddenControlInset
                    DailyCompletionButton(tracker: tracker, now: now,
                        recordLocationByDefault: recordLocationByDefault,
                        cancelForPresentation: cancelForPresentation,
                        onEditor: onRecord, onBegin: onBegin, onFailure: onFailure)
                        .tint(completionTint(row))
                        .position(x: bounds.map { $0.maxX - dailyControlTextInset / 2 + 2 } ?? geometry.size.width - CardLayout.hiddenControlInset,
                                  y: bounds?.midY ?? fallbackY)
                }
            }
        }
        .contextMenu { TrackerContextMenu(tracker: tracker, onDetails: onDetails, onEdit: onEdit, onArchive: onArchive) }
        .modifier(TrackerReorderInteraction(id: tracker.id, active: active, onReorder: onReorder))
    }
    private func completionTint(_ row: WidgetRow) -> Color {
        guard row.hasPhoto, let thumbnail = row.thumbnail else { return TrackerColors.accent }
        return CardImageContrast.prefersLightText(thumbnail, position: row.resolvedTextPosition) ? .white : .black
    }
}

/// Both Today layouts share native lift/drop and the same accessible move destinations.
struct TrackerReorderInteraction: ViewModifier {
    var enabled = true
    let id: UUID
    let active: [Tracker]
    let onReorder: (UUID, UUID) -> Void
    @State private var targeted = false
    @State private var dropCount = 0

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard let source = items.first.flatMap(UUID.init(uuidString:)), source != id,
                          active.contains(where: { $0.id == source }) else { return false }
                    onReorder(source, id); dropCount += 1; return true
                } isTargeted: { targeted = $0 }
                .overlay {
                    RoundedRectangle(cornerRadius: CardLayout.radius, style: .continuous).strokeBorder(Color.accentColor, lineWidth: targeted ? 3 : 0)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                .sensoryFeedback(.impact, trigger: dropCount)
                .accessibilityActions {
                    if let earlier = neighbor(-1) { Button(L.text("Move up")) { onReorder(id, earlier) } }
                    if let later = neighbor(1) { Button(L.text("Move down")) { onReorder(id, later) } }
                }
        } else { content }
    }
    private func neighbor(_ offset: Int) -> UUID? {
        guard let index = active.firstIndex(where: { $0.id == id }), active.indices.contains(index + offset) else { return nil }
        return active[index + offset].id
    }
}

private struct DashboardTileSize: ViewModifier {
    let edge: CGFloat?
    @ViewBuilder func body(content: Content) -> some View {
        if let edge { content.frame(width: edge, height: edge) }
        else { content.fixedSize(horizontal: false, vertical: true) }
    }
}
