import SwiftUI

/// One game across all PCs: the same title on two PCs is one entry with two sources.
nonisolated struct CatalogGame: Identifiable, Hashable {
    struct Source: Hashable {
        let pcID: String
        let app: HostApp
    }

    /// The PC's title, lowercased: the same however the game is renamed here.
    let id: String
    /// What Moonswift shows: your nickname for it, else the PC's title.
    let title: String
    let originalTitle: String
    let sources: [Source]
    /// Desktop, Steam Big Picture and the like: launchers and tools, not games.
    let isApp: Bool
    let isFavorite: Bool
    let lastPlayed: Date?

    static let appTitles: Set<String> = ["desktop", "steam big picture", "steam", "remote monitor", "remote input",
                                         "playnite", "playnite fullscreen", "virtual desktop"]
}

/// Every PC's games, kept on this device so Home and Library show them at once (and while a PC is offline), and
/// refreshed from each PC while it's up. Favorites and last-played times come from each PC's GameHistory.
@Observable final class GameCatalog {
    private(set) var apps: [String: [HostApp]] = [:] { didSet { gamesCache = [:] } } // by PC, as last seen
    private(set) var histories: [String: GameHistory] = [:] { didSet { gamesCache = [:] } } // by PC
    /// Your own name and pictures for a game, by game ID. Only how Moonswift shows it; the PC's list is untouched.
    private(set) var nicknames: [String: String] = [:] { didSet { gamesCache = [:] } }
    /// `games(on:)` by its PCs, until a list, history or nickname changes: Home reads it many times a redraw.
    @ObservationIgnored private var gamesCache: [[String]: [CatalogGame]] = [:]
    /// Seconds the launch splash stays past the first picture, for games that need more (or less) than the default.
    private(set) var splashWaits: [String: Int] = [:]
    /// The on-screen controller layout last used with each game, by game ID.
    private(set) var padLayouts: [String: String] = [:]
    /// Your pictures by kind, then game ID: a hero, and a cover for each cover shape.
    private(set) var artwork: [Artwork: [String: UIImage]] = [:]
    /// The file-name part of each kind; "cover" is the 2:3 cover (the only cover there was at first).
    enum Artwork: String, CaseIterable {
        case hero, cover, cover34, coverSquare

        static func cover(_ shape: CoverShape) -> Artwork {
            switch shape {
            case .tall: .cover
            case .classic: .cover34
            case .square: .coverSquare
            }
        }
    }

    var heroArt: [String: UIImage] { artwork[.hero] ?? [:] }

    /// Your cover for this shape; nil falls back to the PC's art.
    func cover(for gameID: String, _ shape: CoverShape) -> UIImage? { artwork[.cover(shape)]?[gameID] }
    @ObservationIgnored private var lastRefresh: [String: Date] = [:]
    /// PCs whose game list is being fetched now, and those whose last fetch failed (their saved list shows).
    private(set) var fetching: Set<String> = []
    private(set) var fetchFailed: Set<String> = []

