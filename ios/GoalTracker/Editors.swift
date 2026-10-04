import SwiftUI
import PhotosUI
import ImageIO

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
    @State private var keyboard = EditorKeyboardControl()
    @State private var photoPresentation: EditorPhotoPresentation?
    @State private var photoRemoval: DraftPhoto?
    @FocusState private var valueFocused: Bool
    @FocusState private var noteFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
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
                                    Text(L.text("New value")).font(.subheadline).foregroundStyle(TrackerColors.secondaryText)
                                }
                                numericArea
                            }
                            photoArea
                        } else {
                            photoArea
                        }
                        if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("editor.error") }
                    }.padding(.vertical, 4)
                }.listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .disabled(saving)
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
                        if let status = location.draft.status {
                            Text(L.text(status.key)).font(.caption).foregroundStyle(TrackerColors.secondaryText)
                                .accessibilityIdentifier("entry.location.status")
                        }
                        Text(L.text("When enabled, use the first photo’s GPS or your current iPhone location. No background tracking."))
                            .font(.caption).foregroundStyle(TrackerColors.secondaryText)
                        if saving {
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
            .scrollDismissesKeyboard(.interactively)
            .background(EditorKeyboardDismissal(keyboard: keyboard) { valueFocused = false; noteFocused = false })
            .background(EditorDismissalObserver(onDismiss: stopRequests))
            .navigationTitle(L.text(isPersistedEntry ? "Record details" : "New record"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L.text("Cancel")) { stopRequests(); dismiss() }.accessibilityIdentifier("entry.cancel") }
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
                if let e = existing {
                    date = e.occurredAt; dateEdited = true
                    value = (e.value ?? "").replacingOccurrences(of: ".", with: L.locale.decimalSeparator ?? ".")
                    note = e.note; photos = e.photos.map { DraftPhoto(data: $0) }
                }
                inputMode = NumericEntryMode.initial(preference: preferredInputMode, hasBaseline: numericBaseline != nil, editing: isPersistedEntry)
                location.draft = RecordLocationDraft(existing: existing?.location, defaultEnabled: !isPersistedEntry && recordLocationByDefault)
            }
            .onChange(of: isPresented) { _, presented in if !presented { stopRequests() } }
            .onDisappear { if !isPresented { stopRequests() } }
            .onChange(of: numericBaseline?.id) { _, id in if id == nil { inputMode = .direct } }
            .onChange(of: inputMode) { _, mode in
                endEditing()
                if mode == .change, numericBaseline == nil { inputMode = .direct }
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
                            .font(.subheadline).foregroundStyle(TrackerColors.secondaryText)
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
                    do {
                        var t = currentTracker
                        t.entries.removeAll { $0.id == existing?.id }
                        try store.save(t); stopRequests(); dismiss()
                    } catch { self.error = L.error(error) }
                }
            }
        }
    }

    private var numericArea: some View {
        VStack(spacing: 4) {
            NumericValueEditor(text: numericBinding, precision: tracker.precision, unit: tracker.unit,
                               isChange: inputMode == .change, focus: $valueFocused)
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
                }.font(.caption.monospacedDigit()).foregroundStyle(TrackerColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(baseline.occurredAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L.locale, timeZone: tracker.calendar.timeZone)))
                    .font(.caption2).foregroundStyle(TrackerColors.secondaryText)
                    .accessibilityLabel(L.text("Baseline date"))
                    .accessibilityValue(baseline.occurredAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L.locale, timeZone: tracker.calendar.timeZone)))
                    .accessibilityIdentifier("entry.baselineDate")
                if case .failure(let failure) = numericPreview, !change.isEmpty {
                    Text(numericError(failure)).font(.caption).foregroundStyle(.red)
                }
            } else if !isPersistedEntry, numericBaseline == nil {
                Text(L.text("No earlier value for this date. Enter a new value first."))
                    .font(.caption).foregroundStyle(TrackerColors.secondaryText)
            }
        }.multilineTextAlignment(.center).padding(.bottom, 12)
    }

    private var photoArea: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                if comparisonLayout && !dynamicTypeSize.isAccessibilitySize {
                    ScrollView(.vertical) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(photos) { photoTile($0) }
                        }
                    }.frame(height: 250).accessibilityIdentifier("entry.photoRail")
                } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(photos) { photoTile($0) }
                    }
                }.scrollIndicators(.hidden).accessibilityIdentifier("entry.photoRail")
                }
            }
            if loading { ProgressView(L.text("Saving photo copies")) }
        }
    }

    private var photoHeading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L.text("Photos")).font(.subheadline.weight(.semibold))
            Text("\(photos.count)/\(Entry.photoLimit)").font(.caption).foregroundStyle(TrackerColors.secondaryText)
                .accessibilityLabel(L.text("Photos")).accessibilityValue("\(photos.count)/\(Entry.photoLimit)")
                .accessibilityIdentifier("entry.photos.count")
        }
    }
    private var addPhotos: some View {
        PhotosPicker(selection: $selections, maxSelectionCount: max(1, Entry.photoLimit - photos.count), selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "plus").font(.system(size: 18)).accessibilityHidden(true)
                Text(L.text("Add photos")).font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: 44, alignment: .leading)
        }.buttonStyle(.borderless).simultaneousGesture(TapGesture().onEnded { endEditing() })
            .disabled(loading || photos.count == Entry.photoLimit).accessibilityIdentifier("entry.photos")
    }

    private func photoTile(_ photo: DraftPhoto) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                guard let index = photos.firstIndex(where: { $0.id == photo.id }) else { return }
                endEditing()
                photoPresentation = EditorPhotoPresentation(photos: photos.map(\.data), initialIndex: index)
            } label: {
                if let image = UIImage(data: photo.data) {
                    Image(uiImage: image).renderingMode(.original).resizable().scaledToFill()
                        .frame(width: 104, height: 104).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }.frame(width: 104, height: 104).contentShape(Rectangle())
                .buttonStyle(.plain).accessibilityLabel(photoLabel("Record photo %lld", photo: photo))
                .accessibilityIdentifier("entry.photo.\(photo.id.uuidString)")
            Button {
                endEditing(); photoRemoval = photo
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24).background(.red, in: Circle())
                    .overlay { Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5) }
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(loading)
                .accessibilityLabel(photoLabel("Remove photo %lld", photo: photo))
                .accessibilityIdentifier("entry.photo.remove.\(photo.id.uuidString)")
                .offset(x: 18, y: -18)
        }.frame(width: 104, height: 104)
            // Reserve the complete hit target around the protruding corner badge.
            .padding(.top, 18).padding(.trailing, 18)
    }

    private var comparisonLayout: Bool {
#if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--uitesting") && ProcessInfo.processInfo.arguments.contains("--ux-input-alternative")
#else
        false
#endif
    }
    private func photoLabel(_ key: String, photo: DraftPhoto) -> String {
        String(format: L.text(key), locale: L.locale, (photos.firstIndex { $0.id == photo.id } ?? 0) + 1)
    }
    private var currentTracker: Tracker { store.trackers.first { $0.id == tracker.id } ?? tracker }
    private var isPersistedEntry: Bool { existing.map { entry in currentTracker.entries.contains { $0.id == entry.id } } ?? false }
    private var numericInput: String { inputMode == .direct ? value : change }
    private var numericBinding: Binding<String> {
        inputMode == .direct ? $value : $change
    }
    private var numericBaseline: Entry? { NumericEntry.baseline(in: currentTracker, at: date, excluding: existing?.id) }
    private var numericPreview: Result<NumericEntryResult, Error> {
        Result { try NumericEntry.calculate(numericInput, mode: inputMode, tracker: currentTracker, at: date, excluding: existing?.id, locale: L.locale) }
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

    /// Validate before asking for location, then reconstruct against the latest tracker on commit.
    private func preparedEntry(in t: Tracker) throws -> Entry {
        var e = existing ?? Entry(occurredAt: date, localDay: t.day(date))
        e.occurredAt = date
        e.localDay = existing?.occurredAt == date ? (existing?.localDay ?? t.day(date)) : t.day(date)
        e.note = note; e.photos = photos.map(\.data); e.updatedAt = Date()
        e.value = t.kind == .number ? try NumericEntry.calculate(numericInput, mode: inputMode, tracker: t, at: date, excluding: existing?.id, locale: L.locale).value : nil
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
            _ = try preparedEntry(in: currentTracker)
            error = nil; endEditing()
            if location.draft.canResolve {
                saving = true
                saveTask = Task {
                    guard !Task.isCancelled, editorActive else { return }
                    await location.resolveForSave()
                    guard !Task.isCancelled, editorActive else { return }
                    saving = false; commit()
                }
            } else { commit() }
        } catch { self.error = numericError(error) }
    }
    private func commit() {
        do {
            var t = currentTracker
            t.put(try preparedEntry(in: t))
            try store.save(t); stopRequests(); dismiss()
        } catch { saving = false; self.error = numericError(error) }
    }
}

private struct EditorPhotoPresentation: Identifiable {
    let id = UUID()
    let photos: [Data]
    let initialIndex: Int
}

@MainActor func photoCopy(_ data: Data) throws -> Data {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600
          ] as CFDictionary),
          let copy = UIImage(cgImage: image).jpegData(compressionQuality: 0.8),
          Backup.validPhoto(copy) else { throw DataError.photoFailed }
    return copy
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
