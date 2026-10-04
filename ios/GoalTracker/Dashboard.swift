import SwiftUI
import MapKit

struct DashboardView: View {
    let trackers: [Tracker]
    let now: Date
    let onRecord: (Tracker) -> Void
    // Move the source to the target's original index; adjacent targets implement move up/down.
    let onReorder: (UUID, UUID) -> Void
    @AppStorage("homeLayout") private var homeLayout = "grid"
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var active: [Tracker] { trackers.filter { !$0.archived } }
    private var grid: Bool { homeLayout != "list" && !dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: grid ? 2 : 1), spacing: 12) {
                ForEach(active) { tracker in card(tracker) }
            }.padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityIdentifier(grid ? "dashboard.grid" : "dashboard.list")
        .navigationTitle(L.text("Today"))
    }
    private func card(_ tracker: Tracker) -> some View {
        let row = WidgetRow(tracker, now: now)
        return Button { onRecord(tracker) } label: {
            TrackerCardSurface(row: row, now: now, locale: L.locale, text: L.text, minimumHeight: grid ? 0 : 164, fillsHeight: grid) {
                if row.resolvedBackground == .map, let locations = row.locations, !locations.isEmpty {
                    Map(interactionModes: []) {
                        ForEach(Array(locations.enumerated()), id: \.offset) { _, location in
                            Marker(tracker.name, coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)).annotationTitles(.hidden)
                        }
                    }.mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                } else { TrackerCardBackdrop(row: row, text: L.text) }
            }
            .modifier(DashboardTileSize(square: grid))
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityHint(L.text("Record progress"))
        .accessibilityIdentifier("card." + tracker.id.uuidString)
        .modifier(TrackerReorderInteraction(id: tracker.id, active: active, onReorder: onReorder))
    }
}

/// Both Today layouts share native lift/drop and the same accessible move destinations.
struct TrackerReorderInteraction: ViewModifier {
    var enabled = true
    let id: UUID
    let active: [Tracker]
    let onReorder: (UUID, UUID) -> Void
    @State private var targeted = false

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard let source = items.first.flatMap(UUID.init(uuidString:)), source != id,
                          active.contains(where: { $0.id == source }) else { return false }
                    onReorder(source, id); return true
                } isTargeted: { targeted = $0 }
                .overlay {
                    RoundedRectangle(cornerRadius: 20).strokeBorder(Color.accentColor, lineWidth: targeted ? 3 : 0)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
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
    let square: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if square { content.aspectRatio(1, contentMode: .fit) }
        else { content.fixedSize(horizontal: false, vertical: true) }
    }
}
