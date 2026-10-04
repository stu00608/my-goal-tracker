import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("language") private var language = "system"
    @AppStorage("homeLayout") private var homeLayout = "grid"
    @AppStorage("recordLocationByDefault", store: L.defaults) private var recordLocationByDefault = false
    @AppStorage("numericInputMode", store: L.defaults) private var numericInputMode = NumericEntryMode.direct.rawValue
    @State private var export: ExportDocument?
    @State private var exporting = false
    @State private var csv = false
    @State private var importing = false
    @State private var pending: Backup?
    @State private var restoreConfirm = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section(L.text("Preferences")) {
                    Picker(L.text("Home layout"), selection: $homeLayout) {
                        Text(L.text("Grid")).tag("grid")
                        Text(L.text("List")).tag("list")
                    }.accessibilityIdentifier("settings.homeLayout")
                    Picker(L.text("Appearance"), selection: $appearance) {
                        Text(L.text("System")).tag("system"); Text(L.text("Light")).tag("light"); Text(L.text("Dark")).tag("dark")
                    }.accessibilityIdentifier("settings.appearance")
                    Picker(L.text("Language"), selection: $language) {
                        Text(L.text("System")).tag("system"); Text("繁體中文").tag("zh-Hant"); Text("日本語").tag("ja"); Text("English").tag("en")
                    }.accessibilityIdentifier("settings.language")
                    Picker(L.text("Default value input"), selection: $numericInputMode) {
                        Text(L.text("New value")).tag(NumericEntryMode.direct.rawValue)
                        Text(L.text("Change amount")).tag(NumericEntryMode.change.rawValue)
                    }.accessibilityIdentifier("settings.numericInputMode")
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(L.text("Record location by default"), isOn: $recordLocationByDefault)
                            .accessibilityIdentifier("settings.recordLocationDefault")
                        Text(L.text("Applies to new records only. You can change it for each record. Location is requested when you save."))
                            .font(.caption).foregroundStyle(TrackerColors.secondaryText)
                    }
                }
                Section {
                    ForEach(store.trackers.filter { !$0.archived }) { t in NavigationLink(t.name) { ReminderEditor(tracker: t) } }
                } header: { Text(L.text("Reminders")) } footer: {
                    Text(L.text("Enable a reminder to request notification permission. Delivery follows your iPhone settings.")).font(.caption).foregroundStyle(TrackerColors.secondaryText)
                }
                Section {
                    LabeledContent(L.text("Trackers"), value: "\(store.trackers.count)")
                    LabeledContent(L.text("Records"), value: "\(store.trackers.flatMap(\.entries).count)")
                    LabeledContent(L.text("Photo storage"), value: ByteCountFormatter.string(fromByteCount: Int64(store.trackers.flatMap(\.entries).flatMap(\.photos).reduce(0) { $0 + $1.count }), countStyle: .file))
                    Button(L.text("Export full backup")) { prepare(csv: false) }.accessibilityIdentifier("backup.export")
                    Button(L.text("Export CSV")) { prepare(csv: true) }.accessibilityIdentifier("csv.export")
                    Button(L.text("Restore backup")) { importing = true }.accessibilityIdentifier("backup.import")
                } header: { Text(L.text("Your data")) } footer: {
                    Text(L.text("A full backup includes records, goal history and photos. Keep a copy somewhere safe. Backups are not encrypted.")).font(.caption).foregroundStyle(TrackerColors.secondaryText)
                }
                if let b = pending {
                    Section(L.text("Backup preview")) {
                        LabeledContent(L.text("Trackers"), value: "\(b.trackers.count)")
                        LabeledContent(L.text("Records"), value: "\(b.trackers.flatMap(\.entries).count)")
                        LabeledContent(L.text("Photos"), value: "\(b.trackers.flatMap(\.entries).flatMap(\.photos).count)")
                        Button(L.text("Replace data with this backup"), role: .destructive) { restoreConfirm = true }.accessibilityIdentifier("backup.restore")
                        Button(L.text("Cancel")) { pending = nil }
                    }
                }
                if store.trackers.contains(where: \.archived) {
                    Section(L.text("Archived")) {
                        ForEach(store.trackers.filter(\.archived)) { t in NavigationLink(t.name) { TrackerDetail(id: t.id) } }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section { Text(L.text("Private by default. Stored on this iPhone. No account or server.")).font(.footnote).foregroundStyle(TrackerColors.secondaryText) }
            }
            .navigationTitle(L.text("Settings"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L.text("Done")) { dismiss() }.accessibilityIdentifier("settings.done") } }
            .fileExporter(isPresented: $exporting, document: export, contentType: csv ? .commaSeparatedText : .json, defaultFilename: csv ? "goal-tracker-records" : "goal-tracker-backup") { result in
                if case .failure(let failure) = result { error = L.error(failure) }
                export = nil
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    guard (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 <= 100_000_000 else { throw DataError.tooLarge }
                    let b = try Backup.decode(Data(contentsOf: url))
                    pending = b; error = nil
                } catch { self.error = L.error(error) }
            }
            .confirmationDialog(L.text("Replace all current data? This cannot be undone."), isPresented: $restoreConfirm, titleVisibility: .visible) {
                Button(L.text("Replace data"), role: .destructive) {
                    do {
                        guard let pending else { return }
                        try store.restore(pending.encoded()); self.pending = nil
                        Task { do { try await Reminders.sync(store.trackers) } catch { self.error = L.error(error) } }
                    } catch { self.error = L.error(error) }
                }
            }
        }
    }
    private func prepare(csv: Bool) {
        do {
            let backup = Backup(trackers: store.trackers)
            self.csv = csv
            export = ExportDocument(data: csv ? Data(backup.csv().utf8) : try backup.encoded())
            exporting = true; error = nil
        } catch { self.error = L.error(error) }
    }
}

