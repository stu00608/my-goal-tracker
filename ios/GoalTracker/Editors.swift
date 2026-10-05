import SwiftUI
import PhotosUI
import ImageIO
import UIKit

struct EntryEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("recordLocationByDefault", store: L.defaults) private var recordLocationByDefault = false
    @AppStorage("numericInputMode", store: L.defaults) private var preferredInputMode = NumericEntryMode.direct.rawValue
    let tracker: Tracker
    var existing: Entry?
    @State private var date = Date()
    @State private var dateEdited = false
    @State private var value = ""
    @State private var inputMode = NumericEntryMode.direct
    @State private var change = ""
    @State private var note = ""
    @State private var photos: [DraftPhoto] = []
    @State private var selections: [PhotosPickerItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var deleting = false
    @State private var location = RecordLocationRecorder()
    @State private var initialized = false
    @State private var editorActive = true
    @State private var photoTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    @State private var saving = false
    @State private var gatePending = false
    @State private var draftEntry = Entry(occurredAt: Date(), localDay: "")
    @State private var pendingMutation: PendingEntryMutation?
    @State private var confirmingOrphan = false
    @State private var keyboard = EditorKeyboardControl()
    @State private var photoPresentation: EditorPhotoPresentation?
    @State private var photoRemoval: DraftPhoto?
    @State private var discarding = false
    @State private var initialValue = ""
    @State private var initialChange = ""
    @State private var initialMode = NumericEntryMode.direct
    @State private var initialLocationEnabled = false
    @FocusState private var valueFocused: Bool
    @FocusState private var noteFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        if tracker.kind == .number {
                            VStack(spacing: 0) {
                                if !isPersistedEntry {
                                    HStack {
                                        Spacer(minLength: 0)
                                        Picker(L.text("Value input"), selection: $inputMode) {
                                            Text(L.text("New value")).tag(NumericEntryMode.direct)
                                            Text(L.text("Change amount")).tag(NumericEntryMode.change).disabled(numericBaseline == nil)
                                        }.labelsHidden().pickerStyle(.menu).buttonStyle(.borderless)
                                            .font(.subheadline).accessibilityIdentifier("entry.inputMode")
                                        Spacer(minLength: 0)
                                    }
                                } else {
                                    Text(L.text(inputMode == .change ? "Change amount" : "New value")).font(.subheadline).foregroundStyle(Color.secondary)
                                }
                                numericArea
                            }
                            photoArea
                        } else {
                            photoArea
                        }
                    }.padding(.vertical, 4)
                }.listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                    .disabled(saving)
                if currentTracker.requiresConditionGate {
                    Section(L.text("Achievement conditions")) { ConditionStatusView(tracker: currentTracker, onFailure: { error = $0 }) }
                }
                Section {
                    DatePicker(L.text("Date"), selection: Binding(get: { date }, set: { endEditing(); date = $0; dateEdited = true }), in: ...Date(), displayedComponents: tracker.kind == .number ? [.date, .hourAndMinute] : [.date])
                        .simultaneousGesture(TapGesture().onEnded { endEditing() })
                        .environment(\.timeZone, tracker.calendar.timeZone).accessibilityIdentifier("entry.date")
                    TextField(L.text("Notes (optional)"), text: $note, axis: .vertical).focused($noteFocused)
                        .lineLimit(3...8).accessibilityIdentifier("entry.note")
                }.disabled(saving)
                Section(L.text("Location")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(L.text("Record location"), isOn: Binding(get: { location.draft.enabled }, set: { endEditing(); location.setEnabled($0) }))
                            .accessibilityIdentifier("entry.location").disabled(saving)
                        if location.draft.enabled {
                            Text(L.text(location.draft.status?.key ?? "Current iPhone location, not the record’s historical location.")).font(.subheadline).foregroundStyle(Color.secondary)
                                .accessibilityIdentifier("entry.location.status")
                        }
                        if gatePending {
                            ProgressView(L.text("Checking record conditions")).accessibilityIdentifier("entry.conditions.pending")
                        } else if saving {
                            ProgressView(L.text("Getting location before saving")).accessibilityIdentifier("entry.location.pending")
                            Button(L.text("Save without location")) { location.cancel() }
                                .buttonStyle(.borderless).accessibilityIdentifier("entry.location.saveWithout")
                        }
                    }
                }
                if isPersistedEntry {
                    Section { Button(L.text("Delete record"), role: .destructive) { deleting = true }.accessibilityIdentifier("entry.delete").disabled(saving) }
                }
            }
            .listSectionSpacing(16)
            .statusToast(message: $error, identifier: "editor.error", autoDismiss: false)
            .scrollDismissesKeyboard(.interactively)
            .background(EditorKeyboardDismissal(keyboard: keyboard) { valueFocused = false; noteFocused = false })
            .background(EditorDismissalObserver(onDismiss: stopRequests))
            .navigationTitle(tracker.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L.text("Cancel")) { endEditing(); if dirty { discarding = true } else { stopRequests(); dismiss() } }.accessibilityIdentifier("entry.cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.text("Save"), action: beginSave)
                        .disabled(saving || loading || note.count > 10000 || (tracker.kind == .number && numericInput.isEmpty))
                        .accessibilityIdentifier("entry.save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    if valueFocused {
                        Button("±") {
                            do { numericBinding.wrappedValue = try NumericEntry.flipSign(numericInput, locale: L.locale) }
                            catch { self.error = L.error(error) }
                        }.accessibilityLabel(L.text("Change sign")).accessibilityIdentifier("entry.sign")
                    }
                    Spacer()
                    Button(L.text("Done"), action: endEditing).accessibilityIdentifier("entry.keyboard.done")
                }
            }
            .onAppear {
                editorActive = true
                guard !initialized else { return }
                initialized = true
                let raw = existing.flatMap { supplied in currentTracker.entries.first { $0.id == supplied.id } } ?? existing
                if let e = raw {
                    draftEntry = e
                    date = e.occurredAt; dateEdited = true
                    value = (e.value ?? "").replacingOccurrences(of: ".", with: L.locale.decimalSeparator ?? ".")
                    change = (e.change ?? "").replacingOccurrences(of: ".", with: L.locale.decimalSeparator ?? ".")
                    note = e.note; photos = e.photos.map { DraftPhoto(data: $0) }
                } else {
                    draftEntry = Entry(occurredAt: date, localDay: currentTracker.day(date))
                }
                inputMode = isPersistedEntry ? (raw?.change == nil ? .direct : .change) : NumericEntryMode.initial(preference: preferredInputMode, hasBaseline: numericBaseline != nil, editing: false)
                location.draft = RecordLocationDraft(existing: raw?.location, defaultEnabled: !isPersistedEntry && recordLocationByDefault)
                initialValue = value; initialChange = change; initialMode = inputMode
                initialLocationEnabled = location.draft.enabled
            }
            .interactiveDismissDisabled(dirty || saving || loading)
            .confirmationDialog(L.text("Discard changes?"), isPresented: $discarding, titleVisibility: .visible) {
                Button(L.text("Discard changes"), role: .destructive) { stopRequests(); dismiss() }
                    .accessibilityIdentifier("entry.discard")
                Button(L.text("Keep editing"), role: .cancel) { }
                    .accessibilityIdentifier("entry.keepEditing")
            }
            .onChange(of: isPresented) { _, presented in if !presented { stopRequests() } }
            .onDisappear { if !isPresented { stopRequests() } }
            .onChange(of: numericBaseline?.id) { _, id in if id == nil, !isPersistedEntry { inputMode = .direct } }
            .onChange(of: inputMode) { _, mode in
                endEditing()
                if mode == .change, numericBaseline == nil, !isPersistedEntry { inputMode = .direct }
            }
            .fullScreenCover(item: $photoPresentation) { selection in
                PhotoViewer(photos: selection.photos, initialIndex: selection.initialIndex)
            }
            .sheet(item: $photoRemoval) { photo in
                NavigationStack {
                    VStack(spacing: 20) {
                        if let image = UIImage(data: photo.data) {
                            Image(uiImage: image).resizable().scaledToFit()
                                .accessibilityLabel(L.text("Photo to remove")).accessibilityIdentifier("entry.photoRemoval.preview")
                        }
                        Text(L.text("This photo is removed only when you save the record."))
                            .font(.subheadline).foregroundStyle(Color.secondary)
                    }.padding()
                        .navigationTitle(L.text("Photos")).navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(L.text("Cancel")) { photoRemoval = nil }.accessibilityIdentifier("entry.photoRemoval.cancel")
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button(L.text("Remove photo"), role: .destructive) {
                                    let wasFirst = photos.first?.id == photo.id
                                    photos.removeAll { $0.id == photo.id }
                                    if wasFirst { location.setFirstPhoto(nil) }
                                    photoRemoval = nil
                                }.accessibilityIdentifier("entry.photoRemoval.confirm")
                            }
                        }
                }.presentationDetents([.medium, .large])
            }
            .onChange(of: selections) { _, items in importPhotos(items) }
            .confirmationDialog(L.text("Delete this record and its photos?"), isPresented: $deleting, titleVisibility: .visible) {
                Button(L.text("Delete record"), role: .destructive) {
                    prepareDeletion()
                }.accessibilityIdentifier("entry.delete.confirm")
            }
            .alert(L.text("Keep later change records?"), isPresented: $confirmingOrphan) {
                Button(L.text("Convert first change to a value")) { confirmMutation() }
                    .accessibilityIdentifier("entry.orphan.confirm")
                Button(L.text("Cancel"), role: .cancel) { pendingMutation = nil }
                    .accessibilityIdentifier("entry.orphan.cancel")
            } message: {
                if let orphan = pendingMutation?.mutation.orphan {
                    Text(String(format: L.text("This change would leave later records without a baseline. Convert the first affected record to its previous value %@ and recalculate following changes?"), locale: L.locale, localizedValue(orphan.value ?? "")))
                }
            }
        }
    }

    private var numericArea: some View {
        VStack(spacing: 4) {
            NumericValueEditor(text: numericBinding, precision: tracker.precision, unit: tracker.unit,
                               isChange: inputMode == .change, placeholder: numericBaseline?.value.flatMap(Numbers.decimal).map { Numbers.display($0, precision: tracker.precision, locale: L.locale) } ?? "0", focus: $valueFocused)
            if inputMode == .change, let baseline = numericBaseline {
                HStack(spacing: 6) {
                    Text(localizedValue(baseline.value ?? ""))
                        .accessibilityLabel(L.text("Baseline value")).accessibilityValue(localizedValue(baseline.value ?? ""))
                        .accessibilityIdentifier("entry.baseline")
                    Image(systemName: "arrow.right").accessibilityHidden(true)
                    switch numericPreview {
                    case .success(let result):
                        Text(localizedValue(result.value)).accessibilityLabel(L.text("Resulting value")).accessibilityValue(localizedValue(result.value))
                            .accessibilityIdentifier("entry.result")
                    case .failure:
                        Text("—").accessibilityLabel(L.text("Resulting value"))
                    }
                }.font(.subheadline.monospacedDigit()).foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(baseline.occurredAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L.locale, timeZone: tracker.calendar.timeZone)))
                    .font(.subheadline).foregroundStyle(Color.secondary)
                    .accessibilityLabel(L.text("Baseline date"))
                    .accessibilityValue(baseline.occurredAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L.locale, timeZone: tracker.calendar.timeZone)))
                    .accessibilityIdentifier("entry.baselineDate")
                if case .failure(let failure) = numericPreview, !change.isEmpty {
                    Text(numericError(failure)).font(.subheadline).foregroundStyle(.red)
                }
            } else if inputMode == .change, numericBaseline == nil {
                Text(L.text(isPersistedEntry && inputMode == .change
                            ? "No earlier value at this position. Saving requires confirming conversion to the previous value."
                            : "No earlier value for this date. Enter a new value first."))
                    .font(.subheadline).foregroundStyle(Color.secondary)
            }
            if isPersistedEntry, inputMode == .change {
                Text(L.text("Editing this change recalculates later values until the next new value record."))
                    .font(.subheadline).foregroundStyle(Color.secondary)
                    .accessibilityIdentifier("entry.change.explanation")
            }
        }.multilineTextAlignment(.center).padding(.bottom, 12)
    }

    private var photoArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    photoHeading
                    addPhotos
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    photoHeading
                    Spacer(minLength: 4)
                    addPhotos
                }
            }
            if !photos.isEmpty {
                DraftPhotoRail(photos: photos, identifierPrefix: "entry", photoLabelKey: "Record photo %lld", removalDisabled: loading,
                               vertical: comparisonLayout && !dynamicTypeSize.isAccessibilitySize, onOpen: { index in
                    endEditing()
                    photoPresentation = EditorPhotoPresentation(photos: photos.map(\.data), initialIndex: index)
                }, onRemove: { endEditing(); photoRemoval = $0 })
            }
            if loading { ProgressView(L.text("Saving photo copies")) }
        }
    }

    private var photoHeading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L.text("Photos")).font(.subheadline.weight(.semibold))
            if !photos.isEmpty {
                Text("\(photos.count)/\(Entry.photoLimit)").font(.subheadline.monospacedDigit()).foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel(L.text("Photos")).accessibilityValue("\(photos.count)/\(Entry.photoLimit)")
                    .accessibilityIdentifier("entry.photos.count")
            }
        }
    }
    private var addPhotos: some View {
        let accessibilitySize = dynamicTypeSize.isAccessibilitySize
        return PhotosPicker(selection: $selections, maxSelectionCount: max(1, Entry.photoLimit - photos.count), selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "plus").font(.body).accessibilityHidden(true)
                Text(L.text("Add photos")).font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: accessibilitySize ? .infinity : nil, minHeight: 44, alignment: .leading)
        }.buttonStyle(.borderless).simultaneousGesture(TapGesture().onEnded { endEditing() })
            .disabled(loading || photos.count == Entry.photoLimit).accessibilityIdentifier("entry.photos")
    }

    private var comparisonLayout: Bool {
#if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--uitesting") && ProcessInfo.processInfo.arguments.contains("--ux-input-alternative")
#else
        false
#endif
    }
    private var dirty: Bool {
        initialized && (date != draftEntry.occurredAt || value != initialValue || change != initialChange || inputMode != initialMode
            || note != draftEntry.note || photos.map(\.data) != draftEntry.photos || location.draft.enabled != initialLocationEnabled || loading)
    }
    private var currentTracker: Tracker { store.trackers.first { $0.id == tracker.id } ?? tracker }
    private var isPersistedEntry: Bool { existing.map { entry in currentTracker.entries.contains { $0.id == entry.id } } ?? false }
    private var numericInput: String { inputMode == .direct ? value : change }
    private var numericBinding: Binding<String> {
        inputMode == .direct ? $value : $change
    }
    private var numericBaseline: Entry? { NumericEntry.baseline(in: currentTracker, at: date, excluding: existing?.id, position: draftEntry) }
    private var numericPreview: Result<NumericEntryResult, Error> {
        Result { try NumericEntry.calculate(numericInput, mode: inputMode, tracker: currentTracker, at: date, excluding: existing?.id, position: draftEntry, locale: L.locale) }
    }
    private func localizedValue(_ value: String) -> String {
        value.replacingOccurrences(of: ".", with: L.locale.decimalSeparator ?? ".") + (tracker.unit.isEmpty ? "" : " " + tracker.unit)
    }
    private func numericError(_ error: Error) -> String {
        error is NumericEntryError ? L.text("No earlier value for this date. Enter a new value first.") : L.error(error)
    }
    private func stopRequests() {
        endEditing()
        editorActive = false; saveTask?.cancel(); photoTask?.cancel(); location.cancel()
    }
    private func endEditing() { keyboard.dismiss(); valueFocused = false; noteFocused = false }
    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty, !loading else { return }
        loading = true
        photoTask = Task {
            defer { if editorActive { loading = false; selections = [] } }
            do {
                var copies: [DraftPhoto] = []
                var firstDate: Date?
                var firstLocation: RecordedLocation?
                for (index, item) in items.enumerated() {
                    guard !Task.isCancelled, editorActive else { return }
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw DataError.photoFailed }
                    guard !Task.isCancelled, editorActive else { return }
                    if index == 0 {
                        firstDate = photoDate(data, timeZone: tracker.calendar.timeZone)
                        if photos.isEmpty { firstLocation = photoLocation(data) }
                    }
                    copies.append(DraftPhoto(data: try photoCopy(data)))
                }
                guard photos.count + copies.count <= Entry.photoLimit else { throw DataError.tooManyPhotos }
                if existing == nil, photos.isEmpty, !dateEdited, let firstDate { date = firstDate }
                if photos.isEmpty { location.setFirstPhoto(firstLocation) }
                photos.append(contentsOf: copies); error = nil
            } catch { if !Task.isCancelled, editorActive { self.error = L.error(error) } }
        }
    }

    /// Preserve unchanged raw dates and parse the same canonical input used by the preview.
    private func preparedEntry(in t: Tracker) throws -> Entry {
        let raw = existing.flatMap { supplied in t.entries.first { $0.id == supplied.id } }
        var e = raw ?? draftEntry
        e.occurredAt = date
        e.localDay = raw?.occurredAt == date ? (raw?.localDay ?? t.day(date)) : t.day(date)
        e.note = note; e.photos = photos.map(\.data); e.updatedAt = Date()
        e.value = nil; e.change = nil
        if t.kind == .number {
            let raw = try NumericEntry.rawInput(numericInput, mode: inputMode, locale: L.locale)
            if inputMode == .direct { e.value = raw } else { e.change = raw }
        }
        var priorLocation = e.location
        if t.kind == .daily, let conflict = t.entries.first(where: { $0.localDay == e.localDay && $0.id != e.id }) {
            if existing != nil { throw DataError.duplicateDay }
            e.id = conflict.id; e.createdAt = conflict.createdAt; priorLocation = conflict.location
            e.photos = conflict.photos + photos.map(\.data); e.note = note.isEmpty ? conflict.note : note
        }
        e.location = location.draft.applying(to: priorLocation)
        guard e.photos.count <= Entry.photoLimit else { throw DataError.tooManyPhotos }
        return e
    }
    private func beginSave() {
        guard !saving else { return }
        do {
            let original = currentTracker
            let entry = try preparedEntry(in: original)
            let mutation = try NumericEntry.mutation(in: original, replacing: entry)
            error = nil; endEditing()
            let pending = PendingEntryMutation(original: original, mutation: mutation, entry: entry)
            if mutation.orphan != nil { pendingMutation = pending; confirmingOrphan = true }
            else { save(pending) }
        } catch { self.error = numericError(error) }
    }
    private func prepareDeletion() {
        do {
            let original = currentTracker
            let mutation = try NumericEntry.mutation(in: original, deleting: existing?.id)
            let pending = PendingEntryMutation(original: original, mutation: mutation, entry: nil)
            if mutation.orphan != nil { pendingMutation = pending; confirmingOrphan = true }
            else { save(pending) }
        } catch { self.error = numericError(error) }
    }
    private func confirmMutation() {
        guard let pending = pendingMutation else { return }
        pendingMutation = nil
        save(pending)
    }
    private func save(_ pending: PendingEntryMutation) {
        guard !saving else { return }
        saving = true
        saveTask = Task {
            defer { saving = false; gatePending = false }
            do {
                try Task.checkCancellation()
                guard editorActive else { return }
                // A confirmed candidate may never overwrite changes made while its dialog was open.
                guard store.trackers.first(where: { $0.id == tracker.id }) == pending.original else {
                    error = L.text("Records changed while saving. Review the entry and try again."); return
                }
                if let entry = pending.entry, NumericEntry.requiresGate(in: pending.original, for: entry, editing: existing?.id) {
                    gatePending = true
                    try await RecordConditions.verify(tracker: pending.original)
                    gatePending = false
                }
                try Task.checkCancellation()
                guard editorActive else { return }
                let resolvingLocation = pending.entry != nil && location.draft.canResolve
                if resolvingLocation { await location.resolveForSave() }
                try Task.checkCancellation()
                guard editorActive else { return }
                if resolvingLocation, let entry = pending.entry, NumericEntry.requiresGate(in: pending.original, for: entry, editing: existing?.id) {
                    gatePending = true
                    try await RecordConditions.verify(tracker: pending.original)
                    gatePending = false
                }
                try Task.checkCancellation()
                guard store.trackers.first(where: { $0.id == tracker.id }) == pending.original else {
                    error = L.text("Records changed while saving. Review the entry and try again."); return
                }
                var candidate = pending.mutation.tracker
                if let entry = pending.entry, let index = candidate.entries.firstIndex(where: { $0.id == entry.id }) {
                    candidate.entries[index].location = location.draft.applying(to: entry.location)
                }
                try store.save(candidate)
                stopRequests(); dismiss()
            } catch {
                if !Task.isCancelled, editorActive { self.error = numericError(error) }
            }
        }
    }
}

