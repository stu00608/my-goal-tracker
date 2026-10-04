import SwiftUI
import PhotosUI
import ImageIO
import UserNotifications

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
    @State private var conditions: [PlaceCondition] = []
    @State private var combination = ConditionCombination.any
    @State private var gateSave = false
    @State private var remindWhenMet = false
    @State private var conditionPresentation: TrackerConditionPresentation?
    @State private var conditionRemoval: PlaceCondition?
    @State private var notificationAuthorized = true
    @State private var runtime = ConditionReminders.shared
    @State private var error: String?
    @State private var busy = false
    private enum Field: Hashable { case name, unit, target, description, website, axisLower, axisUpper }
    @FocusState private var focusedField: Field?
    @State private var initialized = false
    @State private var keyboard = EditorKeyboardControl()

    var body: some View {
        NavigationStack {
            Form {
                metadataSection
                photoSection
                typeSection
                goalSection
                if kind == .number { axisSection }
                Section(L.text("Card background")) {
                    Picker(L.text("Card background"), selection: $cardBackground) {
                        Text(L.text("Chart")).tag(CardBackground.plot)
                        Text(L.text("Latest photo")).tag(CardBackground.photo)
                        Text(L.text("Tracker photo")).tag(CardBackground.trackerPhoto)
                        Text(L.text("Location map")).tag(CardBackground.map)
                        if progressEligible { Text(L.text("Goal progress")).tag(CardBackground.progress) }
                    }.accessibilityIdentifier("tracker.cardBackground")
                }
                conditionsSection
                notificationsSection
                if let error {
                    Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("editor.error") }
                }
            }
            .disabled(busy)
            .scrollDismissesKeyboard(.interactively)
            .background(EditorKeyboardDismissal(keyboard: keyboard) { focusedField = nil })
            .navigationTitle(L.text(existing == nil ? "New tracker" : "Edit tracker"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.text("Cancel")) { endEditing(); photoTask?.cancel(); dismiss() }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.text("Save"), action: save)
                        .disabled(busy || loadingPhotos || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 120 || unit.count > 30)
                        .accessibilityIdentifier("tracker.save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer(); Button(L.text("Done"), action: endEditing).accessibilityIdentifier("tracker.keyboard.done")
                }
            }
            .onAppear(perform: initialize)
            .task {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                notificationAuthorized = settings.authorizationStatus != .denied
            }
            .onChange(of: kind) { _, _ in endEditing(); resetInvalidBackground() }
            .onChange(of: goalEnabled) { _, _ in resetInvalidBackground() }
            .onChange(of: target) { _, _ in resetInvalidBackground() }
            .onChange(of: period) { _, _ in endEditing(); frequency = min(frequency, period == .weekly ? 7 : 31) }
            .onChange(of: selections) { _, items in importPhotos(items) }
            .onDisappear { photoTask?.cancel() }
            .fullScreenCover(item: $photoPresentation) { selection in
                PhotoViewer(photos: selection.photos, initialIndex: selection.initialIndex)
            }
            .sheet(item: $photoRemoval) { removalSheet($0) }
            .sheet(item: $conditionPresentation) { presentation in
                ConditionEditor(existing: presentation.condition) { condition in
                    if let index = conditions.firstIndex(where: { $0.id == condition.id }) { conditions[index] = condition }
                    else { conditions.append(condition) }
                }
            }
            .confirmationDialog(L.text("Remove this location condition?"), isPresented: Binding(
                get: { conditionRemoval != nil }, set: { if !$0 { conditionRemoval = nil } }
            ), titleVisibility: .visible) {
                Button(L.text("Remove condition"), role: .destructive) {
                    guard let conditionRemoval else { return }
                    conditions.removeAll { $0.id == conditionRemoval.id }
                    if conditions.isEmpty { gateSave = false; remindWhenMet = false }
                    self.conditionRemoval = nil
                }
                Button(L.text("Cancel"), role: .cancel) { conditionRemoval = nil }
            } message: { Text(conditionRemoval?.name ?? "") }
        }
    }

    private var metadataSection: some View {
        Section(L.text("Tracker")) {
            TextField(L.text("Name"), text: $name).focused($focusedField, equals: .name).accessibilityIdentifier("tracker.name")
            TextField(L.text("Description (optional)"), text: $description, axis: .vertical)
                .lineLimit(3...8).focused($focusedField, equals: .description)
                .accessibilityIdentifier("tracker.description")
            TextField(L.text("Website (optional)"), text: $website)
                .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focusedField, equals: .website).accessibilityIdentifier("tracker.website")
        }
    }
    private var typeSection: some View {
        Section(L.text("Record type")) {
            Picker(L.text("Record type"), selection: $kind) {
                Text(L.text("Number snapshot")).tag(TrackerKind.number)
                Text(L.text("Completion record")).tag(TrackerKind.daily)
            }.accessibilityIdentifier("tracker.kind").disabled(typeLocked)
            if typeLocked { Text(L.text("Create a new tracker to change its type or unit.")).font(.caption).foregroundStyle(.secondary) }
            if kind == .number {
                TextField(L.text("Unit (optional)"), text: $unit).focused($focusedField, equals: .unit).disabled(typeLocked).accessibilityIdentifier("tracker.unit")
                Stepper(L.text("Decimal places") + ": \(precision)", value: $precision, in: 0...8)
                Picker(L.text("Improvement direction"), selection: $direction) {
                    Text(L.text("Higher is better")).tag(Direction.up); Text(L.text("Lower is better")).tag(Direction.down)
                }
            }
        }
    }
    private var goalSection: some View {
        Section(L.text("Goal")) {
            if existing?.rules.isEmpty ?? true { Toggle(L.text("Set a goal"), isOn: $goalEnabled).accessibilityIdentifier("goal.enabled") }
            if goalEnabled {
                if kind == .number {
                    TextField(L.text("Target value"), text: $target).focused($focusedField, equals: .target)
                        .keyboardType(.numbersAndPunctuation).accessibilityIdentifier("goal.target")
                    DatePicker(L.text("Deadline"), selection: $due,
                               in: min(existing?.rules.last?.deadline ?? Date(), Date())..., displayedComponents: [.date])
                } else {
                    Picker(L.text("Frequency"), selection: $period) {
                        Text(L.text("Weekly")).tag(Period.weekly); Text(L.text("Monthly")).tag(Period.monthly)
                    }
                    Stepper(L.text("Completions") + ": \(frequency)", value: $frequency, in: 1...(period == .weekly ? 7 : 31))
                        .accessibilityIdentifier("goal.frequency")
                    if !(existing?.rules.isEmpty ?? true) {
                        Text(L.text("Changes start with the next full period. Past goals stay unchanged.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private var axisSection: some View {
        Section {
            TextField(L.text("Minimum (automatic if empty)"), text: $axisLower)
                .keyboardType(.numbersAndPunctuation).focused($focusedField, equals: .axisLower)
                .accessibilityIdentifier("tracker.axisLower")
            TextField(L.text("Maximum (automatic if empty)"), text: $axisUpper)
                .keyboardType(.numbersAndPunctuation).focused($focusedField, equals: .axisUpper)
                .accessibilityIdentifier("tracker.axisUpper")
        } header: { Text(L.text("Chart range")) } footer: {
            Text(L.text("Chart bounds change the view only. Original values and precision are kept."))
        }
    }
    private var conditionsSection: some View {
        Section {
            ForEach(conditions) { condition in
                Button {
                    endEditing(); conditionPresentation = TrackerConditionPresentation(condition: condition)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(condition.name).foregroundStyle(.primary)
                        Text(L.text(condition.relation == .inside ? "Inside 200 m" : "Outside 200 m"))
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.accessibilityIdentifier("tracker.condition.\(condition.id.uuidString)")
                    .swipeActions(allowsFullSwipe: false) {
                        Button(L.text("Remove"), role: .destructive) { conditionRemoval = condition }
                    }
                    .accessibilityAction(named: L.text("Remove condition")) { conditionRemoval = condition }
            }
            Button {
                endEditing(); conditionPresentation = TrackerConditionPresentation(condition: nil)
            } label: { Label(L.text("Add location condition"), systemImage: "plus") }
                .accessibilityIdentifier("tracker.conditions.add")
            if conditions.count > 1 {
                Picker(L.text("Combine conditions"), selection: $combination) {
                    Text(L.text("Any condition")).tag(ConditionCombination.any)
                    Text(L.text("All conditions")).tag(ConditionCombination.all)
                }.accessibilityIdentifier("tracker.conditions.combination")
            }
            Toggle(L.text("Require conditions to save a record"), isOn: $gateSave)
                .disabled(conditions.isEmpty).accessibilityIdentifier("tracker.conditions.gate")
        } header: { Text(L.text("Location conditions")) } footer: {
            Text(L.text(conditions.isEmpty
                ? "Add a place to require a location check or enable a condition reminder."
                : "New records and changes to a record’s number or date require a fresh location check. Notes and photos can still be edited."))
        }
    }
    private var notificationsSection: some View {
        Section {
            NavigationLink {
                ReminderScheduleEditor(reminder: $reminder)
            } label: {
                LabeledContent(L.text("Time and weekdays"), value: L.text(reminder == nil ? "Off" : "On"))
            }.accessibilityIdentifier("tracker.reminders.schedule")
            Toggle(L.text("Remind me when conditions are met"), isOn: $remindWhenMet)
                .disabled(conditions.isEmpty).accessibilityIdentifier("tracker.conditions.remind")
            if !Reminders.enabled {
                Text(L.text("All reminders are off in Settings. Your tracker choices are kept.")).font(.caption).foregroundStyle(.secondary)
            } else if !notificationAuthorized {
                Text(L.text("Notifications are disabled. You can enable them in iPhone Settings.")).font(.caption).foregroundStyle(.secondary)
            }
            if remindWhenMet, let key = runtime.availabilityKey {
                Text(L.text(key)).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("tracker.conditions.availability")
            }
            if Reminders.enabled && ((remindWhenMet && runtime.authorization != .authorizedAlways) || !notificationAuthorized) {
                Link(L.text("Open iPhone Settings"), destination: URL(string: UIApplication.openSettingsURLString)!)
                    .accessibilityIdentifier("tracker.reminders.settings")
            }
        } header: { Text(L.text("Reminders")) } footer: {
            Text(L.text("Location reminders need Always location access. They never create records automatically."))
        }
    }
    private var photoSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) { photoHeading; Spacer(); addPhotos }
                    VStack(alignment: .leading, spacing: 8) { photoHeading; addPhotos }
                }
                if !photos.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) { ForEach(photos) { photoTile($0) } }
                    }.scrollIndicators(.hidden).accessibilityIdentifier("tracker.photoRail")
                }
                if loadingPhotos { ProgressView(L.text("Saving photo copies")) }
            }
        }
    }
    private var photoHeading: some View {
        HStack(spacing: 8) {
            Text(L.text("Photos")).font(.subheadline.weight(.semibold))
            Text("\(photos.count)/\(Entry.photoLimit)").font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel(L.text("Photos")).accessibilityValue("\(photos.count)/\(Entry.photoLimit)")
                .accessibilityIdentifier("tracker.photos.count")
        }
    }
    private var addPhotos: some View {
        PhotosPicker(selection: $selections, maxSelectionCount: max(1, Entry.photoLimit - photos.count),
                     selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current) {
            Label(L.text("Add photos"), systemImage: "plus").frame(minHeight: 44)
        }.buttonStyle(.borderless).disabled(loadingPhotos || photos.count == Entry.photoLimit)
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
                        .frame(width: 104, height: 104).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }.frame(width: 104, height: 104).buttonStyle(.plain)
                .accessibilityLabel(photoLabel("Tracker photo %lld", photo))
                .accessibilityIdentifier("tracker.photo.\(photo.id.uuidString)")
            Button { endEditing(); photoRemoval = photo } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24).background(.red, in: Circle())
                    .overlay { Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5) }
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(loadingPhotos)
                .accessibilityLabel(photoLabel("Remove photo %lld", photo))
                .accessibilityIdentifier("tracker.photo.remove.\(photo.id.uuidString)").offset(x: 18, y: -18)
        }.frame(width: 104, height: 104).padding(.top, 18).padding(.trailing, 18)
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
    private var typeLocked: Bool { !(existing?.entries.isEmpty ?? true) || !(existing?.rules.isEmpty ?? true) }
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
        guard let t = existing else { return }
        name = t.name; kind = t.kind; unit = t.unit; precision = t.precision; direction = t.direction
        description = t.description ?? ""; website = t.website ?? ""
        photos = (t.photos ?? []).map { DraftPhoto(data: $0) }
        axisLower = t.axisLower ?? ""; axisUpper = t.axisUpper ?? ""
        reminder = t.reminder; conditions = t.resolvedConditions; combination = t.resolvedCombination
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
        guard conditions.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 120 && $0.location.isValid }),
              Set(conditions.map(\.id)).count == conditions.count else { throw ConditionError("Choose a valid place for every condition.") }
        guard !(gateSave || remindWhenMet) || !conditions.isEmpty else { throw ConditionError("Add a place before enabling location conditions.") }
        if reminder?.weekdays.isEmpty == true { throw ConditionError("Choose at least one weekday.") }
        t.name = name.trimmingCharacters(in: .whitespacesAndNewlines); t.kind = kind; t.unit = unit; t.precision = precision; t.direction = direction
        t.description = description.isEmpty ? nil : description; t.website = try TrackerFields.website(website)
        t.photos = photos.isEmpty ? nil : photos.map(\.data)
        if kind == .number { (t.axisLower, t.axisUpper) = try TrackerFields.axis(lower: axisLower, upper: axisUpper, locale: L.locale) }
        else { t.axisLower = nil; t.axisUpper = nil }
        t.conditions = conditions.isEmpty ? nil : conditions; t.conditionCombination = conditions.isEmpty ? nil : combination
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
private struct TrackerConditionPresentation: Identifiable {
    let id = UUID()
    let condition: PlaceCondition?
}
