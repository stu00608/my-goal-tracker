import SwiftUI
import UniformTypeIdentifiers

struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

nonisolated struct ExportNameGenerator {
    private var lastMillisecond: Int64?
    mutating func next(csv: Bool, now: Date = Date()) -> String {
        let measured = Int64(floor(now.timeIntervalSince1970 * 1000))
        let instant = max(measured, lastMillisecond.map { $0 + 1 } ?? measured)
        lastMillisecond = instant
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return (csv ? "Goalooker-export-" : "Goalooker-backup-") + formatter.string(from: Date(timeIntervalSince1970: Double(instant) / 1000))
    }
}

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("language") private var language = "system"
    @AppStorage("homeLayout") private var homeLayout = "grid"
    @AppStorage("recordLocationByDefault", store: L.defaults) private var recordLocationByDefault = false
    @AppStorage("numericInputMode", store: L.defaults) private var numericInputMode = NumericEntryMode.direct.rawValue
    @AppStorage("remindersEnabled", store: L.defaults) private var remindersEnabled = true
    @State private var syncingReminders = false
    @State private var exportNames = ExportNameGenerator()
    @State private var exportFilename = ""
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
                    Toggle(L.text("Enable reminders"), isOn: $remindersEnabled)
                        .disabled(syncingReminders).accessibilityIdentifier("settings.remindersEnabled")
                } header: { Text(L.text("Reminders")) } footer: {
                    Text(L.text("Controls time and location reminders for all goals. Configure each reminder in its goal. Delivery follows your iPhone settings."))
                        .font(.caption).foregroundStyle(TrackerColors.secondaryText)
                }
                Section {
                    LabeledContent(L.text("Trackers"), value: "\(store.trackers.count)")
                    LabeledContent(L.text("Records"), value: "\(store.trackers.flatMap(\.entries).count)")
                    LabeledContent(L.text("Photo storage"), value: ByteCountFormatter.string(fromByteCount: Int64(allPhotos(store.trackers).reduce(0) { $0 + $1.count }), countStyle: .file))
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
                        LabeledContent(L.text("Photos"), value: "\(allPhotos(b.trackers).count)")
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
                Section(L.text("About")) {
                    Text(L.text("Goalooker - 過路客")).font(.headline)
                    Text(L.text("Small daily steps leave a visible trace. Explore your own orbit, one record at a time."))
                        .font(.footnote).foregroundStyle(TrackerColors.secondaryText)
                }
            }
            .navigationTitle(L.text("Settings"))
            .onChange(of: remindersEnabled) { _, enabled in
                Task {
                    syncingReminders = true; defer { syncingReminders = false }
                    do { try await Reminders.sync(store.trackers, requestPermission: enabled); error = nil }
                    catch { self.error = L.error(error) }
                }
            }
            .fileExporter(isPresented: $exporting, document: export, contentType: csv ? .commaSeparatedText : .json, defaultFilename: exportFilename) { result in
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
    private func allPhotos(_ trackers: [Tracker]) -> [Data] {
        trackers.flatMap { ($0.photos ?? []) + $0.entries.flatMap(\.photos) }
    }
    private func prepare(csv: Bool) {
        do {
            let backup = Backup(trackers: store.trackers)
            self.csv = csv
            export = ExportDocument(data: csv ? Data(backup.csv().utf8) : try backup.encoded())
            exportFilename = exportNames.next(csv: csv)
            exporting = true; error = nil
        } catch { self.error = L.error(error) }
    }
}
