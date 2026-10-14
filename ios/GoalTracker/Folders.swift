import SwiftUI

nonisolated enum FolderScope: Hashable {
    case all, unfiled, folder(UUID)
    var folderID: UUID? { if case .folder(let id) = self { id } else { nil } }
    func contains(_ tracker: Tracker) -> Bool {
        switch self {
        case .all: true
        case .unfiled: tracker.folderID == nil
        case .folder(let id): tracker.folderID == id
        }
    }
    func title(in folders: [GoalFolder]) -> String {
        switch self {
        case .all: L.text("All items")
        case .unfiled: L.text("Unfiled")
        case .folder(let id): folders.first { $0.id == id }?.name ?? L.text("Unfiled")
        }
    }
}

struct GoalsLibrary: View {
    let now: Date
    @Environment(AppStore.self) private var store
    @State private var path: [FolderScope] = []
    @State private var editMode = EditMode.inactive
    @State private var creatingTracker: Tracker?
    @State private var editingFolder: GoalFolder?
    @State private var deletingFolder: GoalFolder?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var active: [Tracker] { store.trackers.filter { !$0.archived } }

    var body: some View {
        @Bindable var store = store
        NavigationStack(path: $path) {
            Group {
                if store.folders.isEmpty && active.isEmpty {
                    ContentUnavailableView(L.text("Make room for progress"), systemImage: "leaf",
                        description: Text(L.text("Track a number or mark a day. Start with one thing that matters to you.")))
                } else {
                    List {
                        if store.folders.isEmpty { GoalRows(trackers: active, now: now) }
                        else {
                            Section {
                                folderLink(.all, symbol: "tray.full")
                                folderLink(.unfiled, symbol: "tray")
                            }
                            Section(L.text("Folders")) {
                                ForEach(store.folders) { folder in
                                    folderLink(.folder(folder.id), symbol: "folder")
                                        .contextMenu {
                                            Button(L.text("Rename folder")) { editingFolder = folder }
                                            Button(L.text("Delete folder"), role: .destructive) { deletingFolder = folder }
                                        }
                                        .swipeActions {
                                            Button(L.text("Delete folder"), role: .destructive) { deletingFolder = folder }
                                            Button(L.text("Rename folder")) { editingFolder = folder }.tint(TrackerColors.accent)
                                        }
                                }.onMove { indices, destination in
                                    store.perform {
                                        var folders = store.folders
                                        folders.move(fromOffsets: indices, toOffset: destination)
                                        try store.replace(store.trackers, folders: folders)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle(L.text("Goals"))
            .toolbar {
                if !active.isEmpty || !store.folders.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L.text(editMode.isEditing ? "Done" : "Edit")) { editMode = editMode.isEditing ? .inactive : .active }
                            .accessibilityIdentifier("home.edit")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { create(in: .all) } label: { Label(L.text("Create a tracker"), systemImage: "plus") }
                            .accessibilityIdentifier("folder.createTracker")
                        Button { editingFolder = GoalFolder(name: "") } label: { Label(L.text("New folder"), systemImage: "folder.badge.plus") }
                            .accessibilityIdentifier("folder.create")
                    } label: { Image(systemName: "plus") }
                        .accessibilityLabel(L.text("Add")).accessibilityIdentifier("goals.add")
                }
            }
            .navigationDestination(for: FolderScope.self) { scope in
                FolderContents(scope: scope, now: now, onCreate: { create(in: scope) },
                    onRename: { editingFolder = $0 }, onDelete: { deletingFolder = $0 })
            }
            .onChange(of: store.folders) { _, folders in
                if path.contains(where: { scope in scope.folderID.map { id in !folders.contains { $0.id == id } } ?? false }) { path = [] }
            }
        }
        .statusToast(message: $store.error, identifier: "goals.error", autoDismiss: false)
        .sheet(item: $creatingTracker) { TrackerEditor(initialFolderID: $0.folderID) }
        .sheet(item: $editingFolder) { FolderEditor(folder: $0) }
        .alert(L.text("Delete this folder?"), isPresented: Binding(
            get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }
        )) {
            Button(L.text("Delete folder"), role: .destructive) {
                guard let folder = deletingFolder else { return }
                store.perform { try store.removeFolder(folder.id) }
                deletingFolder = nil
            }.accessibilityIdentifier("folder.delete.confirm")
            Button(L.text("Cancel"), role: .cancel) { deletingFolder = nil }.accessibilityIdentifier("folder.delete.cancel")
        } message: { Text(L.text("Items and records are kept in Unfiled.")) }
    }
    private func create(in scope: FolderScope) {
        var tracker = Tracker(name: "", kind: .number); tracker.folderID = scope.folderID
        creatingTracker = tracker
    }
    private func folderLink(_ scope: FolderScope, symbol: String) -> some View {
        NavigationLink(value: scope) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(scope.title(in: store.folders)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    Text(L.text("Trackers") + " · " + active.filter(scope.contains).count.formatted(.number.locale(L.locale)))
                        .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                }
            } else { HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(TrackerColors.accent).accessibilityHidden(true)
                Text(scope.title(in: store.folders)).foregroundStyle(.primary)
                Spacer()
                Text(active.filter(scope.contains).count, format: .number).monospacedDigit().foregroundStyle(.secondary)
            } }
        }.accessibilityIdentifier(scope.folderID.map { "folder." + $0.uuidString } ?? (scope == .all ? "folder.all" : "folder.unfiled"))
    }
}

