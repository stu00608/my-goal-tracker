import SwiftUI
import PhotosUI
import ImageIO
import UserNotifications
import MapKit

struct TrackerEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var existing: Tracker?
    @State private var newTracker = Tracker(name: "", kind: .number)
    @State private var name = ""
    @State private var kind = TrackerKind.number
    @State private var unit = ""
    @State private var description = ""
    @State private var website = ""
    @State private var precision = 3
    @State private var direction = Direction.up
    @State private var goalEnabled = false
    @State private var target = ""
    @State private var due = Date().addingTimeInterval(86400 * 30)
    @State private var period = Period.weekly
    @State private var frequency = 2
    @State private var axisLower = ""
    @State private var axisUpper = ""
    @State private var cardBackground = CardBackground.plot
    @State private var photos: [DraftPhoto] = []
    @State private var selections: [PhotosPickerItem] = []
    @State private var photoPresentation: TrackerPhotoPresentation?
    @State private var photoRemoval: DraftPhoto?
    @State private var photoTask: Task<Void, Never>?
    @State private var loadingPhotos = false
    @State private var reminder: Reminder?
    @State private var groups: [ConditionGroup] = []
    @State private var editingCondition: ConditionEditorSelection?
    @State private var deletingGroup: ConditionGroup?
    @State private var combination = ConditionCombination.any
    @State private var gateSave = false
    @State private var remindWhenMet = false
    @State private var textPosition = CardTextPosition.bottomTrailing
    @State private var showLastRecorded = true
    @State private var ringStyle = RingProgressStyle.percent
    @State private var lifecycle = TrackingLifecycle.finite
    @State private var notificationAuthorized = true
    @State private var runtime = ConditionReminders.shared
    @State private var error: String?
    @State private var busy = false
    private enum Field: Hashable { case name, unit, target, description, website, axisLower, axisUpper }
    @FocusState private var focusedField: Field?
    @State private var deleteTracker = false
    @State private var initialized = false
    @State private var keyboard = EditorKeyboardControl()

    private var healthKeys: Set<HealthFactKey> { Set(groups.flatMap(\.conditions).compactMap(\.healthKey)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L.text("Name"), text: $name).focused($focusedField, equals: .name)
                        .submitLabel(.done).onSubmit(endEditing).accessibilityIdentifier("tracker.name")
                    if typeLocked {
                        LabeledContent(L.text("Record type")) { Text(L.text(kind == .number ? "Number snapshot" : "Completion record")).foregroundStyle(.primary) }
                            .accessibilityIdentifier("tracker.kind")
                    } else {
                        Picker(L.text("Record type"), selection: $kind) {
                            Text(L.text("Number snapshot")).tag(TrackerKind.number)
                            Text(L.text("Completion record")).tag(TrackerKind.daily)
                        }.tint(.primary).accessibilityIdentifier("tracker.kind")
                    }
                }
                numberSection
                goalSection
                Section {
                    NavigationLink { editorPage("Appearance") { appearanceSections } } label: {
                        LabeledContent(L.text("Appearance")) { Text(backgroundSummary).foregroundStyle(.primary) }
                    }.accessibilityIdentifier("tracker.appearance")
                    NavigationLink { editorPage("Achievement conditions") {
                        AchievementConditionEditor(groups: $groups, outerCombination: $combination, gateSave: $gateSave, editing: $editingCondition, deleting: $deletingGroup)
                        if !healthKeys.isEmpty { Section { HealthConnectionView(keys: healthKeys, onFailure: { error = $0 }) } }
                    }
                    .confirmationDialog(L.text("Delete this group and its conditions?"), isPresented: Binding(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } }), titleVisibility: .visible) {
                        Button(L.text("Delete group"), role: .destructive) {
                            if let group = deletingGroup, groups.count > 1 { groups.removeAll { $0.id == group.id } }
                            if groups.allSatisfy({ $0.conditions.isEmpty }) { gateSave = false }
                            deletingGroup = nil
                        }.accessibilityIdentifier("conditions.editor.confirmDelete")
                        Button(L.text("Cancel"), role: .cancel) { deletingGroup = nil }
                            .accessibilityIdentifier("conditions.editor.cancelDelete")
                    }
                    } label: {
                        LabeledContent(L.text("Achievement conditions")) { Text(conditionSummary).monospacedDigit().foregroundStyle(.primary) }
                    }.accessibilityIdentifier("tracker.conditions")
                    NavigationLink { editorPage("Reminders") { notificationsSection } } label: {
                        LabeledContent(L.text("Reminders")) { Text(reminderSummary).monospacedDigit().foregroundStyle(.primary) }
                    }.accessibilityIdentifier("tracker.reminders")
                    NavigationLink { editorPage("Description and photos") { metadataSection; photoSection } } label: {
                        LabeledContent(L.text("Description and photos")) { Text(contentSummary).monospacedDigit().foregroundStyle(.primary) }
                    }.accessibilityIdentifier("tracker.content")
                    if kind == .number {
                        NavigationLink { editorPage("Chart range") { axisSection } } label: {
                            LabeledContent(L.text("Chart range")) { Text(axisSummary).monospacedDigit().foregroundStyle(.primary) }
                        }.accessibilityIdentifier("tracker.chartRange")
                    }
                }
                if let existing {
                    Section {
                        Button(L.text(existing.archived ? "Unarchive" : "Archive tracker"), action: archive).accessibilityIdentifier("tracker.archive")
                        Button(L.text("Delete tracker"), role: .destructive) { endEditing(); deleteTracker = true }.accessibilityIdentifier("tracker.delete")
                    }
                }
            }
            .disabled(busy)
            .statusToast(message: $error, identifier: "editor.error", autoDismiss: false)
            .scrollDismissesKeyboard(.interactively)
            .background(EditorKeyboardDismissal(keyboard: keyboard) { focusedField = nil })
            .navigationTitle(L.text(existing == nil ? "New tracker" : "Edit tracker"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { editorToolbar }
            .onAppear(perform: initialize)
            .task {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                notificationAuthorized = settings.authorizationStatus != .denied
            }
            .onChange(of: kind) { _, kind in endEditing(); if existing == nil { lifecycle = kind == .daily ? .ongoing : .finite }; resetInvalidBackground() }
            .onChange(of: goalEnabled) { _, _ in resetInvalidBackground() }
            .onChange(of: target) { _, _ in resetInvalidBackground() }
            .onChange(of: period) { _, _ in endEditing(); frequency = min(frequency, period == .weekly ? 7 : 31) }
            .onChange(of: groups) { _, _ in if !supportsConditionReminders { remindWhenMet = false } }
            .onChange(of: selections) { _, items in importPhotos(items) }
            .fullScreenCover(item: $photoPresentation) { selection in
                PhotoViewer(photos: selection.photos, initialIndex: selection.initialIndex)
            }
            .sheet(item: $photoRemoval) { removalSheet($0) }
            .confirmationDialog(L.text("Delete this tracker and all its records?"), isPresented: $deleteTracker, titleVisibility: .visible) {
                Button(L.text("Delete tracker"), role: .destructive) {
                    guard let existing else { return }
                    do { try store.remove(existing.id); dismiss() }
                    catch { self.error = L.error(error) }
                }.accessibilityIdentifier("tracker.delete.confirm")
            }
            .sheet(item: $editingCondition) { selection in
                AchievementLeafEditor(existing: selection.condition, kind: selection.kind) { payload in
                    if groups.isEmpty { groups.append(ConditionGroup(id: selection.groupID)) }
                    guard let group = groups.firstIndex(where: { $0.id == selection.groupID }) else { return }
                    if let old = selection.condition,
                       let leaf = groups[group].conditions.firstIndex(where: { $0.id == old.id }) {
                        groups[group].conditions[leaf].payload = payload
                    } else if groups[group].conditions.count < ConditionGroup.limit {
                        groups[group].conditions.append(AchievementCondition(payload: payload))
                    }
                }
            }

        }.onDisappear { photoTask?.cancel() }
    }

    private var metadataSection: some View {
        Section {
            TextField(L.text("Description (optional)"), text: $description, axis: .vertical)
                .lineLimit(3...8).focused($focusedField, equals: .description)
                .accessibilityIdentifier("tracker.description")
            TextField(L.text("Website (optional)"), text: $website)
                .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focusedField, equals: .website).accessibilityIdentifier("tracker.website")
        }
    }
    @ViewBuilder private var numberSection: some View {
        if kind == .number {
            Section {
                if typeLocked {
                    LabeledContent(L.text("Unit (optional)")) { Text(unit.isEmpty ? L.text("None") : unit).foregroundStyle(.primary) }
                        .accessibilityIdentifier("tracker.unit")
                } else {
                    TextField(L.text("Unit (optional)"), text: $unit).focused($focusedField, equals: .unit).accessibilityIdentifier("tracker.unit")
                }
                Stepper(value: $precision, in: 0...8) {
                    LabeledContent(L.text("Decimal places")) { Text(precision, format: .number).monospacedDigit().foregroundStyle(.primary) }
                }.accessibilityIdentifier("tracker.precision")
                Picker(L.text("Improvement direction"), selection: $direction) {
                    Text(L.text("Higher is better")).tag(Direction.up); Text(L.text("Lower is better")).tag(Direction.down)
                }.tint(.primary)
            }
        }
    }
    @ToolbarContentBuilder private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(L.text("Cancel")) { endEditing(); photoTask?.cancel(); dismiss() }.disabled(busy).accessibilityIdentifier("tracker.cancel")
        }
        ToolbarItem(placement: .confirmationAction) {
            saveButton
        }
        ToolbarItemGroup(placement: .keyboard) {
            Spacer(); Button(L.text("Done"), action: endEditing).accessibilityIdentifier("tracker.keyboard.done")
        }
    }
    private var saveButton: some View {
        Button(L.text("Save"), action: save)
            .disabled(busy || loadingPhotos || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 120 || unit.count > 30)
            .accessibilityIdentifier("tracker.save")
    }
    private func editorPage<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Form(content: content).disabled(busy)
            .statusToast(message: $error, identifier: "editor.error", autoDismiss: false)
            .scrollDismissesKeyboard(.interactively)
            .background(EditorKeyboardDismissal(keyboard: keyboard) { focusedField = nil })
            .navigationTitle(L.text(title)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { saveButton }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer(); Button(L.text("Done"), action: endEditing).accessibilityIdentifier("tracker.keyboard.done")
                }
            }
    }
    @ViewBuilder private var appearanceSections: some View {
        Section {
            let now = Date()
            let row = WidgetRow(previewTracker(now: now), now: now)
            TrackerCardSurface(row: row, now: now, locale: L.locale, text: L.text, minimumHeight: 240, fillsHeight: false) {
                if row.resolvedBackground == .map, let locations = row.locations, !locations.isEmpty {
                    Map(position: .constant(.rect(CardMapFraming.rect(locations: locations, textPosition: row.resolvedTextPosition) ?? .world)), interactionModes: []) {
                        ForEach(Array(locations.enumerated()), id: \.offset) { _, location in
                            Marker(name, coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude))
                                .annotationTitles(.hidden).tint(TrackerColors.accent)
                        }
                    }.mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                } else { TrackerCardBackdrop(row: row, text: L.text, now: now, locale: L.locale) }
            }.accessibilityIdentifier("tracker.preview")
        }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
        Section {
            Picker(L.text("Card background"), selection: $cardBackground) {
                Text(L.text("Chart")).tag(CardBackground.plot)
                Text(L.text("Latest photo")).tag(CardBackground.photo)
                Text(L.text("Tracker photo")).tag(CardBackground.trackerPhoto)
                Text(L.text("Location map")).tag(CardBackground.map)
                if progressEligible { Text(L.text("Goal progress")).tag(CardBackground.progress) }
            }.tint(.primary).accessibilityIdentifier("tracker.cardBackground")
            CardPresentationEditor(textPosition: $textPosition, showLastRecorded: $showLastRecorded,
                                   ringStyle: $ringStyle, background: cardBackground)
        }
    }
    private func previewTracker(now: Date) -> Tracker {
        var t = existing ?? newTracker
        t.name = name.isEmpty ? L.text("Name") : name; t.kind = kind; t.unit = unit; t.precision = precision
        t.photos = photos.map(\.data); t.cardBackground = cardBackground
        t.cardTextPosition = textPosition; t.showLastRecorded = showLastRecorded; t.ringStyle = ringStyle
        try? applyGoal(to: &t, now: now)
        return t
    }
    private var backgroundSummary: String {
        L.text(cardBackground == .plot ? "Chart" : cardBackground == .photo ? "Latest photo" : cardBackground == .trackerPhoto ? "Tracker photo" : cardBackground == .map ? "Location map" : "Goal progress")
    }
    private var conditionSummary: String {
        let count = groups.flatMap(\.conditions).count
        return count == 0 ? L.text("None") : count == 1 ? L.text("1 condition") : String(format: L.text("%lld conditions"), locale: L.locale, count)
    }
    private var reminderSummary: String {
        guard let reminder else { return L.text(remindWhenMet ? "When conditions are met" : "Off") }
        let time = Calendar.current.date(bySettingHour: reminder.hour, minute: reminder.minute, second: 0, of: Date()) ?? Date()
        let days = reminder.weekdays.count == 7 ? L.text("Every day") : WeekdayOrder.days(starting: L.firstWeekday)
            .filter { reminder.weekdays.contains($0) }.map { L.locale.calendar.shortStandaloneWeekdaySymbols[$0 - 1] }.joined(separator: " ")
        return days + " " + time.formatted(.dateTime.hour().minute().locale(L.locale))
    }
    private var contentSummary: String {
        if photos.count == 1 { return L.text("1 photo") }
        if !photos.isEmpty { return String(format: L.text("%lld photos"), locale: L.locale, photos.count) }
        return L.text(description.isEmpty && website.isEmpty ? "None" : "Configured")
    }
    private var axisSummary: String {
        axisLower.isEmpty && axisUpper.isEmpty ? L.text("Automatic") : (axisLower.isEmpty ? L.text("Automatic") : axisLower) + " – " + (axisUpper.isEmpty ? L.text("Automatic") : axisUpper)
    }
    private func archive() {
        guard let existing, var current = store.trackers.first(where: { $0.id == existing.id }) else { return }
        endEditing(); current.archived.toggle()
        do { try store.save(current); dismiss() }
        catch { self.error = L.error(error) }
    }
    private var goalSection: some View {
        Section {
            if existing?.rules.isEmpty ?? true { Toggle(L.text("Set a goal"), isOn: $goalEnabled).accessibilityIdentifier("goal.enabled") }
            if goalEnabled {
                if kind == .number {
                    LabeledContent(L.text("Target value")) {
                        TextField(L.text("Target value"), text: $target).focused($focusedField, equals: .target)
                            .multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation).monospacedDigit().accessibilityIdentifier("goal.target")
                    }
                    DatePicker(L.text("Deadline"), selection: $due,
                               in: min(existing?.rules.last?.deadline ?? Date(), Date())..., displayedComponents: [.date])
                } else {
                    Picker(L.text("Frequency"), selection: $period) {
                        Text(L.text("Weekly")).tag(Period.weekly); Text(L.text("Monthly")).tag(Period.monthly)
                    }.tint(.primary)
                    Stepper(value: $frequency, in: 1...(period == .weekly ? 7 : 31)) {
                        LabeledContent(L.text("Completions")) { Text(frequency, format: .number).monospacedDigit().foregroundStyle(.primary) }
                    }.accessibilityIdentifier("goal.frequency")
                }
            }
            Picker(L.text("Tracking style"), selection: $lifecycle) {
                Text(L.text("Ongoing")).tag(TrackingLifecycle.ongoing)
                Text(L.text("Finite goal")).tag(TrackingLifecycle.finite)
            }.tint(.primary).accessibilityIdentifier("tracker.lifecycle")
        } footer: {
            if kind == .daily && !(existing?.rules.isEmpty ?? true) {
                Text(L.text("Changes start with the next full period. Past goals stay unchanged."))
            }
        }
    }
    private var axisSection: some View {
        Section {
            LabeledContent(L.text("Minimum")) {
                TextField(L.text("Automatic"), text: $axisLower)
                    .multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation).monospacedDigit()
                    .focused($focusedField, equals: .axisLower).accessibilityLabel(L.text("Minimum")).accessibilityIdentifier("tracker.axisLower")
            }
            LabeledContent(L.text("Maximum")) {
                TextField(L.text("Automatic"), text: $axisUpper)
                    .multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation).monospacedDigit()
                    .focused($focusedField, equals: .axisUpper).accessibilityLabel(L.text("Maximum")).accessibilityIdentifier("tracker.axisUpper")
            }
        }
    }
    private var supportsConditionReminders: Bool {
        let leaves = groups.flatMap(\.conditions)
        return leaves.contains { $0.place != nil } && !leaves.contains { $0.isHealth }
    }
    @ViewBuilder private var notificationsSection: some View {
        Section {
            NavigationLink {
                ReminderScheduleEditor(reminder: $reminder)
            } label: {
                LabeledContent(L.text("Time and weekdays")) { Text(reminderSummary).monospacedDigit().foregroundStyle(.primary) }
            }.accessibilityIdentifier("tracker.reminders.schedule")
        }
        Section {
            Toggle(L.text("Remind me when conditions are met"), isOn: $remindWhenMet)
                .disabled(!supportsConditionReminders).accessibilityIdentifier("tracker.conditions.remind")
            if Reminders.enabled && ((remindWhenMet && runtime.authorization != .authorizedAlways) || !notificationAuthorized) {
                Link(L.text("Open iPhone Settings"), destination: URL(string: UIApplication.openSettingsURLString)!)
                    .accessibilityIdentifier("tracker.reminders.settings")
            }
        } footer: {
            if !supportsConditionReminders {
                Text(L.text("Condition reminders require a location condition and cannot include health conditions. Time and weekday conditions are checked when a location event occurs."))
            } else if remindWhenMet, let key = runtime.availabilityKey {
                Text(L.text(key)).accessibilityIdentifier("tracker.conditions.availability")
            } else {
                Text(L.text("Condition reminders use location events and need Always location access. They never create records automatically."))
            }
            if !Reminders.enabled {
                Text(L.text("All reminders are off in Settings. Your tracker choices are kept."))
            } else if !notificationAuthorized {
                Text(L.text("Notifications are disabled. You can enable them in iPhone Settings."))
            }
        }
    }
    private var photoSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) { photoHeading; addPhotos }
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        photoHeading
                        Spacer(minLength: 4)
                        addPhotos
                    }
                }
                if !photos.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) { ForEach(photos) { photoTile($0) } }
                    }.scrollIndicators(.hidden).accessibilityIdentifier("tracker.photoRail")
                }
                if loadingPhotos { ProgressView(L.text("Saving photo copies")) }
            }
        }
    }
    private var photoHeading: some View {
        HStack(spacing: 8) {
            Text(L.text("Photos")).font(.subheadline.weight(.semibold))
            if !photos.isEmpty {
                Text("\(photos.count)/\(Entry.photoLimit)").font(.subheadline.monospacedDigit()).foregroundStyle(.primary)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel(L.text("Photos")).accessibilityValue("\(photos.count)/\(Entry.photoLimit)")
                    .accessibilityIdentifier("tracker.photos.count")
            }
        }
    }
    private var addPhotos: some View {
        PhotosPicker(selection: $selections, maxSelectionCount: max(1, Entry.photoLimit - photos.count),
                     selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current) {
            Label(L.text("Add photos"), systemImage: "plus")
                .frame(minHeight: 44)
        }.labelStyle(.titleAndIcon).buttonStyle(.borderless).disabled(loadingPhotos || photos.count == Entry.photoLimit)
            .simultaneousGesture(TapGesture().onEnded { endEditing() }).accessibilityIdentifier("tracker.photos")
    }
    private func photoTile(_ photo: DraftPhoto) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                guard let index = photos.firstIndex(where: { $0.id == photo.id }) else { return }
                endEditing(); photoPresentation = TrackerPhotoPresentation(photos: photos.map(\.data), initialIndex: index)
            } label: {
                if let image = UIImage(data: photo.data) {
                    Image(uiImage: image).renderingMode(.original).resizable().scaledToFill()
                        .frame(width: 104, height: 104).clipped().clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }.frame(width: 104, height: 104).buttonStyle(.plain)
                .accessibilityLabel(photoLabel("Tracker photo %lld", photo))
                .accessibilityIdentifier("tracker.photo.\(photo.id.uuidString)")
            Button { endEditing(); photoRemoval = photo } label: {
                Image(systemName: "xmark.circle.fill").font(.title2).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(loadingPhotos)
                .accessibilityLabel(photoLabel("Remove photo %lld", photo))
                .accessibilityIdentifier("tracker.photo.remove.\(photo.id.uuidString)")
        }.frame(width: 104, height: 104)
    }
    private func photoLabel(_ key: String, _ photo: DraftPhoto) -> String {
        String(format: L.text(key), locale: L.locale, (photos.firstIndex { $0.id == photo.id } ?? 0) + 1)
    }
    private func removalSheet(_ photo: DraftPhoto) -> some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let image = UIImage(data: photo.data) {
                    Image(uiImage: image).resizable().scaledToFit().accessibilityLabel(L.text("Photo to remove"))
                        .accessibilityIdentifier("tracker.photoRemoval.preview")
                }
                Text(L.text("This photo is removed only when you save the tracker.")).font(.subheadline).foregroundStyle(.secondary)
            }.padding()
                .navigationTitle(L.text("Photos")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L.text("Cancel")) { photoRemoval = nil }.accessibilityIdentifier("tracker.photoRemoval.cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L.text("Remove photo"), role: .destructive) {
                            photos.removeAll { $0.id == photo.id }; photoRemoval = nil
                        }.accessibilityIdentifier("tracker.photoRemoval.confirm")
                    }
                }
        }.presentationDetents([.medium, .large])
    }
    private var typeLocked: Bool { !(existing?.entries.isEmpty ?? true) || !(existing?.rules.isEmpty ?? true) || existing?.manualCompletion != nil }
    private var progressEligible: Bool {
        guard goalEnabled else { return false }
        let now = Date()
        var draft = existing ?? newTracker
        draft.kind = kind
        guard (try? applyGoal(to: &draft, now: now)) != nil else { return false }
        return GoalProgress.available(for: draft, now: now)
    }
    private func resetInvalidBackground() {
        if cardBackground == .progress && !progressEligible { cardBackground = .plot }
    }
    private func endEditing() { keyboard.dismiss(); focusedField = nil }
    private func initialize() {
        guard !initialized else { return }; initialized = true
        guard let t = existing else { DispatchQueue.main.async { focusedField = .name }; return }
        name = t.name; kind = t.kind; unit = t.unit; precision = t.precision; direction = t.direction
        description = t.description ?? ""; website = t.website ?? ""
        photos = (t.photos ?? []).map { DraftPhoto(data: $0) }
        axisLower = t.axisLower ?? ""; axisUpper = t.axisUpper ?? ""
        reminder = t.reminder; groups = t.resolvedConditionGroups; combination = t.resolvedOuterCombination
        textPosition = t.resolvedTextPosition; showLastRecorded = t.showLastRecorded ?? true; ringStyle = t.resolvedRingStyle; lifecycle = t.resolvedLifecycle
        gateSave = t.gateSave == true; remindWhenMet = t.remindWhenMet == true
        if let rule = t.rules.max(by: { $0.effectiveAt < $1.effectiveAt }) {
            goalEnabled = true; target = rule.target; due = rule.deadline ?? due; period = rule.period; frequency = Int(rule.target) ?? 2
        }
        cardBackground = t.resolvedCardBackground; resetInvalidBackground()
    }
    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photoTask?.cancel(); loadingPhotos = true
        photoTask = Task {
            defer { loadingPhotos = false; selections = [] }
            do {
                var copies: [DraftPhoto] = []
                for item in items {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw DataError.photoFailed }
                    try Task.checkCancellation()
                    copies.append(DraftPhoto(data: try photoCopy(data)))
                }
                guard photos.count + copies.count <= Entry.photoLimit else { throw DataError.tooManyPhotos }
                try Task.checkCancellation()
                photos.append(contentsOf: copies); error = nil
            } catch is CancellationError { }
            catch { self.error = L.error(error) }
        }
    }
    private func preparedTracker() throws -> Tracker {
        let id = existing?.id ?? newTracker.id
        var t = store.trackers.first { $0.id == id } ?? existing ?? newTracker
        guard description.count <= 10000 else { throw ConditionError("The description can contain up to 10,000 characters.") }
        let configuredGroups = groups.count == 1 && groups[0].conditions.isEmpty ? [] : groups
        guard configuredGroups.allSatisfy({ !$0.conditions.isEmpty }) else { throw ConditionError("Add at least one condition to every group.") }
        guard !(gateSave || remindWhenMet) || !configuredGroups.isEmpty else { throw ConditionError("Add an achievement condition first.") }
        guard !remindWhenMet || supportsConditionReminders else { throw ConditionError("Condition reminders require a location condition without health conditions.") }
        if reminder?.weekdays.isEmpty == true { throw ConditionError("Choose at least one weekday.") }
        t.name = name.trimmingCharacters(in: .whitespacesAndNewlines); t.kind = kind; t.unit = unit; t.precision = precision; t.direction = direction
        t.description = description.isEmpty ? nil : description; t.website = try TrackerFields.website(website)
        t.photos = photos.isEmpty ? nil : photos.map(\.data)
        if kind == .number { (t.axisLower, t.axisUpper) = try TrackerFields.axis(lower: axisLower, upper: axisUpper, locale: L.locale) }
        else { t.axisLower = nil; t.axisUpper = nil }
        t.conditions = nil; t.conditionCombination = nil
        t.conditionGroups = configuredGroups.isEmpty ? nil : configuredGroups; t.outerCombination = configuredGroups.isEmpty ? nil : combination
        t.cardTextPosition = textPosition; t.showLastRecorded = showLastRecorded; t.ringStyle = ringStyle; t.lifecycle = lifecycle
        t.gateSave = gateSave; t.remindWhenMet = remindWhenMet; t.reminder = reminder
        try applyGoal(to: &t, now: Date())
        t.cardBackground = cardBackground == .progress && !GoalProgress.available(for: t, now: Date()) ? .plot : cardBackground
        return t
    }
    private func applyGoal(to t: inout Tracker, now: Date) throws {
        if goalEnabled {
            if kind == .number {
                let value = try Numbers.parse(target, locale: L.locale)
                guard let nextDay = t.calendar.date(byAdding: .day, value: 1, to: t.calendar.startOfDay(for: due)) else { throw DataError.invalidBackup }
                let end = nextDay.addingTimeInterval(-0.001)
                let prior = t.rules.max { $0.effectiveAt < $1.effectiveAt }
                if prior?.target != value || prior?.deadline != end || prior?.direction != direction {
                    guard end >= now else { throw ConditionError("Choose a deadline today or later when changing a goal.") }
                    t.rules.append(GoalRule(period: .deadline, target: value, effectiveAt: now, deadline: end, direction: direction))
                }
            } else if t.rules.max(by: { $0.effectiveAt < $1.effectiveAt })?.target != String(frequency) || t.rules.max(by: { $0.effectiveAt < $1.effectiveAt })?.period != period {
                t.setFrequency(period, target: frequency, now: now)
            }
        }
    }
    private func save() {
        endEditing()
        do {
            let tracker = try preparedTracker()
            var candidate = store.trackers.filter { $0.id != tracker.id }; candidate.append(tracker)
            try Reminders.validate(candidate)
            busy = true; error = nil
            Task {
                defer { busy = false }
                do {
                    if Reminders.enabled && (reminder != nil || remindWhenMet) {
                        notificationAuthorized = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                        if remindWhenMet { runtime.requestAuthorization() }
                    }
                    // Re-read live records after any permission UI suspension; metadata never overwrites raw records.
                    try store.save(preparedTracker())
                    do { try await Reminders.sync(store.trackers) }
                    catch {
                        self.error = L.text("Your tracker was saved, but reminders could not be updated. Open the app to try again.")
                        return
                    }
                    dismiss()
                } catch { self.error = (error as? ConditionError).map { L.text($0.key) } ?? L.error(error) }
            }
        } catch { self.error = (error as? ConditionError).map { L.text($0.key) } ?? L.error(error) }
    }
}

private struct TrackerPhotoPresentation: Identifiable {
    let id = UUID()
    let photos: [Data]
    let initialIndex: Int
}
