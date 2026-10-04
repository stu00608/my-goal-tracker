import SwiftUI
import UIKit

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
        case let condition as ConditionError: text(condition.key)
        case DataError.invalidNumber: text("Enter a number with at most 28 digits, without grouping separators.")
        case DataError.invalidBackup, DataError.unsupportedVersion: text("This backup is damaged or uses an unsupported format. Your data was kept.")
        case DataError.duplicateDay: text("This date already has a record. Edit that record instead.")
        case DataError.tooManyReminders: text("Too many reminders. Choose fewer weekdays or trackers.")
        case DataError.tooLarge: text("The backup exceeds the 100 MB limit.")
        case DataError.tooManyPhotos: text("Each record can have up to 10 photos. Remove photos before saving.")
        case DataError.photoFailed: text("Could not read this photo. Try a different image.")
        default: text("Could not complete this action. Your saved data was kept. Please try again.")
        }
    }
}

@main struct GoalTrackerApp: App {
    @UIApplicationDelegateAdaptor(GoalookerAppDelegate.self) private var appDelegate
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
                for key in ["language", "appearance", "homeLayout"] {
                    if let index = args.firstIndex(of: "-" + key), args.indices.contains(index + 1) { L.defaults.set(args[index + 1], forKey: key) }
                }
                if args.contains("--reset-test-store") {
                    L.defaults.removeObject(forKey: "recordLocationByDefault")
                    L.defaults.removeObject(forKey: "numericInputMode")
                    L.defaults.removeObject(forKey: "remindersEnabled")
                }
                let directory = URL.applicationSupportDirectory.appendingPathComponent("UITests", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                url = directory.appendingPathComponent("test.store")
            }
            #endif
            let loaded = try AppStore(url: url)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--reset-test-store") && url != nil { try loaded.replace([]) }
            #if targetEnvironment(simulator)
            if url != nil, ProcessInfo.processInfo.arguments.contains("--feature-test-fixture"), loaded.trackers.isEmpty {
                let args = ProcessInfo.processInfo.arguments
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let colors: [UIColor] = args.contains("--ux-many-photos")
                    ? [.systemTeal, .systemOrange, .white, .black, .systemBlue, .systemPink, .systemPurple, .systemYellow, .systemGreen, .systemRed]
                    : args.contains("--ux-bright-photo") ? [.white, .black] : [.systemTeal, .systemOrange]
                let photos = colors.map { color in
                    UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240), format: format).image { context in
                        color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
                        UIColor.white.setStroke(); context.cgContext.setLineWidth(4)
                        context.cgContext.strokeEllipse(in: CGRect(x: 100, y: 60, width: 120, height: 120))
                    }.jpegData(compressionQuality: 0.8)!
                }
                let now = Date()
                var score = Tracker(name: "SCORE", kind: .number)
                for days in [365, 60, 7] {
                    let date = score.calendar.date(byAdding: .day, value: -days, to: now)!
                    let value = args.contains("--ux-extreme-fixture") && days == 7
                        ? "12345678901234567890.12345678" : days == 365 ? "16.5" : days == 60 ? "17.25" : "18.5"
                    score.put(Entry(occurredAt: date, localDay: score.day(date), value: value, note: "Synthetic snapshot", photos: photos, location: RecordedLocation(latitude: 35.68, longitude: 139.76)))
                }
                if args.contains("--ux-extreme-fixture") {
                    score.name = "SCORE — 長い目標名稱與精確數值"
                    score.unit = "points · 測定した数値の単位"
                    score.precision = 8
                }
                var cook = Tracker(name: "COOK", kind: .daily); cook.cardBackground = .photo
                cook.setFrequency(.weekly, target: 2, now: now)
                cook.put(Entry(occurredAt: now, localDay: cook.day(now), note: "Synthetic completion", photos: photos, location: RecordedLocation(latitude: 35.68, longitude: 139.76)))
                var travel = Tracker(name: "TRAVEL", kind: .number); travel.cardBackground = .map
                travel.put(Entry(occurredAt: now, localDay: travel.day(now), value: "1", location: RecordedLocation(latitude: 35.68, longitude: 139.76)))
                var fourth = Tracker(name: "EMPTY", kind: .number)
                if args.contains("--ux-widget-fourth") {
                    fourth.name = "VOLFORCE"
                    for (offset, value) in ["21.53", "21.533", "21.536"].enumerated() {
                        let date = now.addingTimeInterval(Double(offset - 3) * 86400)
                        fourth.put(Entry(occurredAt: date, localDay: fourth.day(date), value: value, photos: photos,
                                         location: RecordedLocation(latitude: 35.68 + Double(offset) * 0.01, longitude: 139.76)))
                    }
                }
                var fixture = [score, cook, travel, fourth]
                if args.contains("--ux-widget-duplicates") {
                    var duplicate = Tracker(name: fourth.name, kind: .number)
                    duplicate.put(Entry(occurredAt: now, localDay: duplicate.day(now), value: "22"))
                    fixture.append(duplicate)
                }
                if args.contains("--goalooker-test-fixture") {
                    score.description = "Small steps leave a visible trace."
                    score.website = "https://example.com"
                    score.photos = photos
                    score.axisLower = "0"; score.axisUpper = "25"
                    score.rules = [GoalRule(period: .deadline, target: "20", effectiveAt: now.addingTimeInterval(-90 * 86400), deadline: now.addingTimeInterval(30 * 86400))]
                    score.put(Entry(occurredAt: now.addingTimeInterval(-86400), localDay: score.day(now.addingTimeInterval(-86400)), change: "0.25", note: "Derived change"))
                    cook.photos = photos; cook.cardBackground = .trackerPhoto
                    var office = Tracker(name: "OFFICE", kind: .daily)
                    office.description = "Record only when either office condition is satisfied."
                    office.setFrequency(.weekly, target: 2, now: now)
                    office.conditions = [PlaceCondition(name: "Office A", location: RecordedLocation(latitude: 35.68, longitude: 139.76)), PlaceCondition(name: "Office B", location: RecordedLocation(latitude: 34.69, longitude: 135.5))]
                    office.conditionCombination = .any; office.gateSave = true
                    fixture = [score, cook, travel, fourth, office]
                    if args.contains("--goalooker-progress-fixture") { score.cardBackground = .progress; fixture[0] = score }
                }
                try loaded.replace(fixture)
            }
            #endif
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
            .tint(TrackerColors.accent)
            .onChange(of: language) { store?.refreshWidget() }
            .onChange(of: scenePhase) { if scenePhase == .active { store?.refreshWidget() } }
        }
    }
}