/// Shared app-owned photo previews with separate preview and removal targets.
struct DraftPhotoRail: View {
    let photos: [DraftPhoto]
    let identifierPrefix: String
    let photoLabelKey: String
    var removalDisabled = false
    var vertical = false
    let onOpen: (Int) -> Void
    let onRemove: (DraftPhoto) -> Void

    var body: some View {
        Group {
            if vertical {
                ScrollView(.vertical) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) { tiles }
                }.frame(height: 250)
            } else {
                ScrollView(.horizontal) { HStack(spacing: 12) { tiles } }.scrollIndicators(.hidden)
            }
        }.accessibilityIdentifier(identifierPrefix + ".photoRail")
    }
    private var tiles: some View {
        ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
            ZStack(alignment: .topTrailing) {
                Button { onOpen(index) } label: {
                    if let image = UIImage(data: photo.data) {
                        Image(uiImage: image).renderingMode(.original).resizable().scaledToFill()
                            .frame(width: 104, height: 104)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }.frame(width: 104, height: 104).contentShape(Rectangle()).buttonStyle(.plain)
                    .accessibilityLabel(String(format: L.text(photoLabelKey), locale: L.locale, index + 1))
                    .accessibilityIdentifier(identifierPrefix + ".photo." + photo.id.uuidString)
                Button { onRemove(photo) } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.65))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(removalDisabled)
                    .accessibilityLabel(String(format: L.text("Remove photo %lld"), locale: L.locale, index + 1))
                    .accessibilityIdentifier(identifierPrefix + ".photo.remove." + photo.id.uuidString)
            }.frame(width: 104, height: 104)
        }
    }
}

