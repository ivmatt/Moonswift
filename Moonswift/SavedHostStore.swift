import Foundation
import os
import SwiftData

/// Opens the saved hosts without ever crashing the app or deleting what's on disk.
enum SavedHostStore {
    /// Set at launch when the saved hosts couldn't be opened, so RootView can say so once.
    @MainActor static var wasRecovered = false

    /// SwiftData's own default location, which earlier versions used.
    static let defaultURL = URL.applicationSupportDirectory.appending(path: "default.store")

    /// Opens the store at `url`. If it won't open (an update SwiftData can't carry over, or a damaged file), its files
    /// are moved into an "unreadable-<time>" folder beside it and a new store starts; if even that fails, the hosts
    /// live in memory for this run. `recovered` is true in both cases: the hosts need adding again.
    static func open(at url: URL) -> (container: ModelContainer, recovered: Bool) {
        let log = Logger(subsystem: "Moonswift", category: "SavedHostStore")
        do {
            return (try ModelContainer(for: SavedHost.self, configurations: ModelConfiguration(url: url)), false)
        } catch {
            log.error("Can't open the saved hosts, moving them aside: \(error)")
        }
        let folder = url.deletingLastPathComponent()
        let aside = folder.appending(path: "unreadable-\(Int(Date.now.timeIntervalSince1970))")
        try? FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        for suffix in ["", "-shm", "-wal"] { // SQLite's store and its two side files
            let name = url.lastPathComponent + suffix
            try? FileManager.default.moveItem(at: folder.appending(path: name), to: aside.appending(path: name))
        }
        do {
            return (try ModelContainer(for: SavedHost.self, configurations: ModelConfiguration(url: url)), true)
        } catch {
            log.error("Can't start new saved hosts either, keeping them in memory: \(error)")
        }
        // An in-memory store can't fail to open short of the model itself being broken, which tests would catch.
        let memory = try! ModelContainer(for: SavedHost.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return (memory, true)
    }
}
