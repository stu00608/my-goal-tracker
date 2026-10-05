import SwiftData
import SwiftUI
import UIKit

@Model final class Ledger {
    @Attribute(.externalStorage) var payload: Data
    init(payload: Data) { self.payload = payload }
}

@MainActor @Observable final class AppStore {
    private let container: ModelContainer
    private let context: ModelContext
    private let row: Ledger
    private(set) var trackers: [Tracker]
    var error: String?

    init(url: URL? = nil) throws {
        let config: ModelConfiguration
        if let url { config = ModelConfiguration(url: url, cloudKitDatabase: .none) }
        else {
            try FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
            config = ModelConfiguration(groupContainer: .none, cloudKitDatabase: .none)
        }
        container = try ModelContainer(for: Ledger.self, configurations: config)
        context = ModelContext(container); context.autosaveEnabled = false
        if let existing = try context.fetch(FetchDescriptor<Ledger>()).first {
            let decoded = try Backup.decode(existing.payload)
            if decoded.version < 3 {
                let directory = url?.deletingLastPathComponent() ?? URL.applicationSupportDirectory
                let safetyCopy = directory.appendingPathComponent("Ledger-v2-premigration.json")
                if !FileManager.default.fileExists(atPath: safetyCopy.path) {
                    try existing.payload.write(to: safetyCopy, options: [.atomic, .completeFileProtection])
                }
            }
            row = existing; trackers = decoded.trackers
        } else {
            row = Ledger(payload: try Backup(trackers: []).encoded())
            context.insert(row); try context.save(); trackers = []
        }
    }
    func replace(_ supplied: [Tracker]) throws {
        // Reject ambiguous dual schemas before normalization, then preserve legacy semantics in v3 keys.
        try Backup(trackers: supplied).validate()
        let candidate = supplied.map { tracker in var copy = tracker; copy.migrateConditions(); return copy }
        // Validate raw events, derived overflow and metadata before touching the persisted document.
        let data = try Backup(trackers: candidate).encoded()
        // Validate the whole active configuration on every entry path, including unarchive and restore.
        // This is pure preflight: no permission request or monitor mutation, even when reminders are OFF.
        try Reminders.validate(candidate)
        // ponytail: one atomic SwiftData document, 100 MB backup ceiling; split into rows if measured saves become slow.
        row.payload = data
        do { try context.save() } catch { context.rollback(); throw error }
        trackers = candidate
        refreshWidget()
    }
    func refreshWidget() {
        #if WIDGETS
        // Test stores must never replace the user's home-screen summary.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--uitesting") {
            #if DEBUG && targetEnvironment(simulator)
            guard args.contains("--widgettesting") else { return }
            #else
            return
            #endif
        }
        do { try WidgetSnapshot.publish(trackers) }
        catch { self.error = L.text("Your records are saved, but the widget could not be updated. Open the app to try again.") }
        #endif
    }
    func save(_ tracker: Tracker) throws {
        var next = trackers
        if let index = next.firstIndex(where: { $0.id == tracker.id }) { next[index] = tracker }
        else { next.append(tracker) }
        try replace(next)
    }
    func remove(_ id: UUID) throws { try replace(trackers.filter { $0.id != id }) }
    func perform(_ action: () throws -> Void) {
        do { try action() } catch { self.error = L.error(error) }
    }
    func restore(_ data: Data) throws {
        let b = try Backup.decode(data)
        try replace(b.trackers)
    }
}
