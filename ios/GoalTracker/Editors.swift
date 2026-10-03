import SwiftUI
import PhotosUI
import ImageIO

struct TrackerEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var existing: Tracker?
    @State private var name = ""
    @State private var kind = TrackerKind.number
    @State private var unit = ""
    @State private var precision = 3
    @State private var direction = Direction.up
    @State private var goalEnabled = false
    @State private var target = ""
    @State private var due = Date().addingTimeInterval(86400 * 30)
    @State private var period = Period.weekly
    @State private var frequency = 2
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section(L.text("Tracker")) {
                    TextField(L.text("Name"), text: $name).accessibilityIdentifier("tracker.name")
                    Picker(L.text("Record type"), selection: $kind) {
                        Text(L.text("Number snapshot")).tag(TrackerKind.number)
                        Text(L.text("Daily completion")).tag(TrackerKind.daily)
                    }.accessibilityIdentifier("tracker.kind").disabled(!(existing?.entries.isEmpty ?? true) || !(existing?.rules.isEmpty ?? true))
                    if !(existing?.entries.isEmpty ?? true) { Text(L.text("Create a new tracker to change its type or unit.")).font(.caption).foregroundStyle(.secondary) }
                    if kind == .number {
                        TextField(L.text("Unit (optional)"), text: $unit).disabled(!(existing?.entries.isEmpty ?? true) || !(existing?.rules.isEmpty ?? true)).accessibilityIdentifier("tracker.unit")
                        Stepper(L.text("Decimal places") + ": \(precision)", value: $precision, in: 0...8)
                        Picker(L.text("Improvement direction"), selection: $direction) {
                            Text(L.text("Higher is better")).tag(Direction.up); Text(L.text("Lower is better")).tag(Direction.down)
                        }
                    }
                }
                Section(L.text("Goal")) {
                    if existing?.rules.isEmpty ?? true { Toggle(L.text("Set a goal"), isOn: $goalEnabled).accessibilityIdentifier("goal.enabled") }
                    if goalEnabled {
                        if kind == .number {
                            TextField(L.text("Target value"), text: $target).keyboardType(.numbersAndPunctuation).accessibilityIdentifier("goal.target")
                            DatePicker(L.text("Deadline"), selection: $due, in: Date()..., displayedComponents: [.date])
                        } else {
                            Picker(L.text("Frequency"), selection: $period) {
                                Text(L.text("Weekly")).tag(Period.weekly); Text(L.text("Monthly")).tag(Period.monthly)
                            }
                            Stepper(L.text("Completions") + ": \(frequency)", value: $frequency, in: 1...(period == .weekly ? 7 : 31))
                                .accessibilityIdentifier("goal.frequency")
                            if !(existing?.rules.isEmpty ?? true) { Text(L.text("Changes start with the next full period. Past goals stay unchanged.")).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                Section {
                    if let t = existing { LabeledContent(L.text("Statistics time zone"), value: t.timeZoneID) }
                    else { LabeledContent(L.text("Statistics time zone"), value: TimeZone.current.identifier) }
                }
                if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("editor.error") } }
            }
            .navigationTitle(L.text(existing == nil ? "New tracker" : "Edit tracker"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L.text("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(L.text("Save"), action: save).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 120 || unit.count > 30).accessibilityIdentifier("tracker.save") }
            }
            .onAppear {
                guard let t = existing else { return }
                name = t.name; kind = t.kind; unit = t.unit; precision = t.precision; direction = t.direction
                if let rule = t.rules.max(by: { $0.effectiveAt < $1.effectiveAt }) {
                    goalEnabled = true; target = rule.target; due = rule.deadline ?? due; period = rule.period; frequency = Int(rule.target) ?? 2
                }
            }
            .onChange(of: period) { _, _ in frequency = min(frequency, period == .weekly ? 7 : 31) }
        }
    }
    private func save() {
        do {
            var t = existing ?? Tracker(name: name, kind: kind)
            t.name = name.trimmingCharacters(in: .whitespacesAndNewlines); t.kind = kind; t.unit = unit; t.precision = precision; t.direction = direction
            if goalEnabled {
                if kind == .number {
                    let value = try Numbers.parse(target, locale: L.locale)
                    let end = t.calendar.date(byAdding: .day, value: 1, to: t.calendar.startOfDay(for: due))!.addingTimeInterval(-0.001)
                    let prior = t.rules.max { $0.effectiveAt < $1.effectiveAt }
                    if prior?.target != value || prior?.deadline != end || prior?.direction != direction {
                        t.rules.append(GoalRule(period: .deadline, target: value, effectiveAt: Date(), deadline: end, direction: direction))
                    }
                } else if t.rules.max(by: { $0.effectiveAt < $1.effectiveAt })?.target != String(frequency) || t.rules.max(by: { $0.effectiveAt < $1.effectiveAt })?.period != period {
                    t.setFrequency(period, target: frequency, now: Date())
                }
            }
            try store.save(t); dismiss()
        } catch { self.error = L.error(error) }
    }
}

