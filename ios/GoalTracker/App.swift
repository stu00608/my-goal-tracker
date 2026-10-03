import SwiftUI

nonisolated enum L {
    static var defaults: UserDefaults {
        if ProcessInfo.processInfo.arguments.contains("--uitesting") { return UserDefaults(suiteName: "GoalTrackerUITests")! }
        return .standard
    }
    static var language: String {
        let chosen = defaults.string(forKey: "language") ?? "system"
        if chosen != "system" { return chosen }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("ja") ? "ja" : preferred.hasPrefix("zh") ? "zh-Hant" : "en"
    }
    static var locale: Locale { Locale(identifier: language) }
    static func text(_ key: String) -> String {
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
    static func error(_ error: Error) -> String {
        switch error {
        case DataError.invalidNumber: text("Enter a number with at most 28 digits, without grouping separators.")
        case DataError.invalidBackup, DataError.unsupportedVersion: text("This backup is damaged or uses an unsupported format. Your data was kept.")
        case DataError.duplicateDay: text("This date already has a record. Edit that record instead.")
        case DataError.tooManyReminders: text("Too many reminders. Choose fewer weekdays or trackers.")
        case DataError.tooLarge: text("The backup exceeds the 100 MB limit.")
        case DataError.photoFailed: text("Could not read this photo. Try a different image.")
        default: text("Could not complete this action. Your saved data was kept. Please try again.")
        }
    }
}

@main struct GoalTrackerApp: App {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("language") private var language = "system"
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: AppStore?
    @State private var loadError: String?
    init() {
        do {
            var url: URL?
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--uitesting") {
                let args = ProcessInfo.processInfo.arguments
                for key in ["language", "appearance"] {
                    if let index = args.firstIndex(of: "-" + key), args.indices.contains(index + 1) { L.defaults.set(args[index + 1], forKey: key) }
                }
                let directory = URL.applicationSupportDirectory.appendingPathComponent("UITests", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                url = directory.appendingPathComponent("test.store")
            }
            #endif
            let loaded = try AppStore(url: url)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--reset-test-store") && url != nil { try loaded.replace([]) }
            #endif
            loaded.refreshWidget()
            _store = State(initialValue: loaded)
        } catch { _loadError = State(initialValue: L.error(error)) }
    }
    var body: some Scene {
        WindowGroup {
            Group {
                if let store { RootView().environment(store).id(language) }
                else { ContentUnavailableView(L.text("Could not open your data"), systemImage: "externaldrive.badge.exclamationmark", description: Text(loadError ?? "")) }
            }
            .defaultAppStorage(L.defaults)
            .environment(\.locale, L.locale)
            .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
            .tint(.teal)
            .onChange(of: language) { store?.refreshWidget() }
            .onChange(of: scenePhase) { if scenePhase == .active { store?.refreshWidget() } }
        }
    }
}
