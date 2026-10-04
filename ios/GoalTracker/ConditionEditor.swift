import SwiftUI
import MapKit
import Observation

struct ConditionEditor: View {
    @Environment(\.dismiss) private var dismiss
    let existing: PlaceCondition?
    let onSave: (PlaceCondition) -> Void
    @State private var search = PlaceSearch()
    @State private var name = ""
    @State private var relation = PlaceRelation.inside
    @State private var selected: RecordedLocation?
    @State private var camera = MapCameraPosition.automatic
    @State private var initialized = false
    private enum Field: Hashable { case search, name }
    @FocusState private var focusedField: Field?
    @State private var keyboard = EditorKeyboardControl()

    var body: some View {
        NavigationStack {
            Form {
                if mapFirst { mapSection; searchSection }
                else { searchSection; mapSection }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(EditorKeyboardDismissal(keyboard: keyboard, dismiss: endEditing))
            .navigationTitle(L.text("Place"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L.text("Cancel")) { search.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.text("Done")) {
                        guard let selected else { return }
                        var condition = existing ?? PlaceCondition(name: name, location: selected)
                        condition.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        condition.location = selected; condition.relation = relation
                        onSave(condition); dismiss()
                    }.disabled(selected == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 120)
                        .accessibilityIdentifier("condition.confirm")
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button(L.text("Done")) { endEditing() } }
            }
            .onAppear {
                guard !initialized else { return }; initialized = true
                if let existing {
                    name = existing.name; relation = existing.relation; selected = existing.location
                    camera = position(existing.location)
                }
            }
            .onChange(of: search.query) { _, value in search.complete(value) }
            .onDisappear { search.cancel() }
        }
    }
    private var searchSection: some View {
        Section {
            TextField(L.text("Search for a place or address"), text: $search.query)
                .textInputAutocapitalization(.words).autocorrectionDisabled()
                .focused($focusedField, equals: .search).submitLabel(.search)
                .accessibilityIdentifier("condition.search")
                .onSubmit { search.findQuery { choose($0) } }
            if search.loading { ProgressView(L.text("Finding place…")) }
            ForEach(Array(search.suggestions.enumerated()), id: \.offset) { _, suggestion in
                Button {
                    endEditing(); search.find(suggestion) { choose($0) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(suggestion.title).foregroundStyle(.primary)
                        if !suggestion.subtitle.isEmpty { Text(suggestion.subtitle).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.accessibilityIdentifier("condition.search.result")
            }
            if let error = search.error {
                Text(L.text(error)).foregroundStyle(.red).accessibilityIdentifier("condition.search.error")
            }
        } header: { Text(L.text("Place")) }
    }
    private var mapSection: some View {
        Section {
            MapReader { proxy in
                Map(position: $camera) {
                    if let selected {
                        Marker(name.isEmpty ? L.text("Selected place") : name, coordinate: coordinate(selected))
                        MapCircle(center: coordinate(selected), radius: PlaceCondition.radius)
                            .foregroundStyle(.blue.opacity(0.16)).stroke(.blue, lineWidth: 2)
                    }
                }
                .onTapGesture { point in
                    guard let coordinate = proxy.convert(point, from: .local) else { return }
                    endEditing(); search.cancel()
                    self.selected = RecordedLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = L.text("Selected place") }
                    camera = position(self.selected!)
                }
                .accessibilityLabel(L.text("Selected place and 200 m boundary"))
                .accessibilityIdentifier("condition.map")
            }.frame(height: 260).listRowInsets(EdgeInsets())
            if selected != nil {
                TextField(L.text("Place name"), text: $name).focused($focusedField, equals: .name).accessibilityIdentifier("condition.name")
                Picker(L.text("Condition"), selection: $relation) {
                    Text(L.text("Inside")).tag(PlaceRelation.inside)
                    Text(L.text("Outside")).tag(PlaceRelation.outside)
                }.pickerStyle(.segmented).accessibilityIdentifier("condition.relation")
            } else {
                Text(L.text("Search and choose a result to place the pin.")).foregroundStyle(.secondary)
                    .accessibilityIdentifier("condition.empty")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(L.text("Tap the map to move the pin. Use search to select a place with VoiceOver."))
                Text(L.text("The fixed boundary is 200 m. Location accuracy can affect verification."))
            }
        }
    }
    private func endEditing() { keyboard.dismiss(); focusedField = nil }
    private var mapFirst: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--uitesting") && ProcessInfo.processInfo.arguments.contains("--condition-map-first")
        #else
        false
        #endif
    }
    private func choose(_ item: MKMapItem) {
        let point = item.placemark.coordinate
        let location = RecordedLocation(latitude: point.latitude, longitude: point.longitude)
        selected = location; name = item.name ?? search.query
        endEditing(); search.suggestions = []
        camera = position(location)
    }
    private func coordinate(_ location: RecordedLocation) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
    }
    private func position(_ location: RecordedLocation) -> MapCameraPosition {
        .region(MKCoordinateRegion(center: coordinate(location), latitudinalMeters: 1000, longitudinalMeters: 1000))
    }
}

@MainActor @Observable private final class PlaceSearch: NSObject, @preconcurrency MKLocalSearchCompleterDelegate {
    var query = ""
    var suggestions: [MKLocalSearchCompletion] = []
    var loading = false
    var error: String?
    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    @ObservationIgnored private var request: MKLocalSearch?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    override init() {
        super.init()
        completer.delegate = self; completer.resultTypes = [.address, .pointOfInterest]
    }
    func complete(_ query: String) {
        request?.cancel(); task?.cancel(); loading = false
        generation = UUID(); error = nil
        completer.queryFragment = query
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { suggestions = [] }
    }
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        suggestions = Array(completer.results.prefix(8))
    }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        self.error = "Could not search places. Check your connection and try again."
    }
    func find(_ completion: MKLocalSearchCompletion, receive: @escaping (MKMapItem) -> Void) {
        find(MKLocalSearch.Request(completion: completion), receive: receive)
    }
    func findQuery(receive: @escaping (MKMapItem) -> Void) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query
        find(request, receive: receive)
    }
    private func find(_ request: MKLocalSearch.Request, receive: @escaping (MKMapItem) -> Void) {
        cancel(); loading = true; error = nil
        let token = UUID(); generation = token
        let search = MKLocalSearch(request: request); self.request = search
        task = Task {
            do {
                let response = try await search.start()
                guard !Task.isCancelled, generation == token else { return }
                guard let item = response.mapItems.first else {
                    loading = false; error = "No places found. Try a more specific address."; return
                }
                loading = false; receive(item)
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                loading = false; self.error = "Could not search places. Check your connection and try again."
            }
        }
    }
    func cancel() {
        generation = UUID()
        request?.cancel(); request = nil
        task?.cancel(); task = nil
        completer.cancel(); loading = false
    }
}