    init() {
        let folder = Self.folder
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            guard let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([HostApp].self, from: data) else { continue }
            let id = file.deletingPathExtension().lastPathComponent
            apps[id] = list
            histories[id] = GameHistory.load(hostID: id)
        }
        let custom = Self.customFolder
        if let data = try? Data(contentsOf: custom.appending(path: "nicknames.json")) {
            nicknames = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        if let data = try? Data(contentsOf: custom.appending(path: "splashWaits.json")) {
            splashWaits = (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
        }
        if let data = try? Data(contentsOf: custom.appending(path: "padLayouts.json")) {
            padLayouts = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        for file in (try? FileManager.default.contentsOfDirectory(at: custom, includingPropertiesForKeys: nil)) ?? [] {
            // "<base64 game ID>.<kind>.jpg"
            let parts = file.deletingPathExtension().lastPathComponent.split(separator: ".")
            guard parts.count == 2, let kind = Artwork(rawValue: String(parts[1])),
                  let id = Self.gameID(fromFileKey: String(parts[0])), let image = UIImage(contentsOfFile: file.path) else { continue }
            artwork[kind, default: [:]][id] = image
        }
    }

    private static var customFolder: URL {
        let url = URL.applicationSupportDirectory.appending(path: "Customizations", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Game IDs are titles, which can hold "/" and the like: file names use them in URL-safe base64.
    nonisolated static func fileKey(gameID: String) -> String {
        Data(gameID.utf8).base64EncodedString().replacing("/", with: "_").replacing("+", with: "-")
    }

    nonisolated static func gameID(fromFileKey key: String) -> String? {
        Data(base64Encoded: key.replacing("_", with: "/").replacing("-", with: "+")).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// An empty or unchanged name removes the nickname.
    func setNickname(_ name: String, for game: CatalogGame) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        nicknames[game.id] = name.isEmpty || name == game.originalTitle ? nil : name
        try? JSONEncoder().encode(nicknames).write(to: Self.customFolder.appending(path: "nicknames.json"), options: .atomic)
    }

    /// nil: the default from Settings.
    func setSplashWait(_ seconds: Int?, for game: CatalogGame) {
        splashWaits[game.id] = seconds
        try? JSONEncoder().encode(splashWaits).write(to: Self.customFolder.appending(path: "splashWaits.json"), options: .atomic)
    }

    /// The game (by its host's title) uses this on-screen controller layout from now on.
    func setPadLayout(_ layoutID: String, forTitle title: String) {
        padLayouts[title.lowercased()] = layoutID
        try? JSONEncoder().encode(padLayouts).write(to: Self.customFolder.appending(path: "padLayouts.json"), options: .atomic)
    }

    /// Saves a picture you picked (scaled down to what the screen needs), or removes it with nil.
    func setArtwork(_ image: UIImage?, _ kind: Artwork, for game: CatalogGame) {
        let file = Self.customFolder.appending(path: "\(Self.fileKey(gameID: game.id)).\(kind.rawValue).jpg")
        let longest: CGFloat = kind == .hero ? 2400 : 900
        let scaled = image.map { image in
            let scale = min(1, longest / max(image.size.width, image.size.height))
            return image.preparingThumbnail(of: CGSize(width: image.size.width * scale, height: image.size.height * scale)) ?? image
        }
        if let scaled, let data = scaled.jpegData(compressionQuality: 0.85) {
            try? data.write(to: file)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
        artwork[kind, default: [:]][game.id] = scaled
    }

    /// Back to the PC's name and art.
    func resetCustomizations(for game: CatalogGame) {
        setNickname("", for: game)
        for kind in Artwork.allCases { setArtwork(nil, kind, for: game) }
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
        fetching.insert(pc.id)
        defer { fetching.remove(pc.id) }
        for attempt in 1...2 {
            if let list = try? await pc.client.apps() {
                if apps[pc.id] != list {
                    apps[pc.id] = list
                    try? JSONEncoder().encode(list).write(to: Self.folder.appending(path: "\(pc.id).json"), options: .atomic)
                }
                histories[pc.id] = GameHistory.load(hostID: pc.id)
                fetchFailed.remove(pc.id)
                return
            }
            if attempt == 1 { try? await Task.sleep(for: .milliseconds(500)) }
        }
        fetchFailed.insert(pc.id)
    }

    func forget(_ pcID: String) {
        apps[pcID] = nil
        try? FileManager.default.removeItem(at: Self.folder.appending(path: "\(pcID).json"))
    }

    /// All games of the saved PCs, one entry per title, newest played first, then by name.
    func games(on pcIDs: [String]) -> [CatalogGame] {
        _ = (apps, histories, nicknames) // read even when cached, so views still follow their changes
        if let cached = gamesCache[pcIDs] { return cached }
        let games = buildGames(on: pcIDs)
        gamesCache[pcIDs] = games
        return games
    }

    private func buildGames(on pcIDs: [String]) -> [CatalogGame] {
        var byTitle: [String: [CatalogGame.Source]] = [:]
        for id in pcIDs {
            // The session controls that come and go (Resume, Terminate…) aren't games: Home shows them as a banner.
            for app in apps[id] ?? [] where app.sessionControl?.isContextual != true {
                byTitle[app.title.lowercased(), default: []].append(.init(pcID: id, app: app))
            }
        }
        return byTitle.values.map { sources in
            let history = sources.map { (histories[$0.pcID] ?? GameHistory(), GameHistory.key($0.app)) }
            let original = sources[0].app.title, id = original.lowercased()
            return CatalogGame(id: id, title: nicknames[id] ?? original, originalTitle: original, sources: sources,
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

    /// The controls for a session on this host, when it offers them: Join (or Resume) and End for a session another
    /// device is streaming; Resume and Disconnect for this device's own Remote Monitor or Remote Input session, while
    /// which the host lists no games at all (Home showed "Loading Games" for good).
    func remoteSession(on pcID: String) -> RemoteSession? {
        let list = apps[pcID] ?? []
        let session = RemoteSession(join: list.first { $0.sessionControl == .join },
                                    end: list.first { $0.sessionControl == .end },
                                    disconnect: list.first { $0.sessionControl == .disconnectMonitor || $0.sessionControl == .disconnectInput })
        return session.join == nil && session.end == nil && session.disconnect == nil ? nil : session
    }

    struct RemoteSession {
        let join: HostApp?, end: HostApp?
        /// This device's own remote session: Disconnect Remote Monitor or Remote Input.
        let disconnect: HostApp?
        var isOwn: Bool { disconnect != nil }
        var kind: String { disconnect?.sessionControl == .disconnectInput ? "Remote Input" : "Remote Monitor" }
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


        func notePlayed(_ app: HostApp, on pcID: String) {
        var history = histories[pcID] ?? GameHistory.load(hostID: pcID)
        history.lastPlayed[GameHistory.key(app)] = .now
        history.save(hostID: pcID)
        histories[pcID] = history
    }
}

/// The shape of every game's cover, to suit the art: 2:3 like Steam's 600×900 box art, 3:4 like GameStream's, or
/// square. Settings → Library.
nonisolated enum CoverShape: String, CaseIterable {
    case tall = "2:3", classic = "3:4", square = "Square"

    var ratio: CGFloat {
        switch self {
        case .tall: 2 / 3
        case .classic: 3 / 4
        case .square: 1
        }
    }
}

/// A game's box art: your own picture, else its PC's (kept on this device after the first download), else a
/// placeholder.
struct CoverArt: View {
    let app: HostApp
    let client: HostClient?
    var custom: UIImage? = nil
    /// The name to put on the placeholder: a nickname, if you gave one.
    var title: String? = nil
    @State private var image: UIImage?

    var body: some View {
        Rectangle().fill(.quaternary)
            .overlay {
                if let image = custom ?? image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    // No art (yet): a colour from the title, with the title on it.
                    // From the title's characters: hashValue changes every launch, and the colour shouldn't.
                    let hue = Double(app.title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
                    LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.55),
                                            Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.3)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay {
                            Text(title ?? app.title).font(.headline).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.9))
                                .minimumScaleFactor(0.5).padding(8)
                        }
                }
            }
            .clipped()
            // Per game as well as art version, so a view reused for another game never keeps the old one's art.
            .task(id: "\(app.uuid)|\(app.id)|\(app.artVersion)") {
                image = nil
                guard let client, let png = try? await client.boxArt(for: app) else { return }
                image = UIImage(data: png)
            }
    }
}
