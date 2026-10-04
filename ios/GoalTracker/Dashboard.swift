import SwiftUI
import MapKit

struct DashboardView: View {
    let trackers: [Tracker]
    let now: Date
    var editing = false
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
        return VStack(alignment: .leading, spacing: 0) {
            Button { onRecord(tracker) } label: {
                TrackerCardSurface(row: row, now: now, locale: L.locale, text: L.text) {
                    if row.resolvedBackground == .map, let locations = row.locations, !locations.isEmpty {
                        Map(interactionModes: []) {
                            ForEach(Array(locations.enumerated()), id: \.offset) { _, location in
                                Marker(tracker.name, coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude))
                            }
                        }.mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                    } else { TrackerCardBackdrop(row: row, text: L.text) }
                }
                .frame(minHeight: grid ? 200 : 164)
                .contentShape(RoundedRectangle(cornerRadius: 20))
            }
            .buttonStyle(.plain)
            .disabled(editing)
            .accessibilityHint(L.text("Record progress"))
            .accessibilityIdentifier("card." + tracker.id.uuidString)
            .accessibilityAction(named: Text(L.text("Move up"))) { move(tracker, offset: -1) }
            .accessibilityAction(named: Text(L.text("Move down"))) { move(tracker, offset: 1) }
            HStack {
                NavigationLink { TrackerDetail(id: tracker.id) } label: {
                    if editing {
                        Image(systemName: "chart.xyaxis.line").frame(minWidth: 44, minHeight: 44)
                    } else {
                        Label(L.text("Details"), systemImage: "chart.xyaxis.line")
                            .font(.caption).padding(.horizontal, 12).frame(minHeight: 44)
                    }
                }
                .accessibilityLabel(L.text("Details") + ": " + tracker.name)
                .accessibilityIdentifier("card.detail." + tracker.id.uuidString)
                Spacer(minLength: 0)
                if editing {
                    Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).accessibilityHidden(true)
                    moveButton(tracker, offset: -1)
                    moveButton(tracker, offset: 1)
                }
            }
        }
        .draggable(tracker.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let source = items.first.flatMap(UUID.init(uuidString:)), source != tracker.id,
                  active.contains(where: { $0.id == source }) else { return false }
            onReorder(source, tracker.id)
            return true
        }
        .contextMenu {
            Button(L.text("Record progress"), systemImage: "plus") { onRecord(tracker) }
            NavigationLink { TrackerDetail(id: tracker.id) } label: { Label(L.text("Details"), systemImage: "chart.xyaxis.line") }
            Button(L.text("Move up"), systemImage: "arrow.up") { move(tracker, offset: -1) }.disabled(!canMove(tracker, offset: -1))
            Button(L.text("Move down"), systemImage: "arrow.down") { move(tracker, offset: 1) }.disabled(!canMove(tracker, offset: 1))
        }
    }
    private func moveButton(_ tracker: Tracker, offset: Int) -> some View {
        Button { move(tracker, offset: offset) } label: {
            Image(systemName: offset < 0 ? "arrow.up" : "arrow.down").frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(L.text(offset < 0 ? "Move up" : "Move down") + ": " + tracker.name)
        .accessibilityIdentifier("card." + (offset < 0 ? "moveEarlier." : "moveLater.") + tracker.id.uuidString)
        .disabled(!canMove(tracker, offset: offset))
    }
    private func canMove(_ tracker: Tracker, offset: Int) -> Bool {
        guard let index = active.firstIndex(where: { $0.id == tracker.id }) else { return false }
        return active.indices.contains(index + offset)
    }
    private func move(_ tracker: Tracker, offset: Int) {
        guard let index = active.firstIndex(where: { $0.id == tracker.id }), active.indices.contains(index + offset) else { return }
        onReorder(tracker.id, active[index + offset].id)
    }
}