struct EntryEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let tracker: Tracker
    var existing: Entry?
    @State private var date = Date()
    @State private var value = ""
    @State private var note = ""
    @State private var photos: [Data] = []
    @State private var selections: [PhotosPickerItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var deleting = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if tracker.kind == .number {
                        TextField(L.text("Value"), text: $value).keyboardType(.numbersAndPunctuation).accessibilityIdentifier("entry.value")
                    }
                    DatePicker(L.text("Date"), selection: $date, in: ...Date(), displayedComponents: tracker.kind == .number ? [.date, .hourAndMinute] : [.date])
                        .environment(\.timeZone, tracker.calendar.timeZone).accessibilityIdentifier("entry.date")
                    TextField(L.text("Notes (optional)"), text: $note, axis: .vertical).lineLimit(3...8).accessibilityIdentifier("entry.note")
                }
                Section(L.text("Photos")) {
                    ForEach(Array(photos.enumerated()), id: \.offset) { index, data in
                        if let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFit().accessibilityLabel(L.text("Record photo"))
                            Button(L.text("Remove photo"), role: .destructive) { photos.remove(at: index) }
                        }
                    }
                    if photos.count < 6 {
                        PhotosPicker(selection: $selections, maxSelectionCount: 6 - photos.count, matching: .images) {
                            Label(L.text("Add photos"), systemImage: "photo.badge.plus")
                        }.disabled(loading).accessibilityIdentifier("entry.photos")
                    }
                    if loading { ProgressView(L.text("Saving photo copies")) }
                    Text(L.text("Photos are copied into the app. Up to 6 per record, resized to 1600 pixels.")).font(.caption).foregroundStyle(.secondary)
                }
                if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("editor.error") } }
                if let existing, tracker.entries.contains(where: { $0.id == existing.id }) {
                    Section { Button(L.text("Delete record"), role: .destructive) { deleting = true }.accessibilityIdentifier("entry.delete") }
                }
            }
            .navigationTitle(L.text(existing == nil ? "New record" : "Record details"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L.text("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.text("Save"), action: save).disabled(loading || note.count > 10000 || (tracker.kind == .number && value.isEmpty)).accessibilityIdentifier("entry.save")
                }
            }
            .onAppear {
                if let e = existing { date = e.occurredAt; value = e.value ?? ""; note = e.note; photos = e.photos }
            }
            .onChange(of: selections) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    loading = true
                    defer { loading = false; selections = [] }
                    do {
                        var copies: [Data] = []
                        for item in items {
                            guard let data = try await item.loadTransferable(type: Data.self) else { throw DataError.photoFailed }
                            let copy = try photoCopy(data)
                            copies.append(copy)
                        }
                        photos.append(contentsOf: copies)
                    } catch { self.error = L.error(error) }
                }
            }
            .confirmationDialog(L.text("Delete this record and its photos?"), isPresented: $deleting, titleVisibility: .visible) {
                Button(L.text("Delete record"), role: .destructive) {
                    do {
                        var t = store.trackers.first { $0.id == tracker.id } ?? tracker
                        t.entries.removeAll { $0.id == existing?.id }
                        try store.save(t); dismiss()
                    } catch { self.error = L.error(error) }
                }
            }
        }
    }
    private func save() {
        do {
            var t = store.trackers.first { $0.id == tracker.id } ?? tracker
            var e = existing ?? Entry(occurredAt: date, localDay: t.day(date))
            e.occurredAt = date; e.localDay = existing?.occurredAt == date ? (existing?.localDay ?? t.day(date)) : t.day(date); e.note = note; e.photos = photos; e.updatedAt = Date()
            e.value = t.kind == .number ? try Numbers.parse(value, locale: L.locale) : nil
            if t.kind == .daily, let conflict = t.entries.first(where: { $0.localDay == e.localDay && $0.id != e.id }) {
                if existing != nil { throw DataError.duplicateDay }
                // Preserve the original creation time when updating an already completed date.
                e.id = conflict.id; e.createdAt = conflict.createdAt
                if existing == nil { e.photos = conflict.photos + photos; e.note = note.isEmpty ? conflict.note : note }
            }
            t.put(e); try store.save(t); dismiss()
        } catch { self.error = L.error(error) }
    }
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
