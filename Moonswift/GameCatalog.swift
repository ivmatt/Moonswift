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
    /// Hidden by you: left out of Home and Library, except Library's Hidden filter.
    let isHidden: Bool
    let isFavorite: Bool
    let lastPlayed: Date?

    static let appTitles: Set<String> = ["desktop", "steam big picture", "steam", "remote monitor", "remote input",
                                         "playnite", "playnite fullscreen", "virtual desktop"]

    /// Your choice in Show As wins; without one, session controls and the usual launcher titles are shortcuts.
    static func isShortcut(_ choice: ShowAs?, title: String, isSessionControl: Bool) -> Bool {
        switch choice {
        case .game: false
        case .shortcut: true
        case nil: isSessionControl || appTitles.contains(title.lowercased())
        }
    }
}

/// How a title is listed: with the games, or as a shortcut. No choice saved means Automatic.
nonisolated enum ShowAs: String, Codable, CaseIterable {
    case game, shortcut // shown as "App"; these names are saved in showAs.json, so renaming one would lose people's choices
}

/// Every PC's games, kept on this device so Home and Library show them at once (and while a PC is offline), and
/// refreshed from each PC while it's up. Favorites and last-played times come from each PC's GameHistory.
@Observable final class GameCatalog {
    private(set) var apps: [String: [HostApp]] = [:] { didSet { gamesCache = [:] } } // by PC, as last seen
    private(set) var histories: [String: GameHistory] = [:] { didSet { gamesCache = [:] } } // by PC
    /// Your own name and pictures for a game, by game ID. Only how Moonswift shows it; the PC's list is untouched.
    private(set) var nicknames: [String: String] = [:] { didSet { gamesCache = [:] } }
    /// Games you hid, and your Show As choices, by game ID.
    private(set) var hidden: Set<String> = [] { didSet { gamesCache = [:] } }
    private(set) var showAs: [String: ShowAs] = [:] { didSet { gamesCache = [:] } }
    /// `games(on:)` by its PCs, until a list, history or nickname changes: Home reads it many times a redraw.
    @ObservationIgnored private var gamesCache: [[String]: [CatalogGame]] = [:]
    /// Seconds the launch splash stays past the first picture, for games that need more (or less) than the default.
    private(set) var splashWaits: [String: Int] = [:]
    /// The on-screen controller layout last used with each game, by game ID.
    private(set) var padLayouts: [String: String] = [:]
    /// Your pictures by kind, then game ID: a hero, and a cover for each cover shape.
    private(set) var artwork: [Artwork: [String: UIImage]] = [:]
    /// The file-name part of each kind; "cover" is the 2:3 cover (the only cover there was at first).
    enum Artwork: String, CaseIterable, Codable {
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

    /// What a cover or Home's hero shows: your picture, else one found online (else, for a cover, the host's art).
    func shownCover(for gameID: String, _ shape: CoverShape) -> UIImage? {
        cover(for: gameID, shape) ?? found(.cover(shape), for: gameID)
    }
    func shownHero(for gameID: String) -> UIImage? { heroArt[gameID] ?? found(.hero, for: gameID) }

    // MARK: Art found online

    /// What SteamGridDB matched for a game, or when it found nothing (tried again after a week).
    struct FoundMatch: Codable {
        var gameID: Int?
        var name: String?
        var checked: Date
    }
    private(set) var foundMatches: [String: FoundMatch] = [:]
    /// Games whose found art you turned off (a wrong match).
    private(set) var onlineArtOff: Set<String> = []
    /// Which kinds of found art each game has on disk. Observed, so art appears as it arrives; the pictures themselves
    /// load on first look (a whole library's heroes in memory at once would be far too much).
    private(set) var foundKinds: [String: Set<Artwork>] = [:]
    @ObservationIgnored private let foundCache = NSCache<NSString, UIImage>()
    /// Bumped when found art is replaced by another of the same kind, which `foundKinds` doesn't show.
    private(set) var foundVersion = 0

