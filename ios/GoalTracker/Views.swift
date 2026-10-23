import SwiftUI
import Charts
import MapKit

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var selected = 0
    @State private var navigationID = UUID()
    @State private var recording: RecordingRequest?
    @State private var journalScope: RecordScope?

    var body: some View {
        TimelineView(.everyMinute) { _ in screen(at: Date()) }
    }
    private func screen(at date: Date) -> some View {
        TabView(selection: $selected) {
            GoalsLibrary(now: date, journalScope: $journalScope).id(navigationID)
                .tabItem { Label(L.text("Goals"), systemImage: "square.grid.2x2") }.tag(0)
            CompletedTab(trackers: store.trackers, now: date).tabItem { Label(L.text("Completed tab"), systemImage: "sparkles") }.tag(1)
            SettingsView(now: date).tabItem { Label(L.text("Settings"), systemImage: "gearshape") }.tag(2)
        }
        .task(id: store.trackers) {
            do { try await Reminders.sync(store.trackers) }
            catch is CancellationError { }
            catch { store.error = L.error(error) }
        }
        .onOpenURL { url in
            guard url.scheme == "goaltracker", url.host == "today" || url.host == "record" else { return }
            recording = nil; selected = 0; navigationID = UUID()
            journalScope = url.host == "today" ? .today : nil
            if url.host == "record", url.pathComponents.count == 2,
               let id = UUID(uuidString: url.pathComponents[1]), store.trackers.contains(where: { $0.id == id && !$0.archived }) {
                recording = RecordingRequest(trackerID: id)
            }
        }
        .sheet(item: $recording) { RecordingSheet(selectedID: $0.trackerID) }
    }
}

private struct RecordingRequest: Identifiable {
    let id = UUID()
    var trackerID: UUID?
}

private struct RecordingSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var selectedID: UUID?
    @State private var search = ""
    private var trackers: [Tracker] {
        store.trackers.filter { !$0.archived && (search.isEmpty || $0.name.localizedStandardContains(search)) }
    }
    var body: some View {
        if let tracker = store.trackers.first(where: { $0.id == selectedID && !$0.archived }) {
            EntryEditor(tracker: tracker, existing: tracker.kind == .daily ? tracker.entries.first { $0.localDay == tracker.day(Date()) } : nil)
        } else {
            NavigationStack {
                List(trackers) { tracker in
                    Button { selectedID = tracker.id } label: {
                        Label(tracker.name, systemImage: tracker.kind == .number ? "number" : "checkmark.circle")
                            .foregroundStyle(Color.primary).padding(.vertical, 8)
                    }.accessibilityIdentifier("record.choose." + tracker.id.uuidString)
                }
                .overlay { if trackers.isEmpty { ContentUnavailableView(L.text("No matching items"), systemImage: "magnifyingglass", description: Text(search)) } }
                .searchable(text: $search, prompt: L.text("Search items"))
                .navigationTitle(L.text("Record progress")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L.text("Cancel")) { dismiss() }.accessibilityIdentifier("record.cancel")
                    }
                }
            }
        }
    }
}

struct RecordJournal: View {
    @Environment(AppStore.self) private var store
    let now: Date
    @State var scope: RecordScope
    @State private var recording = false
    private var records: [JournalRecord] { JournalRecord.records(in: store.trackers, scope: scope, now: now) }
    private var canRecord: Bool { store.trackers.contains { !$0.archived } }

    var body: some View {
        VStack(spacing: 0) {
            Picker(L.text("Date"), selection: $scope) {
                Text(L.text("All dates")).tag(RecordScope.all)
                Text(L.text("Today")).tag(RecordScope.today)
            }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.vertical, 8)
                .accessibilityIdentifier("records.scope")
            if records.isEmpty {
                ContentUnavailableView {
                    Label { Text(L.text(scope == .today ? "No records today" : "No records yet")) } icon: {
                        Image(systemName: "clock").accessibilityHidden(true)
                    }
                } description: {
                    if !canRecord { Text(L.text("Create an item to start recording.")) }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 20) {
                        ForEach(records) { record in
                            NavigationLink {
                                JournalRecordDetail(trackerID: record.tracker.id, entryID: record.entry.id, now: now)
                            } label: {
                                JournalRecordCard(record: record)
                            }.buttonStyle(.plain).accessibilityIdentifier("journal.record." + record.id)
                        }
                    }.padding(16)
                }.id(scope).accessibilityIdentifier("records.journal")
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(L.text("Record history")).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canRecord {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { recording = true } label: {
                        HStack(spacing: 8) { Image(systemName: "plus"); Text(L.text("Record now")) }
                    }.accessibilityIdentifier("records.add")
                }
            }
        }
        .sheet(isPresented: $recording) { RecordingSheet(selectedID: nil) }
    }
}

