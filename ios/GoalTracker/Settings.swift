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
    let now: Date
    @Environment(AppStore.self) private var store
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("language") private var language = "system"
    @AppStorage("homeLayout") private var homeLayout = "grid"
    @AppStorage("recordLocationByDefault", store: L.defaults) private var recordLocationByDefault = false
    @AppStorage("numericInputMode", store: L.defaults) private var numericInputMode = NumericEntryMode.direct.rawValue
    @AppStorage("remindersEnabled", store: L.defaults) private var remindersEnabled = true
    @AppStorage("firstWeekday", store: L.defaults) private var firstWeekday = 1
    @State private var healthSettings = false
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
                Section(L.text("Appearance")) {
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
                }
                Section {
                    Picker(L.text("Default value input"), selection: $numericInputMode) {
                        Text(L.text("New value")).tag(NumericEntryMode.direct.rawValue)
                        Text(L.text("Change amount")).tag(NumericEntryMode.change.rawValue)
                    }.accessibilityIdentifier("settings.numericInputMode")
                    Picker(L.text("First day of week"), selection: $firstWeekday) {
                        Text(L.text("Sunday")).tag(1)
                        Text(L.text("Monday")).tag(2)
                    }.accessibilityIdentifier("settings.firstWeekday")
                    Toggle(L.text("Record location by default"), isOn: $recordLocationByDefault)
                        .accessibilityIdentifier("settings.recordLocationDefault")
                } header: { Text(L.text("Recording")) } footer: {
                    Text(L.text("Applies to new records only. You can change it for each record. Location is requested when you save."))
                }
                Section {
                    Button { healthSettings = true } label: {
                        HStack {
                            Label(L.text("Apple Health"), systemImage: "heart.fill").foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }.frame(minHeight: 44)
                    }.accessibilityIdentifier("settings.health")
                }
                Section {
                    Toggle(L.text("Enable reminders"), isOn: $remindersEnabled)
                        .disabled(syncingReminders).accessibilityIdentifier("settings.remindersEnabled")
                } header: { Text(L.text("Reminders")) } footer: {
                    Text(L.text("Controls time and location reminders for all goals. Configure each reminder in its goal. Delivery follows your iPhone settings."))
                }
                Section {
                    LabeledContent(L.text("Trackers"), value: store.trackers.count.formatted(.number.locale(L.locale))).monospacedDigit()
                    LabeledContent(L.text("Records"), value: store.trackers.flatMap(\.entries).count.formatted(.number.locale(L.locale))).monospacedDigit()
                    LabeledContent(L.text("Photo storage"), value: ByteCountFormatter.string(fromByteCount: Int64(allPhotos(store.trackers).reduce(0) { $0 + $1.count }), countStyle: .file))
                } header: { Text(L.text("Your data")) }
                Section {
                    Button(L.text("Export full backup")) { prepare(csv: false) }.accessibilityIdentifier("backup.export")
                    Button(L.text("Export CSV")) { prepare(csv: true) }.accessibilityIdentifier("csv.export")
                    Button(L.text("Restore backup"), role: .destructive) { importing = true }.accessibilityIdentifier("backup.import")
                } footer: {
                    Text(L.text("A full backup includes records, goal history and photos. Keep a copy somewhere safe. Backups are not encrypted."))
                }
                if store.trackers.contains(where: \.archived) {
                    Section(L.text("Archived")) {
                        ForEach(store.trackers.filter(\.archived)) { t in NavigationLink(t.name) { TrackerDetail(id: t.id, now: now) } }
                    }
                }
                Section(L.text("About")) {
                    LabeledContent(L.text("App"), value: L.text("Goalooker - 過路客"))
                    LabeledContent(L.text("Version"), value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1") + ")")
                }
            }
            .statusToast(message: $error, identifier: "settings.error", autoDismiss: false)
            .sensoryFeedback(.error, trigger: error) { _, error in error != nil }
            .navigationTitle(L.text("Settings"))
            .sheet(isPresented: $healthSettings) { HealthSettingsSheet() }
            #if DEBUG && targetEnvironment(simulator)
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("--uitesting") && ProcessInfo.processInfo.arguments.contains("--backup-confirmation-fixture") {
                    pending = Backup(trackers: store.trackers)
                    restoreConfirm = true
                }
            }
            #endif
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
                    pending = b; error = nil; restoreConfirm = true
                } catch { self.error = L.error(error) }
            }
            .confirmationDialog(L.text("Replace all current data? This cannot be undone."), isPresented: $restoreConfirm, titleVisibility: .visible) {
                Button(L.text("Replace data"), role: .destructive) {
                    do {
                        guard let pending else { return }
                        try store.restore(pending.encoded()); self.pending = nil
                        Task { do { try await Reminders.sync(store.trackers) } catch { self.error = L.error(error) } }
                    } catch { self.error = L.error(error) }
                }.accessibilityIdentifier("backup.restore")
                Button(L.text("Cancel"), role: .cancel) { pending = nil }
            } message: {
                if let pending {
                    let counts = [("Trackers", pending.trackers.count), ("Records", pending.trackers.flatMap(\.entries).count), ("Photos", allPhotos(pending.trackers).count)]
                    Text(counts.map { L.text($0.0) + " · " + $0.1.formatted(.number.locale(L.locale)) }.joined(separator: "\n"))
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
