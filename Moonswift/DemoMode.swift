#if DEBUG
import SwiftData
import SwiftUI

/// Debug builds started with the `-MoonswiftDemo` launch argument (and Xcode's previews, always) show a pretend PC
/// with sample games, so the layout can be seen without pairing a real PC. Nothing here ships in release builds.
enum DemoMode {
    /// `-MoonswiftFirstRun`: the app as on a fresh install, with a Mock PC to find and pair, to walk through setup on a
    /// device that already has hosts. Hosts, settings, the artwork key and game customizations are left untouched.
    nonisolated static let isFirstRun = ProcessInfo.processInfo.arguments.contains("-MoonswiftFirstRun")
    static let isOn = isFirstRun || ProcessInfo.processInfo.arguments.contains("-MoonswiftDemo")
        || ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    static let pcID = "demo-pc"
    /// A documentation-only address, so nothing real can ever answer it.
    static let mockAddress = "192.0.2.20"

    /// Where the walkthrough's choices go: a store of its own, emptied each launch.
    static let settings: UserDefaults = {
        guard isFirstRun, let store = UserDefaults(suiteName: "MoonswiftFirstRun") else { return .standard }
        store.removePersistentDomain(forName: "MoonswiftFirstRun")
        return store
    }()

    /// Made up, because App Store screenshots come from this list and real titles are other people's trademarks.
    static let titles = ["Copper Comet Courier", "Velvet Orbit Rally", "Paper Lantern Postman", "Glasswing Depths",
                         "Marble Tide Racers", "Pocket Observatory", "Saffron Skyway", "Thimble Kingdoms",
                         "Tiny Harbor Tactics", "Moss Knight Almanac", "Desktop"]

    static var apps: [HostApp] {
        titles.enumerated().compactMap { HostApp(fields: ["ID": "\($0.offset + 1)", "AppTitle": $0.element, "UUID": "demo-\($0.offset)"]) }
    }

    /// A pretend paired PC, in a container that's never saved to disk.
    static func container() -> ModelContainer {
        let container = try! ModelContainer(for: SavedHost.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        if !isFirstRun {
            container.mainContext.insert(SavedHost(uniqueID: pcID, name: "Gaming PC", address: "192.168.1.20",
                                                   serverCert: Data([1])))
        }
        return container
    }

    /// Recently played, favourites and a running game, for the rows to have something to show.
    static func seed(_ catalog: GameCatalog, _ directory: PCDirectory, running: Int = 1) {
        var history = GameHistory()
        for (index, app) in apps.prefix(5).enumerated() { history.lastPlayed[GameHistory.key(app)] = .now.addingTimeInterval(Double(-index) * 9000) }
        for app in apps where [2, 5, 7].contains(app.id) { history.favorites.insert(GameHistory.key(app)) }
        catalog.demoApps(apps, history: history, pcID: pcID)
        directory.setDemo(pcID: pcID, running: running)
    }
}

#endif