private struct JournalRecordCard: View {
    let record: JournalRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) { name; Spacer(minLength: 12); time.fixedSize() }
                VStack(alignment: .leading, spacing: 4) { name; time }
            }
            JournalRecordValue(tracker: record.tracker, entry: record.entry)
                .font(.title2.weight(.semibold)).foregroundStyle(Color.primary)
            if !record.entry.note.isEmpty {
                Text(record.entry.note).font(.subheadline).foregroundStyle(Color.secondary).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let data = record.entry.photos.first, let photo = UIImage(data: data) {
                Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { Image(uiImage: photo).resizable().scaledToFill() }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if record.entry.photos.count > 1 {
                            Label(record.entry.photos.count.formatted(.number.locale(L.locale)), systemImage: "photo.on.rectangle")
                                .font(.subheadline.monospacedDigit()).padding(8)
                                .background(.regularMaterial, in: Capsule()).padding(8)
                        }
                    }.accessibilityElement(children: .ignore)
                    .accessibilityLabel(L.text("Photos") + " · " + record.entry.photos.count.formatted(.number.locale(L.locale)))
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine).accessibilityHint(L.text("View record"))
    }
    private var name: some View {
        Text(record.tracker.name).font(.headline).foregroundStyle(Color.primary).fixedSize(horizontal: false, vertical: true)
    }
    private var time: some View {
        Text(record.entry.occurredAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L.locale, timeZone: record.tracker.calendar.timeZone)))
            .font(.subheadline.monospacedDigit()).foregroundStyle(Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct JournalRecordValue: View {
    let tracker: Tracker
    let entry: Entry
    var body: some View {
        if let value = entry.value.flatMap(Numbers.decimal) {
            Text(Numbers.display(value, precision: tracker.precision, locale: L.locale) + (tracker.unit.isEmpty ? "" : " " + tracker.unit))
                .monospacedDigit().fixedSize(horizontal: false, vertical: true)
        } else {
            Label { Text(L.text("Recorded completion")) } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(TrackerColors.accent)
            }
        }
    }
}

private struct JournalRecordDetail: View {
    let trackerID: UUID
    let entryID: UUID
    let now: Date
    @Environment(AppStore.self) private var store
    @State private var editing = false
    @State private var photoPreview: TrackerPhotoPreview?
    private var tracker: Tracker? { store.trackers.first { $0.id == trackerID } }
    var body: some View {
        Group {
            if let tracker, let entry = tracker.resolvedEntries.first(where: { $0.id == entryID }) {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            JournalRecordValue(tracker: tracker, entry: entry).font(.largeTitle.weight(.semibold))
                            Text(entry.occurredAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L.locale, timeZone: tracker.calendar.timeZone)))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 12)
                    }.listRowBackground(Color.clear)
                    if !entry.note.isEmpty { Section(L.text("Notes")) { Text(entry.note).textSelection(.enabled) } }
                    if !entry.photos.isEmpty {
                        Section(L.text("Photos")) {
                            ForEach(entry.photos.indices, id: \.self) { index in
                                Button { photoPreview = TrackerPhotoPreview(photos: entry.photos, index: index) } label: {
                                    if let photo = UIImage(data: entry.photos[index]) {
                                        Image(uiImage: photo).resizable().scaledToFit()
                                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    }
                                }.buttonStyle(.plain)
                                    .accessibilityLabel(String(format: L.text("Photo %lld of %lld"), locale: L.locale, Int64(index + 1), Int64(entry.photos.count)))
                                    .accessibilityIdentifier("record.photo.\(index)")
                            }
                        }
                    }
                    if let location = entry.location {
                        Section(L.text("Location")) {
                            Map(initialPosition: .rect(CardMapFraming.rect(locations: [location], textPosition: .hidden) ?? .world), interactionModes: []) {
                                Marker(tracker.name, coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude))
                            }.frame(height: DetailStyle.chartHeight).tint(TrackerColors.accent)
                        }
                    }
                    Section {
                        NavigationLink { TrackerDetail(id: tracker.id, now: now) } label: {
                            Label(L.text("View item"), systemImage: "square.grid.2x2")
                        }.accessibilityIdentifier("record.item")
                    }
                }
                .navigationTitle(tracker.name).navigationBarTitleDisplayMode(.inline)
                .accessibilityIdentifier("record.detail")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L.text("Edit")) { editing = true }.accessibilityIdentifier("record.edit")
                    }
                }
                .sheet(isPresented: $editing) {
                    if let raw = tracker.entries.first(where: { $0.id == entryID }) { EntryEditor(tracker: tracker, existing: raw) }
                }
                .fullScreenCover(item: $photoPreview) { PhotoViewer(photos: $0.photos, initialIndex: $0.index) }
            } else { ContentUnavailableView(L.text("No records yet"), systemImage: "tray") }
        }
    }
}

