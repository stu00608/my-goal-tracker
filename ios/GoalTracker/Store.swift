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
            config = ModelConfiguration(cloudKitDatabase: .none)
        }
        container = try ModelContainer(for: Ledger.self, configurations: config)
        context = ModelContext(container); context.autosaveEnabled = false
        if let existing = try context.fetch(FetchDescriptor<Ledger>()).first {
            row = existing; trackers = try Backup.decode(existing.payload).trackers
        } else {
            row = Ledger(payload: try Backup(trackers: []).encoded())
            context.insert(row); try context.save(); trackers = []
        }
    }
    func replace(_ candidate: [Tracker]) throws {
        let data = try Backup(trackers: candidate).encoded()
        // ponytail: one atomic SwiftData document, 100 MB backup ceiling; split into rows if measured saves become slow.
        row.payload = data
        do { try context.save() } catch { context.rollback(); throw error }
        trackers = candidate
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