private struct FolderContents: View {
    let scope: FolderScope
    let now: Date
    let onCreate: () -> Void
    let onRename: (GoalFolder) -> Void
    let onDelete: (GoalFolder) -> Void
    @Environment(AppStore.self) private var store
    @State private var editMode = EditMode.inactive
    private var active: [Tracker] { store.trackers.filter { !$0.archived && scope.contains($0) } }
    var body: some View {
        Group {
            if active.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if scope.folderID != nil { folderHeading.padding(.horizontal, 16) }
                        ContentUnavailableView(L.text("No items in this folder"), systemImage: "folder")
                    }.padding(.top, 16)
                }
            } else {
                List {
                    Section { GoalRows(trackers: active, now: now) } header: {
                        if scope.folderID != nil { folderHeading }
                    }
                }
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle(scope.folderID == nil ? scope.title(in: store.folders) : L.text("Folder"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let folder = store.folders.first(where: { $0.id == scope.folderID }) {
                    Menu {
                        Button(L.text("Rename folder")) { onRename(folder) }.accessibilityIdentifier("folder.rename")
                        if !active.isEmpty {
                            Button(L.text(editMode.isEditing ? "Done" : "Reorder items")) { editMode = editMode.isEditing ? .inactive : .active }
                        }
                        Button(L.text("Delete folder"), role: .destructive) { onDelete(folder) }.accessibilityIdentifier("folder.delete")
                    } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel(L.text("Folder actions")).accessibilityIdentifier("folder.actions")
                } else if !active.isEmpty {
                    Button(L.text(editMode.isEditing ? "Done" : "Edit")) { editMode = editMode.isEditing ? .inactive : .active }
                        .accessibilityIdentifier("home.edit")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onCreate) { Image(systemName: "plus") }
                    .accessibilityLabel(L.text("Create a tracker")).accessibilityIdentifier("tracker.create")
            }
        }
    }
    private var folderHeading: some View {
        Text(scope.title(in: store.folders)).font(.title2.weight(.semibold)).foregroundStyle(Color.primary)
            .textCase(nil).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
    }
}

private struct GoalRows: View {
    let trackers: [Tracker]
    let now: Date
    @Environment(AppStore.self) private var store
    var body: some View {
        ForEach(trackers) { tracker in
            NavigationLink { TrackerDetail(id: tracker.id, now: now) } label: { TrackerSummary(tracker: tracker, now: now) }
                .accessibilityIdentifier("tracker." + tracker.id.uuidString)
        }.onMove { indices, destination in
            store.perform {
                var next = trackers
                next.move(fromOffsets: indices, toOffset: destination)
                try store.reorder(next.map(\.id))
            }
        }
    }
}

private struct FolderEditor: View {
    let folder: GoalFolder
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @FocusState private var focused: Bool
    @State private var keyboard = EditorKeyboardControl()
    private var existing: Bool { store.folders.contains { $0.id == folder.id } }
    var body: some View {
        NavigationStack {
            Form {
                TextField(L.text("Folder name"), text: $name).focused($focused)
                    .submitLabel(.done).onSubmit { focused = false }.accessibilityIdentifier("folder.name")
            }
            .scrollDismissesKeyboard(.interactively)
            .background(EditorKeyboardDismissal(keyboard: keyboard) { focused = false })
            .navigationTitle(L.text(existing ? "Folder name" : "New folder"))
            .navigationBarTitleDisplayMode(.inline)
            .statusToast(message: $error, identifier: "folder.error", autoDismiss: false)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.text("Cancel")) { dismiss() }.accessibilityIdentifier("folder.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.text("Save")) {
                        do {
                            var candidate = folder; candidate.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            try store.saveFolder(candidate); dismiss()
                        } catch { self.error = L.error(error) }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 120)
                        .accessibilityIdentifier("folder.save")
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer(); Button(L.text("Done")) { keyboard.dismiss(); focused = false }
                        .accessibilityIdentifier("folder.keyboard.done")
                }
            }
            .onAppear { name = folder.name; focused = true }
        }
    }
}

struct FolderFilter: View {
    @Binding var scope: FolderScope
    @Environment(AppStore.self) private var store
    var body: some View {
        Menu {
            Picker(L.text("Folder"), selection: $scope) {
                Text(L.text("All items")).tag(FolderScope.all)
                Text(L.text("Unfiled")).tag(FolderScope.unfiled)
                ForEach(store.folders) { Text($0.name).tag(FolderScope.folder($0.id)) }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "folder").foregroundStyle(TrackerColors.accent)
                Text(scope.title(in: store.folders)).foregroundStyle(Color.primary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(Color.secondary)
            }.font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("today.folder")
    }
}