struct DailyCompletionButton: View {
    @Environment(AppStore.self) private var store
    let tracker: Tracker
    let now: Date
    let recordLocationByDefault: Bool
    let cancelForPresentation: Bool
    let onEditor: (Tracker) -> Void
    let onBegin: () -> Void
    let onFailure: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var checking = false
    @State private var verification: Task<Void, Never>?
    @State private var pendingRemoval: (tracker: Tracker, entryID: UUID)?
    @State private var quickLocation = RecordLocationRecorder()
    // Haptics follow the user's action, not `done`, which also flips at midnight or after restores.
    @State private var feedbackTick = 0
    @State private var feedbackCompleted = false
    private var done: Bool { tracker.entries.contains { $0.localDay == tracker.day(now) } }
    var body: some View {
        Button(action: toggle) {
            Group {
                if checking { ProgressView() }
                else { Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.title2)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace)) }
            }.frame(minWidth: 44, minHeight: 44)
        }.buttonStyle(.borderless).disabled(checking)
            .sensoryFeedback(trigger: feedbackTick) { _, _ in feedbackCompleted ? .success : .impact }
            .animation(reduceMotion ? nil : .snappy, value: done)
            .accessibilityLabel(L.text(checking ? "Checking record conditions" : done ? "Undo completion" : "Mark complete") + ": " + tracker.name)
            .accessibilityIdentifier("complete." + tracker.id.uuidString)
            .onDisappear { verification?.cancel(); quickLocation.cancel() }
            .onChange(of: cancelForPresentation) { _, cancel in if cancel { verification?.cancel(); quickLocation.cancel() } }
            .confirmationDialog(L.text("Cancel this completion and its attachments?"), isPresented: Binding(
                get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
            ), titleVisibility: .visible) {
                Button(L.text("Undo completion"), role: .destructive) {
                    guard let pending = pendingRemoval else { return }
                    let original = pending.tracker
                    pendingRemoval = nil
                    guard store.trackers.first(where: { $0.id == original.id }) == original else {
                        onFailure(L.text("Records changed while checking. Try recording again.")); return
                    }
                    var candidate = original
                    candidate.entries.removeAll { $0.id == pending.entryID }
                    store.perform { try store.save(candidate) }
                    feedback(completed: false)
                }
                Button(L.text("Cancel"), role: .cancel) { pendingRemoval = nil }
            } message: { Text(L.text("The record, notes and photos for today will be removed.")) }
    }
    private func feedback(completed: Bool) { feedbackCompleted = completed; feedbackTick += 1 }
    private func toggle() {
        guard !checking, var original = store.trackers.first(where: { $0.id == tracker.id }) else { return }
        onBegin()
        let instant = Date(), day = original.day(instant)
        if let entry = original.entries.first(where: { $0.localDay == day }) {
            if !entry.note.isEmpty || !entry.photos.isEmpty || entry.location != nil { pendingRemoval = (original, entry.id); return }
            original.entries.removeAll { $0.localDay == day }
            store.perform { try store.save(original) }
            feedback(completed: false)
            return
        }
        guard original.requiresConditionGate || recordLocationByDefault else {
            original.put(Entry(occurredAt: instant, localDay: day))
            store.perform { try store.save(original) }
            feedback(completed: true)
            return
        }
        checking = true
        let snapshot = original
        verification = Task {
            defer { checking = false }
            do {
                try await RecordConditions.verify(tracker: snapshot)
                try Task.checkCancellation()
                if recordLocationByDefault {
                    quickLocation.draft = RecordLocationDraft(existing: nil, defaultEnabled: true)
                    await quickLocation.resolveForSave()
                    try Task.checkCancellation()
                    // A location prompt can suspend across a time-condition boundary.
                    try await RecordConditions.verify(tracker: snapshot)
                }
                guard store.trackers.first(where: { $0.id == snapshot.id }) == snapshot else {
                    onFailure(L.text("Records changed while checking. Try recording again.")); return
                }
                var candidate = snapshot
                let instant = Date()
                var entry = Entry(occurredAt: instant, localDay: candidate.day(instant))
                if recordLocationByDefault { entry.location = quickLocation.draft.applying(to: nil) }
                candidate.put(entry)
                try store.save(candidate)
                feedback(completed: true)
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled {
                    onFailure(L.error(error))
                }
            }
        }
    }
}

struct TrackerSummary: View {
    let tracker: Tracker
    var now = Date()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(tracker.name).font(.headline).foregroundStyle(Color.primary)
                if CompletionEngine.isCompleted(tracker: tracker, now: now) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(TrackerColors.accent)
                        .accessibilityLabel(L.text("Completed goal"))
                }
            }
            if tracker.kind == .number {
                if let v = tracker.resolvedEntries.last(where: { $0.occurredAt <= now })?.value.flatMap(Numbers.decimal) {
                    Text(Numbers.display(v, precision: tracker.precision, locale: L.locale) + (tracker.unit.isEmpty ? "" : " " + tracker.unit)).font(.title3.monospacedDigit()).foregroundStyle(Color.primary)
                } else { Text(L.text("No records yet")).foregroundStyle(Color.secondary) }
            } else if let rule = tracker.rule(at: now) {
                Text("\(tracker.count(in: tracker.interval(now, period: rule.period))) / \(rule.target) · " + L.text(rule.period == .weekly ? "This week" : "This month"))
                    .foregroundStyle(Color.primary).monospacedDigit().accessibilityIdentifier("progress." + tracker.id.uuidString)
            } else { Text(L.text(tracker.entries.contains { $0.localDay == tracker.day(now) && $0.occurredAt <= now } ? "Today is recorded" : "No record today")).foregroundStyle(Color.secondary) }
        }.padding(.vertical, 2)
    }
}

struct TrackerContextMenu: View {
    let tracker: Tracker
    let onRecord: (Tracker) -> Void
    let onEdit: (Tracker) -> Void
    let onArchive: (Tracker) -> Void
    var body: some View {
        Button { onRecord(tracker) } label: { Label(L.text("Record progress"), systemImage: "plus") }
            .accessibilityIdentifier("tracker.context.record")
        Button { onEdit(tracker) } label: { Label(L.text("Edit"), systemImage: "pencil") }
            .accessibilityIdentifier("tracker.context.edit")
        Button { onArchive(tracker) } label: { Label(L.text("Archive"), systemImage: "archivebox") }
            .accessibilityIdentifier("tracker.context.archive")
    }
}

