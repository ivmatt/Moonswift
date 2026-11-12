import SwiftUI

/// One game across all PCs: the same title on two PCs is one entry with two sources.
nonisolated struct CatalogGame: Identifiable, Hashable {
    struct Source: Hashable {
        let pcID: String
        let app: HostApp
    }

    let title: String
    let sources: [Source]
    /// Desktop, Steam Big Picture and the like: launchers and tools, not games.
    let isApp: Bool
    let isFavorite: Bool
    let lastPlayed: Date?
    var id: String { title.lowercased() }

    static let appTitles: Set<String> = ["desktop", "steam big picture", "steam", "remote monitor", "remote input",
                                         "playnite", "playnite fullscreen", "virtual desktop"]
}

/// Every PC's games, kept on this device so Home and Library show them at once (and while a PC is offline), and
/// refreshed from each PC while it's up. Favorites and last-played times come from each PC's GameHistory.
@Observable final class GameCatalog {
    private(set) var apps: [String: [HostApp]] = [:] // by PC, as last seen
    private(set) var histories: [String: GameHistory] = [:] // by PC
    @ObservationIgnored private var lastRefresh: [String: Date] = [:]

    init() {
        let folder = Self.folder
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            guard let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([HostApp].self, from: data) else { continue }
            let id = file.deletingPathExtension().lastPathComponent
            apps[id] = list
            histories[id] = GameHistory.load(hostID: id)
        }
    }

    private static var folder: URL {
        let url = URL.applicationSupportDirectory.appending(path: "Catalog", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Fetches a PC's game list when it hasn't been for a while (or `force`), retrying once.
    func refresh(_ pc: PCRef, force: Bool = false) async {
        #if DEBUG
        if DemoMode.isOn { return }
        #endif
        if !force, let last = lastRefresh[pc.id], Date.now.timeIntervalSince(last) < 30 { return }
        lastRefresh[pc.id] = .now
        for attempt in 1...2 {
            if let list = try? await pc.client.apps() {
                if apps[pc.id] != list {
                    apps[pc.id] = list
                    try? JSONEncoder().encode(list).write(to: Self.folder.appending(path: "\(pc.id).json"))
                }
                histories[pc.id] = GameHistory.load(hostID: pc.id)
                return
            }
            if attempt == 1 { try? await Task.sleep(for: .milliseconds(500)) }
        }
    }

    func forget(_ pcID: String) {
        apps[pcID] = nil
        try? FileManager.default.removeItem(at: Self.folder.appending(path: "\(pcID).json"))
    }

    /// All games of the saved PCs, one entry per title, newest played first, then by name.
    func games(on pcIDs: [String]) -> [CatalogGame] {
        var byTitle: [String: [CatalogGame.Source]] = [:]
        for id in pcIDs {
            // The session controls that come and go (Resume, Terminate…) aren't games: Home shows them as a banner.
            for app in apps[id] ?? [] where app.sessionControl?.isContextual != true {
                byTitle[app.title.lowercased(), default: []].append(.init(pcID: id, app: app))
            }
        }
        return byTitle.values.map { sources in
            let history = sources.map { (histories[$0.pcID] ?? GameHistory(), GameHistory.key($0.app)) }
            return CatalogGame(title: sources[0].app.title, sources: sources,
                               isApp: sources[0].app.sessionControl != nil
                                   || CatalogGame.appTitles.contains(sources[0].app.title.lowercased()),
                               isFavorite: history.contains { $0.0.favorites.contains($0.1) },
                               lastPlayed: history.compactMap { $0.0.lastPlayed[$0.1] }.max())
        }
        .sorted { a, b in
            if a.lastPlayed != b.lastPlayed { return (a.lastPlayed ?? .distantPast) > (b.lastPlayed ?? .distantPast) }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    /// Join and End for a session another device is streaming on this PC, when the PC offers them.
    func remoteSession(on pcID: String) -> (join: HostApp?, end: HostApp?)? {
        let list = apps[pcID] ?? []
        let join = list.first { $0.sessionControl == .join }, end = list.first { $0.sessionControl == .end }
        return join == nil && end == nil ? nil : (join, end)
    }

    func title(of gameID: Int, on pcID: String) -> String? { apps[pcID]?.first { $0.id == gameID }?.title }

    func toggleFavorite(_ game: CatalogGame) {
        for source in game.sources {
            var history = histories[source.pcID] ?? GameHistory.load(hostID: source.pcID)
            let key = GameHistory.key(source.app)
            if game.isFavorite { history.favorites.remove(key) } else { history.favorites.insert(key) }
            history.save(hostID: source.pcID)
            histories[source.pcID] = history
        }
    }

    #if DEBUG
    func demoApps(_ list: [HostApp], history: GameHistory, pcID: String) {
        apps = [pcID: list]
        histories = [pcID: history]
        lastRefresh[pcID] = .distantFuture
    }
    #endif

    func reloadHistory(_ pcID: String) { histories[pcID] = GameHistory.load(hostID: pcID) }

        func notePlayed(_ app: HostApp, on pcID: String) {
        var history = histories[pcID] ?? GameHistory.load(hostID: pcID)
        history.lastPlayed[GameHistory.key(app)] = .now
        history.save(hostID: pcID)
        histories[pcID] = history
    }
}

/// A game's box art from its PC (kept on this device after the first download), or a placeholder.
struct CoverArt: View {
    let app: HostApp
    let client: HostClient?
    @State private var image: UIImage?

    var body: some View {
        Rectangle().fill(.quaternary)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    // No art (yet): a colour from the title, with the title on it.
                    let hue = Double(abs(app.title.hashValue % 360)) / 360
                    LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.55),
                                            Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.3)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay {
                            Text(app.title).font(.headline).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.9))
                                .minimumScaleFactor(0.5).padding(8)
                        }
                }
            }
            .clipped()
            .task(id: app.artVersion) {
                guard let client, let png = try? await client.boxArt(for: app) else { return }
                image = UIImage(data: png)
            }
    }
}

/// "Played 3h ago", "Never played".
nonisolated func playedText(_ date: Date?) -> String {
    guard let date else { return "Never played" }
    return "Played " + date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
}