private struct PendingEntryMutation {
    let original: Tracker
    let mutation: NumericEntryMutation
    let entry: Entry? // nil is deletion: never location gated.
}
private struct EditorPhotoPresentation: Identifiable {
    let id = UUID()
    let photos: [Data]
    let initialIndex: Int
}

@MainActor func photoCopy(_ data: Data) throws -> Data {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          CGImageSourceGetCount(source) == 1 else { throw DataError.photoFailed }
    // Extreme detail can exceed 2 MB even at quality .65. Reduce dimensions before degrading further.
    for edge in [1600, 1440, 1280] {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge
          ] as CFDictionary) else { throw DataError.photoFailed }
        let still = UIImage(cgImage: image)
        for quality in [0.8, 0.75, 0.7, 0.65] {
            guard let copy = still.jpegData(compressionQuality: quality) else { throw DataError.photoFailed }
            if copy.count <= 2_000_000 {
                guard Backup.validPhoto(copy) else { throw DataError.photoFailed }
                return copy
            }
        }
    }
    throw DataError.photoFailed
}

// Read the original file before photoCopy strips metadata from the owned JPEG.
@MainActor func photoDate(_ data: Data, timeZone: TimeZone, now: Date = Date()) -> Date? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
    let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
    let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
    let original = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
    let digitized = exif[kCGImagePropertyExifDateTimeDigitized as String] as? String
    var result: Date?
    if let raw = original ?? digitized ?? (tiff[kCGImagePropertyTIFFDateTime as String] as? String) {
        let offsetKey = original != nil ? kCGImagePropertyExifOffsetTimeOriginal : digitized != nil ? kCGImagePropertyExifOffsetTimeDigitized : kCGImagePropertyExifOffsetTime
        let offset = exif[offsetKey as String] as? String
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.isLenient = false
        if let offset {
            guard offset.range(of: #"^[+-][0-9]{2}:[0-9]{2}$"#, options: .regularExpression) != nil else { return nil }
            let parts = offset.dropFirst().split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, parts[1] < 60, parts[0] * 60 + parts[1] <= 14 * 60 else { return nil }
            formatter.timeZone = TimeZone(secondsFromGMT: (parts[0] * 3600 + parts[1] * 60) * (offset.first == "-" ? -1 : 1))
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let date = formatter.date(from: raw), formatter.string(from: date) == raw { result = date }
    }
    guard let result, Backup.validDate(result), result <= now else { return nil }
    return result
}
