#if DEBUG
import SwiftData
import SwiftUI

/// Debug builds started with the `-MoonswiftDemo` launch argument show a pretend PC with sample games, so the layout
/// can be seen in the simulator without pairing a real PC. Nothing here ships in release builds.
enum DemoMode {
    static let isOn = ProcessInfo.processInfo.arguments.contains("-MoonswiftDemo")
    static let pcID = "demo-pc"

    static let titles = ["Hades II", "Elden Ring", "Cyberpunk 2077", "Hollow Knight: Silksong", "Forza Horizon 5",
                         "Baldur's Gate 3", "Celeste", "Stardew Valley", "Red Dead Redemption 2", "Balatro",
                         "Desktop", "Steam Big Picture"]

    static var apps: [HostApp] {
        titles.enumerated().compactMap { HostApp(fields: ["ID": "\($0.offset + 1)", "AppTitle": $0.element, "UUID": "demo-\($0.offset)"]) }
    }

    /// A pretend paired PC, in a container that's never saved to disk.
    static func container() -> ModelContainer {
        let container = try! ModelContainer(for: SavedHost.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.insert(SavedHost(uniqueID: pcID, name: "Ivan's PC", address: "192.168.1.20",
                                               serverCert: Data([1])))
        return container
    }

    /// Recently played, favourites and a running game, for the rows to have something to show.
    static func seed(_ catalog: GameCatalog, _ directory: PCDirectory) {
        var history = GameHistory()
        for (index, app) in apps.prefix(5).enumerated() { history.lastPlayed[GameHistory.key(app)] = .now.addingTimeInterval(Double(-index) * 9000) }
        for app in apps where [2, 5, 7].contains(app.id) { history.favorites.insert(GameHistory.key(app)) }
        catalog.demoApps(apps, history: history, pcID: pcID)
        directory.setDemo(pcID: pcID, running: 1)
    }
}

#endif