struct ReminderEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let tracker: Tracker
    @State private var enabled = false
    @State private var time = Date()
    @State private var weekdays = Set(1...7)
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        Form {
            Toggle(L.text("Enable reminders"), isOn: $enabled)
            if enabled {
                Section {
                DatePicker(L.text("Time"), selection: $time, displayedComponents: .hourAndMinute)
                ForEach(1...7, id: \.self) { day in
                    Toggle(L.locale.calendar.weekdaySymbols[day - 1], isOn: Binding(get: { weekdays.contains(day) }, set: { if $0 { weekdays.insert(day) } else { weekdays.remove(day) } }))
                }
                } footer: {
                    Text(L.text("Deadline goals also get a reminder on their due date.")).font(.caption).foregroundStyle(TrackerColors.secondaryText)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle(tracker.name)
            .toolbar { Button(L.text("Save")) {
                Task {
                    busy = true; defer { busy = false }
                    do {
                        if enabled {
                            guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) else { error = L.text("Notifications are disabled. You can enable them in iPhone Settings."); return }
                        }
                        var t = store.trackers.first { $0.id == tracker.id } ?? tracker
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
                        t.reminder = enabled ? Reminder(hour: parts.hour!, minute: parts.minute!, weekdays: weekdays.sorted()) : nil
                        let candidate = store.trackers.map { $0.id == t.id ? t : $0 }
                        _ = try Reminders.requests(candidate)
                        try store.save(t); try await Reminders.sync(store.trackers); dismiss()
                    } catch { self.error = L.error(error) }
                }
            }.disabled(busy || (enabled && weekdays.isEmpty)) }
            .onAppear {
                if let r = tracker.reminder {
                    enabled = true; weekdays = Set(r.weekdays)
                    time = Calendar.current.date(bySettingHour: r.hour, minute: r.minute, second: 0, of: Date())!
                }
            }
    }
}

@MainActor enum Reminders {
    static func requests(_ trackers: [Tracker], now: Date = Date()) throws -> [UNNotificationRequest] {
        var result: [UNNotificationRequest] = []
        for t in trackers where !t.archived {
            guard let r = t.reminder else { continue }
            for day in r.weekdays {
                var parts = DateComponents(); parts.timeZone = t.calendar.timeZone; parts.weekday = day; parts.hour = r.hour; parts.minute = r.minute
                let content = UNMutableNotificationContent(); content.title = t.name; content.body = L.text(t.kind == .daily ? "A moment to record your day." : "Any progress to capture?"); content.sound = .default
                result.append(UNNotificationRequest(identifier: t.id.uuidString + ".\(day)", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)))
            }
            if let rule = t.rule(at: now), let due = rule.deadline, !t.achieved(rule) {
                var parts = t.calendar.dateComponents([.year, .month, .day], from: due)
                parts.timeZone = t.calendar.timeZone; parts.hour = r.hour; parts.minute = r.minute
                if let date = t.calendar.date(from: parts), date > now {
                    let content = UNMutableNotificationContent(); content.title = t.name; content.body = L.text("Your goal's deadline is today."); content.sound = .default
                    result.append(UNNotificationRequest(identifier: t.id.uuidString + ".deadline", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
                }
            }
        }
        guard result.count <= 60 else { throw DataError.tooManyReminders }
        return result
    }
    static func sync(_ trackers: [Tracker]) async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        try Task.checkCancellation()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let planned = try requests(trackers)
        let old = await center.pendingNotificationRequests()
        for request in planned { try Task.checkCancellation(); try await center.add(request) }
        try Task.checkCancellation()
        let identifiers = Set(planned.map(\.identifier))
        center.removePendingNotificationRequests(withIdentifiers: old.filter { !identifiers.contains($0.identifier) }.map(\.identifier))
    }
}