@MainActor struct TrackerDetail: View {
    @Environment(AppStore.self) private var store
    let id: UUID
    let now: Date
    @State private var editing = false
    @State private var addEntry = false
    @State private var selectedEntry: Entry?
    @State private var numericView = "Chart"
    @State private var photoPreview: TrackerPhotoPreview?
    @State private var range = ChartRange.ninetyDays
    @State private var customStart = Date()
    @State private var customEnd = Date()
    @State private var initializedRange = false
    @State private var month = Date()
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize = 48
    @State private var reopenCompletion = false
    @State private var completing = false
    @State private var completionError: String?
    @State private var completionTask: Task<Void, Never>?
    @AppStorage("firstWeekday", store: L.defaults) private var firstWeekday = 1
    private var tracker: Tracker? { store.trackers.first { $0.id == id } }
    var body: some View {
        Group {
            if let t = tracker {
                List {
                    Section { hero(t) }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                    if t.kind == .number { numeric(t, now: now) }
                    else { CompletionProgressView(tracker: t, now: now, editGoal: { editing = true }) { daily(t) } }
                    recentRecords(t)
                    content(t)
                    locations(t)
                    CompletionHistoryView(tracker: t, now: now)
                    if t.resolvedLifecycle == .finite {
                        if t.manualCompletion != nil && CompletionEngine.isCompleted(tracker: t, now: now) {
                            Section {
                                Button(L.text("Reopen goal")) { reopenCompletion = true }
                                    .accessibilityIdentifier("tracker.reopen")
                            }
                        } else if t.rules.isEmpty && !CompletionEngine.isCompleted(tracker: t, now: now) {
                            Section {
                                Button(L.text("Complete goal")) { completeManually(t) }
                                    .disabled(completing).accessibilityIdentifier("tracker.complete")
                                if completing { ProgressView(L.text("Checking record conditions")) }
                            }
                        }
                    }
                    if !t.rules.isEmpty {
                        Section(L.text("Goal history")) {
                            ForEach(t.rules.sorted { $0.effectiveAt > $1.effectiveAt }) { rule in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(L.text(rule.period == .weekly ? "Weekly" : rule.period == .monthly ? "Monthly" : "Deadline goal") + " · " + formatted(rule.target, tracker: t))
                                    Text(DetailStyle.date(rule.effectiveAt, calendar: t.calendar, now: now)).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .statusToast(message: Binding(get: { completionError ?? store.error }, set: {
                    if completionError != nil { completionError = $0 } else { store.error = $0 }
                }), identifier: "detail.error", autoDismiss: false)
                .sensoryFeedback(.success, trigger: t.manualCompletion != nil) { !$0 && $1 }
                .sensoryFeedback(.error, trigger: completionError ?? store.error) { _, error in error != nil }
                .navigationTitle(t.name).navigationBarTitleDisplayMode(.inline)
                .environment(\.timeZone, t.calendar.timeZone)
                .environment(\.calendar, t.calendar)
                .onAppear {
                    guard !initializedRange else { return }
                    customEnd = t.calendar.startOfDay(for: now)
                    customStart = t.calendar.date(byAdding: .day, value: -89, to: customEnd) ?? customEnd
                    month = now
                    initializedRange = true
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L.text("Edit")) { editing = true }.accessibilityIdentifier("tracker.menu")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { addEntry = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel(L.text(t.kind == .number ? "Add a snapshot" : "Add a completion"))
                            .accessibilityIdentifier("entry.add")
                    }
                }
                .sheet(isPresented: $editing) { TrackerEditor(existing: t) }
                .sheet(isPresented: $addEntry) { EntryEditor(tracker: t) }
                .sheet(item: $selectedEntry) { selection in
                    EntryEditor(tracker: t, existing: t.entries.first { $0.id == selection.id } ?? selection)
                }
                .fullScreenCover(item: $photoPreview) { PhotoViewer(photos: $0.photos, initialIndex: $0.index) }
                .onDisappear { completionTask?.cancel() }
                .confirmationDialog(L.text("Reopen this goal?"), isPresented: $reopenCompletion, titleVisibility: .visible) {
                    Button(L.text("Reopen goal"), role: .destructive) {
                        store.perform {
                            guard var current = tracker else { return }
                            current.manualCompletion = nil
                            try store.save(current)
                        }
                    }
                    Button(L.text("Cancel"), role: .cancel) { }
                } message: { Text(L.text("The manual completion card will be removed. Your records stay unchanged.")) }

            } else { ContentUnavailableView(L.text("Tracker removed"), systemImage: "archivebox") }
        }
    }
    private func hero(_ t: Tracker) -> some View {
        let entries = t.resolvedEntries.filter { $0.occurredAt <= now }
        let latestText = entries.last?.value.map { formatted($0, tracker: t, withUnit: false) }
        return VStack(alignment: .leading, spacing: 12) {
            if t.kind == .number {
                Text(latestText ?? "—")
                    .font(.system(size: heroSize, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(latestText == nil ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(latestText ?? L.text("No records yet"))
                    .accessibilityIdentifier("detail.value")
                if !t.unit.isEmpty { Text(t.unit).font(.subheadline).foregroundStyle(.secondary) }
                if let value = entries.last?.value.flatMap(Numbers.decimal), let previous = entries.dropLast().last?.value.flatMap(Numbers.decimal) {
                    Text(L.text("Since previous") + " · " + DetailStyle.signedQuantity(value - previous, unit: t.unit, precision: t.precision, locale: L.locale))
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let progress = GoalProgress.current(for: t, now: now) {
                    ProgressView(value: progress.fraction) {
                        let title = Text(L.text(progress.achieved ? "Goal achieved" : "Target"))
                        let value = Text(formatted(progress.target, tracker: t)).monospacedDigit()
                        ViewThatFits(in: .horizontal) {
                            HStack { title.fixedSize(); Spacer(); value.fixedSize() }
                            VStack(alignment: .leading, spacing: 4) { title; value }
                        }.font(.subheadline)
                    }.tint(TrackerColors.accent)
                }
            } else {
                let period = CompletionProgressData.current(for: t, now: now)
                let count = period?.count ?? t.count(in: t.interval(now, period: .weekly))
                Text(count.formatted(.number.locale(L.locale)) + (period?.target.map { " / " + $0.formatted(.number.locale(L.locale)) } ?? ""))
                    .font(.system(size: heroSize, weight: .semibold, design: .rounded)).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("detail.value")
                Text(L.text(period?.period == .monthly ? "This month" : "This week")).font(.subheadline).foregroundStyle(.secondary)
                if let period { ProgressView(value: period.fraction).tint(TrackerColors.accent) }
            }
        }.padding(.vertical, 12).foregroundStyle(.primary)
    }
    private func recentRecords(_ t: Tracker) -> some View {
        Section(L.text("Recent records")) {
            if t.entries.isEmpty { Text(L.text("No records yet")).foregroundStyle(.secondary) }
            ForEach(Array(t.resolvedEntries.reversed().prefix(5))) { entry in
                DetailRecordRow(tracker: t, entry: entry, now: now) { selectedEntry = entry }
            }
            if !t.entries.isEmpty {
                NavigationLink(L.text("All records")) {
                    List {
                        ForEach(t.resolvedEntries.reversed()) { entry in
                            DetailRecordRow(tracker: t, entry: entry, now: now) { selectedEntry = entry }
                        }
                    }.navigationTitle(L.text("All records")).accessibilityIdentifier("timeline.all")
                }.accessibilityIdentifier("timeline.open")
            }
        }
    }

    private func completeManually(_ original: Tracker) {
        guard !completing else { return }
        completionError = nil
        completing = true
        completionTask = Task {
            defer { completing = false }
            do {
                try await RecordConditions.verify(tracker: original)
                try Task.checkCancellation()
                guard tracker == original else { throw ConditionError("Records changed while checking. Try recording again.") }
                var candidate = original
                candidate.manualCompletion = CompletionEngine.manualSnapshot(tracker: original, now: Date())
                try store.save(candidate)
            } catch is CancellationError { }
            catch { completionError = L.error(error) }
        }
    }
    @ViewBuilder private func content(_ t: Tracker) -> some View {
        if t.description?.isEmpty == false || validatedWebsite(t.website) != nil {
            Section {
                if let description = t.description, !description.isEmpty {
                    Text(description).textSelection(.enabled).accessibilityIdentifier("tracker.description")
                }
                if let url = validatedWebsite(t.website) {
                    Link(destination: url) { Label(L.text("Website"), systemImage: "arrow.up.right.square") }
                        .accessibilityIdentifier("tracker.website")
                }
            }
        }
        if let photos = t.photos, !photos.isEmpty {
            Section(L.text("Tracker photos")) {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(photos.indices, id: \.self) { index in
                            Button { photoPreview = TrackerPhotoPreview(photos: photos, index: index) } label: {
                                if let image = UIImage(data: photos[index]) {
                                    Image(uiImage: image).resizable().scaledToFill().frame(width: 104, height: 104)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                            }.buttonStyle(.plain)
                                .accessibilityLabel(String(format: L.text("Photo %lld of %lld"), locale: L.locale, Int64(index + 1), Int64(photos.count)))
                                .accessibilityIdentifier("tracker.photo.\(index)")
                        }
                    }
                }.accessibilityIdentifier("tracker.photoGallery")
            }
        }
    }
    private func validatedWebsite(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false else { return nil }
        return url
    }
    private func numeric(_ t: Tracker, now: Date) -> some View {
        let snapshot = range.snapshot(for: t, now: now, customStart: customStart, customEnd: customEnd)
        let entries = t.resolvedEntries.filter { $0.occurredAt <= now }
        let values = entries.compactMap { $0.value.flatMap(Numbers.decimal) }
        let latest = entries.last?.value.flatMap(Numbers.decimal)
        return Section {
            VStack(alignment: .leading, spacing: 16) {
            Picker(L.text("Numeric view"), selection: $numericView) {
                Text(L.text("Chart")).tag("Chart")
                Text(L.text("Goal progress")).tag("Goal progress")
            }.pickerStyle(.segmented).accessibilityIdentifier("snapshot.view")
            if numericView == "Goal progress" {
                if let progress = GoalProgress.current(for: t, now: now) {
                    VStack(spacing: 12) {
                        GoalProgressRing(fraction: progress.fraction).frame(width: 144, height: 144)
                            .overlay {
                                Text(progress.fraction.formatted(.percent.precision(.fractionLength(0)).locale(L.locale)))
                                    .font(.title2.monospacedDigit())
                            }
                        Text(formatted(progress.baseline, tracker: t) + " → " + formatted(progress.target, tracker: t))
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).frame(minHeight: DetailStyle.chartHeight).accessibilityIdentifier("snapshot.progress")
                } else {
                    ContentUnavailableView {
                        Label(L.text(t.rule(at: now) == nil ? "No completion goal" : "No records yet"), systemImage: "chart.xyaxis.line")
                    } actions: {
                        if t.rule(at: now) == nil { Button(L.text("Set a goal")) { editing = true }.buttonStyle(.borderless).accessibilityIdentifier("detail.setGoal") }
                        else { Button(L.text("Add a snapshot")) { addEntry = true }.buttonStyle(.borderless).accessibilityIdentifier("detail.addRecord") }
                    }.frame(minHeight: DetailStyle.chartHeight)
                }
            } else {
            Picker(L.text("Period"), selection: $range) {
                ForEach(ChartRange.allCases, id: \.self) { period in Text(L.text(period.title)).tag(period) }
            }.pickerStyle(.segmented).accessibilityIdentifier("snapshot.period")
            if range == .custom {
                DatePicker(L.text("Start date"), selection: Binding(get: { customStart }, set: {
                    customStart = t.calendar.startOfDay(for: $0)
                    if customEnd < customStart { customEnd = customStart }
                }), in: ...customEnd, displayedComponents: .date)
                .accessibilityIdentifier("snapshot.custom.start")
                DatePicker(L.text("End date"), selection: Binding(get: { customEnd }, set: {
                    customEnd = t.calendar.startOfDay(for: $0)
                    if customStart > customEnd { customStart = customEnd }
                }), in: customStart..., displayedComponents: .date)
                .accessibilityIdentifier("snapshot.custom.end")
            }
            if let snapshot { snapshotChart(snapshot, tracker: t) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: typeSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: 16) {
                if let best = t.direction == .up ? values.max() : values.min() { metric("Best", formatted(best, tracker: t)) }
                if let change = snapshot?.periodChange { metric("Period change", DetailStyle.signedQuantity(change, unit: t.unit, precision: t.precision, locale: L.locale)) }
                if let rule = t.rule(at: now), let target = Numbers.decimal(rule.target) {
                    metric("Target", formatted(rule.target, tracker: t))
                    if let latest { metric("Distance to target", formatted(abs(target - latest), tracker: t)) }
                    if let deadline = rule.deadline { metric("Deadline", DetailStyle.date(deadline, calendar: t.calendar, now: now)) }
                }
            }.accessibilityIdentifier("detail.metrics")
            }.padding(.vertical, 8)
        }
    }
    private func formatted(_ value: String, tracker: Tracker, withUnit: Bool = true) -> String {
        DetailStyle.quantity(value, unit: withUnit && tracker.kind == .number ? tracker.unit : "", precision: tracker.kind == .daily ? 0 : tracker.precision, locale: L.locale)
    }
    private func formatted(_ value: Decimal, tracker: Tracker) -> String {
        DetailStyle.quantity(value, unit: tracker.kind == .number ? tracker.unit : "", precision: tracker.precision, locale: L.locale)
    }
    private func snapshotChart(_ snapshot: ChartSnapshot, tracker: Tracker) -> some View {
        let entries = snapshot.numericEntries
        let points = entries.compactMap { entry in entry.value.map { CardPlotPoint(date: entry.occurredAt, value: $0) } }
        let carried = snapshot.carries.flatMap { [$0.start, $0.end] }
        let target = tracker.rule(at: now).map { CardPlotPoint(date: snapshot.interval.start, value: $0.target) }
        let domain = CardPlotScale.domain(points: points + carried + [target].compactMap { $0 }, precision: tracker.precision,
                                          lower: tracker.axisLower, upper: tracker.axisUpper)
        let clipped = points.filter { CardPlotScale.excludes($0.value, lower: tracker.axisLower, upper: tracker.axisUpper) }.count
        let segments = CardPlotScale.clippedSegments(points, lower: tracker.axisLower, upper: tracker.axisUpper)
        let visibleCarries = snapshot.carries.filter { !CardPlotScale.excludes($0.start.value, lower: tracker.axisLower, upper: tracker.axisUpper) }
        return VStack(alignment: .leading, spacing: 8) {
        if entries.isEmpty && carried.isEmpty {
            ContentUnavailableView(L.text("No snapshots in this period"), systemImage: "chart.xyaxis.line")
                .frame(minHeight: DetailStyle.chartHeight).accessibilityIdentifier("snapshot.empty")
        } else {
        Chart {
        ForEach(entries) { entry in
            if let value = entry.value.flatMap(Numbers.plottedValue) {
                if let raw = entry.value, !CardPlotScale.excludes(raw, lower: tracker.axisLower, upper: tracker.axisUpper) {
                    PointMark(x: .value(L.text("Date"), entry.occurredAt), y: .value(L.text("Value"), value)).symbolSize(45).foregroundStyle(TrackerColors.accent)
                        .accessibilityLabel(Text(DetailStyle.date(entry.occurredAt, calendar: tracker.calendar, now: now)))
                        .accessibilityValue(Text(formatted(raw, tracker: tracker, withUnit: true)))
                }
            }
        }
        ForEach(segments) { segment in
            ForEach(Array([segment.start, segment.end].enumerated()), id: \.offset) { _, point in
                if let value = point.plottedValue {
                    LineMark(x: .value(L.text("Date"), point.date), y: .value(L.text("Value"), value), series: .value("Series", "actual-\(segment.id)")).foregroundStyle(TrackerColors.accent)
                }
            }
        }
        ForEach(visibleCarries) { segment in
            ForEach([segment.start, segment.end], id: \.date) { point in
                if let value = point.plottedValue {
                    LineMark(x: .value(L.text("Date"), point.date), y: .value(L.text("Value"), value), series: .value("Series", segment.id))
                        .lineStyle(DetailStyle.dashed).foregroundStyle(TrackerColors.accent)
                }
            }
        }
        }
        .frame(height: DetailStyle.chartHeight)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .chartXScale(domain: snapshot.interval.start...snapshot.interval.end, range: .plotDimension(padding: 20))
        .chartXAxis {
            AxisMarks(values: [snapshot.interval.start, snapshot.interval.start.addingTimeInterval(snapshot.interval.duration / 2), snapshot.interval.end.addingTimeInterval(-1)]) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(anchor: value.index == 0 ? .topLeading : value.index == 2 ? .topTrailing : .top, collisionResolution: .disabled) {
                    if let date = value.as(Date.self) { Text(DetailStyle.date(date, calendar: tracker.calendar, now: now)).fixedSize() }
                }
            }
        }
        .chartYScale(domain: domain)
        .chartPlotStyle { $0.clipped() }.chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { location in
                    guard let frame = proxy.plotFrame, geometry[frame].contains(location) else { return }
                    let point = CGPoint(x: location.x - geometry[frame].origin.x, y: location.y - geometry[frame].origin.y)
                    let hits = entries.compactMap { entry -> (Entry, Double)? in
                        guard let raw = entry.value, !CardPlotScale.excludes(raw, lower: tracker.axisLower, upper: tracker.axisUpper),
                              let value = Numbers.plottedValue(raw), domain.contains(value),
                              let x = proxy.position(forX: entry.occurredAt), let y = proxy.position(forY: value) else { return nil }
                        return (entry, hypot(point.x - x, point.y - y))
                    }
                    if let hit = hits.min(by: { $0.1 < $1.1 }), hit.1 <= 26 { selectedEntry = hit.0 }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L.text("Snapshot chart"))
        .accessibilityIdentifier("snapshot.chart")
        .accessibilityChildren {
            ForEach(entries) { entry in
                let date = DetailStyle.date(entry.occurredAt, calendar: tracker.calendar, now: now)
                let spoken = entry.value.flatMap { raw -> String? in
                    guard Numbers.decimal(raw) != nil else { return nil }
                    return formatted(raw, tracker: tracker, withUnit: true)
                }
                Button { selectedEntry = entry } label: { Text(date) }
                    .accessibilityLabel(date)
                    .accessibilityValue(spoken ?? "")
                    .accessibilityIdentifier("snapshot.point." + entry.id.uuidString)
            }
        }
        }
        if !carried.isEmpty, let date = snapshot.lastRecordedAt {
            (Text(L.text("Last recorded")) + Text(" ") + Text(DetailStyle.date(date, calendar: tracker.calendar, now: now)))
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("snapshot.lastRecorded")
        }
        if clipped > 0 {
            Text(String(format: L.text("%lld records outside the chart bounds. Values are preserved in the timeline."), locale: L.locale, Int64(clipped)))
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("snapshot.clipped")
        } else if carried.contains(where: { CardPlotScale.excludes($0.value, lower: tracker.axisLower, upper: tracker.axisUpper) }) {
            Text(L.text("Last recorded value is outside chart bounds."))
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("snapshot.clipped")
        }
        }
    }
    @ViewBuilder private func locations(_ tracker: Tracker) -> some View {
        let entries = tracker.sortedEntries.filter { $0.location?.isValid == true }
        if !entries.isEmpty {
            let points = entries.compactMap(\.location).map { MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
            let rect = points.dropFirst().reduce(MKMapRect(origin: points[0], size: MKMapSize(width: 1, height: 1))) {
                $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 1, height: 1)))
            }
            let minimum = MKMapPointsPerMeterAtLatitude(points[0].coordinate.latitude) * 800
            let width = max(rect.width * 1.4, minimum), height = max(rect.height * 1.4, minimum)
            let region = MKCoordinateRegion(MKMapRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height))
            Section(L.text("Recorded locations")) {
                Map(position: .constant(.region(region)), interactionModes: []) {
                    ForEach(entries) { entry in
                        if let location = entry.location {
                            Annotation("", coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)) {
                                Button { selectedEntry = entry } label: {
                                    Image(systemName: "mappin.circle.fill").font(.title).foregroundStyle(.white, TrackerColors.accent)
                                        .padding(6).background(.regularMaterial, in: Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(DetailStyle.date(entry.occurredAt, calendar: tracker.calendar, now: now)))
                                .accessibilityIdentifier("location." + entry.id.uuidString)
                            }
                        }
                    }
                }.frame(height: DetailStyle.chartHeight).accessibilityIdentifier("record.map")
            }
        }
    }
    private func metric(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L.text(key)).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(.primary)
        }.accessibilityElement(children: .combine)
    }
    private func daily(_ t: Tracker) -> some View {
        let cells = CompletionCalendarCell.month(for: t, containing: month, firstWeekday: firstWeekday)
        let completed = Set(t.entries.map(\.localDay))
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button { month = t.calendar.date(byAdding: .month, value: -1, to: month)! } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.buttonStyle(.borderless).accessibilityLabel(L.text("Previous month"))
                Spacer(); Text(month, format: .dateTime.year().month(.wide)); Spacer()
                Button { month = t.calendar.date(byAdding: .month, value: 1, to: month)! } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.buttonStyle(.borderless).accessibilityLabel(L.text("Next month"))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(cells) { cell in
                    switch cell {
                    case .weekday(let index):
                        Text(L.locale.calendar.veryShortStandaloneWeekdaySymbols[index - 1]).font(.caption)
                            .dynamicTypeSize(...DynamicTypeSize.accessibility1).foregroundStyle(.secondary).accessibilityIdentifier(cell.id)
                    case .padding:
                        Color.clear.frame(height: 32).accessibilityHidden(true)
                    case .day(let date, let localDay):
                        let done = completed.contains(localDay)
                        Button {
                            if let entry = t.entries.first(where: { $0.localDay == localDay }) { selectedEntry = entry }
                            else { selectedEntry = Entry(occurredAt: date, localDay: localDay) }
                        } label: {
                            Text("\(t.calendar.component(.day, from: date))").font(.body.monospacedDigit())
                                .dynamicTypeSize(...DynamicTypeSize.accessibility1).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity, minHeight: 44)
                                .background(done ? TrackerColors.accent : Color.clear, in: Circle())
                                .foregroundStyle(done ? Color.white : date > t.calendar.startOfDay(for: now) ? Color.secondary : Color.primary)
                                .overlay { if localDay == t.day(now) { Circle().strokeBorder(done ? .white : TrackerColors.accent, lineWidth: 2).padding(2) } }
                        }
                        .buttonStyle(.borderless)
                        .disabled(date > t.calendar.startOfDay(for: now))
                        .accessibilityLabel(date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: L.locale, calendar: t.calendar, timeZone: t.calendar.timeZone)) + ": " + L.text(done ? "Completed" : "No record"))
                        .accessibilityIdentifier(cell.id)
                    }
                }
            }

        }.accessibilityElement(children: .contain).accessibilityIdentifier("completion.calendar")
    }

}