    func found(_ kind: Artwork, for gameID: String) -> UIImage? {
        _ = foundVersion
        guard !onlineArtOff.contains(gameID), foundKinds[gameID]?.contains(kind) == true else { return nil }
        let file = foundFile(gameID, kind)
        if let image = foundCache.object(forKey: file.path as NSString) { return image }
        guard let image = UIImage(contentsOfFile: file.path) else { return nil }
        foundCache.setObject(image, forKey: file.path as NSString)
        return image
    }

    func setOnlineArt(_ isOn: Bool, for game: CatalogGame) {
        if isOn { onlineArtOff.remove(game.id) } else { onlineArtOff.insert(game.id) }
        saveSettings()
    }

    /// Looks up art for each game that hasn't been, one at a time. Stops at a rejected key; a network error leaves the
    /// game to try again next time.
    func findArtwork(for games: [CatalogGame], key: String) async {
        let api = SteamGridDB(key: key)
        for game in games where !game.isApp {
            if let match = foundMatches[game.id], match.gameID != nil || match.checked.timeIntervalSinceNow > -7 * 86_400 { continue }
            guard !Task.isCancelled else { return }
            do {
                guard let match = try await api.search(SteamGridDB.cleaned(game.originalTitle)) else {
                    saveMatch(FoundMatch(checked: .now), for: game.id)
                    continue
                }
                try await fetchFound(game.id, match: match, api: api)
            } catch SteamGridDB.Failure.unauthorized {
                return // a wrong key: nothing will work until it's changed
            } catch {
                continue
            }
        }
    }

    /// Each kind's picture for a match, saved as the game's found art; then the match itself. Steam's own store
    /// picture where there is one (a Steam game's 2:3 cover and hero), else SteamGridDB's top rated.
    private func fetchFound(_ gameID: String, match: SteamGridDB.Match, api: SteamGridDB) async throws {
        let steamAppID = try? await api.steamAppID(game: match.id)
        for kind in Artwork.allCases {
            if let appID = steamAppID, let url = SteamGridDB.steamPicture(kind, appID: appID),
               (try? await setFound(from: url, kind, for: gameID)) != nil { continue } // Steam may have none: a 404
            guard let url = try await api.imageURL(kind, game: match.id) else { continue }
            try? await setFound(from: url, kind, for: gameID)
        }
        saveMatch(FoundMatch(gameID: match.id, name: match.name, checked: .now), for: gameID)
    }

    /// The picker's "this is the right game": its art replaces what the wrong one brought.
    func rematch(_ game: CatalogGame, to match: SteamGridDB.Match, key: String) async throws {
        for kind in foundKinds[game.id] ?? [] {
            try? FileManager.default.removeItem(at: foundFile(game.id, kind))
            foundCache.removeObject(forKey: foundFile(game.id, kind).path as NSString)
        }
        foundKinds[game.id] = nil
        onlineArtOff.remove(game.id)
        try await fetchFound(game.id, match: match, api: SteamGridDB(key: key))
    }

    /// A picture picked (or the top-rated one), downloaded and saved as the game's found art of that kind.
    func setFound(from url: URL, _ kind: Artwork, for gameID: String) async throws {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data), let jpeg = Self.scaled(image, kind).jpegData(compressionQuality: 0.85) else {
            throw URLError(.cannotDecodeContentData)
        }
        let file = foundFile(gameID, kind)
        try jpeg.write(to: file)
        foundCache.removeObject(forKey: file.path as NSString)
        foundKinds[gameID, default: []].insert(kind)
        foundVersion += 1 // the same kind replaced: views showing it look again
        if onlineArtOff.contains(gameID) {
            onlineArtOff.remove(gameID)
            saveSettings()
        }
    }

    private func foundFile(_ gameID: String, _ kind: Artwork) -> URL {
        Self.foundFolder.appending(path: "\(Self.fileKey(gameID: gameID)).\(kind.rawValue).jpg")
    }