private struct DetailRecordRow: View {
    let tracker: Tracker
    let entry: Entry
    let now: Date
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                let value = Group {
                    if let value = entry.value.flatMap(Numbers.decimal) {
                        Text(DetailStyle.quantity(value, unit: tracker.kind == .number ? tracker.unit : "", precision: tracker.precision, locale: L.locale)).monospacedDigit()
                    } else { Label(L.text("Completed"), systemImage: "checkmark.circle.fill") }
                }.font(.headline)
                let date = Text(DetailStyle.date(tracker.kind == .daily ? tracker.date(for: entry.localDay) ?? entry.occurredAt : entry.occurredAt, calendar: tracker.calendar, now: now))
                    .font(.subheadline).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) { value.fixedSize(); Spacer(minLength: 8); date.fixedSize() }
                    VStack(alignment: .leading, spacing: 4) { value; date }
                }
                HStack(spacing: 8) {
                    if !entry.note.isEmpty { Text(entry.note).lineLimit(1) }
                    if !entry.photos.isEmpty { Label(entry.photos.count.formatted(.number.locale(L.locale)), systemImage: "photo").monospacedDigit() }
                }.font(.subheadline).foregroundStyle(.secondary)
            }.foregroundStyle(.primary).padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain).alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .accessibilityIdentifier("entry." + entry.id.uuidString)
    }
}