    private func saveMatch(_ match: FoundMatch, for gameID: String) {
        foundMatches[gameID] = match
        saveSettings()
    }

    private static var foundFolder: URL {
        let url = URL.applicationSupportDirectory.appending(path: "FoundArt", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Scaled down to what the screen needs: a hero fills it, a cover is at most about a third of it.
    private static func scaled(_ image: UIImage, _ kind: Artwork) -> UIImage {
        let longest: CGFloat = kind == .hero ? 2400 : 900
        let scale = min(1, longest / max(image.size.width, image.size.height))
        return image.preparingThumbnail(of: CGSize(width: image.size.width * scale, height: image.size.height * scale)) ?? image
    }

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
        if let data = try? Data(contentsOf: custom.appending(path: "hidden.json")) {
            hidden = (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
        }
        if let data = try? Data(contentsOf: custom.appending(path: "showAs.json")) {
            showAs = (try? JSONDecoder().decode([String: ShowAs].self, from: data)) ?? [:]
        }
        if let data = try? Data(contentsOf: custom.appending(path: "splashWaits.json")) {
            splashWaits = (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
        }
        if let data = try? Data(contentsOf: custom.appending(path: "padLayouts.json")) {
            padLayouts = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        let found = Self.foundFolder
        if let data = try? Data(contentsOf: found.appending(path: "matches.json")) {
            foundMatches = (try? JSONDecoder().decode([String: FoundMatch].self, from: data)) ?? [:]
        }
        if let data = try? Data(contentsOf: found.appending(path: "off.json")) {
            onlineArtOff = (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
        }
        for file in (try? FileManager.default.contentsOfDirectory(at: found, includingPropertiesForKeys: nil)) ?? [] {
            let parts = file.deletingPathExtension().lastPathComponent.split(separator: ".")
            guard parts.count == 2, let kind = Artwork(rawValue: String(parts[1])), let id = Self.gameID(fromFileKey: String(parts[0]))
            else { continue }
            foundKinds[id, default: []].insert(kind) // just which exist: the pictures load when first shown
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

    /// Debug's first-run walkthrough (`DemoMode.isFirstRun`) changes nothing saved.
    private static var isWalkthrough: Bool {
        #if DEBUG
        DemoMode.isFirstRun
        #else
        false
        #endif
    }

    /// Every per-game setting, each in its own small file (loaded in init). One place, so a new setting can't be
    /// saved by one change and left behind by another (removing a host's data).
    private func saveSettings() {
        guard !Self.isWalkthrough else { return }
        let encoder = JSONEncoder()
        func save(_ value: some Encodable, _ folder: URL, _ name: String) {
            try? encoder.encode(value).write(to: folder.appending(path: name), options: .atomic)
        }
        save(foundMatches, Self.foundFolder, "matches.json")
        save(onlineArtOff, Self.foundFolder, "off.json")
        save(nicknames, Self.customFolder, "nicknames.json")
        save(hidden, Self.customFolder, "hidden.json")
        save(showAs, Self.customFolder, "showAs.json")
        save(splashWaits, Self.customFolder, "splashWaits.json")
        save(padLayouts, Self.customFolder, "padLayouts.json")
    }

    /// An empty or unchanged name removes the nickname.
    func setNickname(_ name: String, for game: CatalogGame) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        nicknames[game.id] = name.isEmpty || name == game.originalTitle ? nil : name
        saveSettings()
    }

    func setHidden(_ isHidden: Bool, for game: CatalogGame) {
        if isHidden { hidden.insert(game.id) } else { hidden.remove(game.id) }
        saveSettings()
    }

    /// nil: Automatic.
    func setShowAs(_ choice: ShowAs?, for game: CatalogGame) {
        showAs[game.id] = choice
        saveSettings()
    }

    /// nil: the default from Settings.
    func setSplashWait(_ seconds: Int?, for game: CatalogGame) {
        splashWaits[game.id] = seconds
        saveSettings()
    }

    /// The game (by its host's title) uses this on-screen controller layout from now on.
    func setPadLayout(_ layoutID: String, forTitle title: String) {
        padLayouts[title.lowercased()] = layoutID
        saveSettings()
    }

    /// Saves a picture you picked (scaled down to what the screen needs), or removes it with nil.
    func setArtwork(_ image: UIImage?, _ kind: Artwork, for game: CatalogGame) {
        guard !Self.isWalkthrough else { return }
        let file = Self.customFolder.appending(path: "\(Self.fileKey(gameID: game.id)).\(kind.rawValue).jpg")
        let scaled = image.map { Self.scaled($0, kind) }
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
        if DemoMode.isOn { return } // pretend hosts keep their saved games
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

    /// Removing a host with its data: also everything kept for its games (art found online and its matches, your own
    /// pictures, names, hidden, Show As, splash waits, controller layouts) and its favourites and play history. Games
    /// another saved host also has keep theirs.
    func forgetEverything(of pcID: String, keepingGamesOf others: [String]) {
        guard !Self.isWalkthrough else { return } // the Mock PC's games can share IDs with your real ones
        let kept = Set(games(on: others).map(\.id))
        let gone = games(on: [pcID]).map(\.id).filter { !kept.contains($0) }
        for id in gone {
            for kind in Artwork.allCases {
                try? FileManager.default.removeItem(at: foundFile(id, kind))
                foundCache.removeObject(forKey: foundFile(id, kind).path as NSString)
                try? FileManager.default.removeItem(at: Self.customFolder.appending(path: "\(Self.fileKey(gameID: id)).\(kind.rawValue).jpg"))
                artwork[kind]?[id] = nil
            }
            foundKinds[id] = nil
            foundMatches[id] = nil
            onlineArtOff.remove(id)
            nicknames[id] = nil
            hidden.remove(id)
            showAs[id] = nil
            splashWaits[id] = nil
            padLayouts[id] = nil
        }
        saveSettings()
        GameHistory.remove(hostID: pcID)
        histories[pcID] = nil
        forget(pcID)
    }

    /// All games of the saved PCs, one entry per title, newest played first, then by name.
    func games(on pcIDs: [String]) -> [CatalogGame] {
        _ = (apps, histories, nicknames, hidden, showAs) // read even when cached, so views still follow their changes
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
                               isApp: CatalogGame.isShortcut(showAs[id], title: original,
                                                             isSessionControl: sources[0].app.sessionControl != nil),
                               isHidden: hidden.contains(id),
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize // redraws the title when the text size changes

    /// The largest size, down to half, whose longest word fits on one line, because SwiftUI splits a word that doesn't.
    /// Measured at each size: the system font's letter spacing widens as it shrinks, so scaling by a ratio falls short.
    nonisolated static func titleSize(_ title: String, base: CGFloat, width: CGFloat) -> CGFloat {
        let words = title.split(whereSeparator: \.isWhitespace).map(String.init)
        var size = base
        while size > base / 2 {
            let font = UIFont.systemFont(ofSize: size, weight: .semibold)
            if words.allSatisfy({ ceil($0.size(withAttributes: [.font: font]).width) <= width }) { break }
            size -= 0.5
        }
        return max(size, base / 2)
    }

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
                            GeometryReader { proxy in
                                let shown = title ?? app.title
                                let base = UIFont.preferredFont(forTextStyle: .headline).pointSize
                                Text(shown).font(.system(size: Self.titleSize(shown, base: base, width: proxy.size.width - 16), weight: .semibold))
                                    .multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.9))
                                    .minimumScaleFactor(0.5)
                                    .padding(.horizontal, 8).padding(.bottom, 8)
                                    .padding(.top, min(30, proxy.size.height * 0.3)) // clear of the favorite star
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) // Home's row can run off the screen's bottom
                            }
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