enum DetailStyle {
    static let chartHeight: CGFloat = 240
    static let dashed = StrokeStyle(lineWidth: 2, dash: [5, 4])
    static func quantity(_ value: String, unit: String, precision: Int, locale: Locale) -> String {
        guard let decimal = Numbers.decimal(value) else { return joining(value, unit: unit) }
        return quantity(decimal, unit: unit, precision: precision, locale: locale)
    }
    static func quantity(_ value: Decimal, unit: String, precision: Int, locale: Locale) -> String {
        joining(Numbers.display(value, precision: precision, locale: locale), unit: unit)
    }
    static func signedQuantity(_ value: Decimal, unit: String, precision: Int, locale: Locale) -> String {
        (value < 0 ? "" : "+") + quantity(value, unit: unit, precision: precision, locale: locale)
    }
    private static func joining(_ shown: String, unit: String) -> String {
        unit.isEmpty ? shown : shown + " " + unit
    }
    static func date(_ date: Date, calendar: Calendar, now: Date = Date()) -> String {
        var format = Date.FormatStyle(date: .omitted, time: .omitted, locale: L.locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { format = format.year() }
        return date.formatted(format)
    }
}

private struct TrackerPhotoPreview: Identifiable {
    let id = UUID()
    let photos: [Data]
    let index: Int
}
