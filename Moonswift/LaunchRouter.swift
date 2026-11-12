import AppIntents
import Foundation

/// "Stream this game on this PC", from a link or a Siri Shortcut. The PC is matched by
/// its unique ID or its name, the game by its UUID or title (case doesn't matter).
nonisolated struct LaunchRequest: Equatable, Sendable, Codable {
    let pc: String
    let game: String

    /// moonswift://stream?pc=Desktop&game=Hades
    init?(url: URL) {
        guard url.scheme?.lowercased() == "moonswift", url.host()?.lowercased() == "stream",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let pc = items.first(where: { $0.name == "pc" })?.value, !pc.isEmpty,
              let game = items.first(where: { $0.name == "game" })?.value, !game.isEmpty else { return nil }
        self.init(pc: pc, game: game)
    }

    init(pc: String, game: String) {
        self.pc = pc
        self.game = game
    }

    var url: URL? {
        var components = URLComponents()
        components.scheme = "moonswift"
        components.host = "stream"
        components.queryItems = [URLQueryItem(name: "pc", value: pc), URLQueryItem(name: "game", value: game)]
        return components.url
    }

    func matches(pcID: String, name: String) -> Bool {
        pc == pcID || pc.caseInsensitiveCompare(name) == .orderedSame
    }

    /// The exact game first (UUID, then title), else the first title containing the words.
    func game(in apps: [HostApp]) -> HostApp? {
        apps.first { $0.uuid == game } ?? apps.first { $0.title.caseInsensitiveCompare(game) == .orderedSame }
            ?? apps.first { $0.title.localizedStandardContains(game) }
    }

    /// The last game streamed, for the Resume Last Game Shortcut.
    static var last: LaunchRequest? {
        get { UserDefaults.standard.data(forKey: "lastLaunch").flatMap { try? JSONDecoder().decode(LaunchRequest.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "lastLaunch") }
    }
}

/// Hands a launch request from outside (link, Shortcut) to the screens: the home screen opens the PC, its game list
/// starts the game and clears the request.
@Observable final class LaunchRouter {
    static let shared = LaunchRouter()
    var pending: LaunchRequest?
}

/// Siri and Shortcuts: stream a game by name.
struct StreamGameIntent: AppIntent {
    static let title: LocalizedStringResource = "Stream a Game"
    static let description = IntentDescription("Opens Moonswift and streams a game from one of your PCs.")
    static let openAppWhenRun = true

    @Parameter(title: "Game") var game: String
    @Parameter(title: "PC") var pc: String

    static var parameterSummary: some ParameterSummary { Summary("Stream \(\.$game) on \(\.$pc)") }

    @MainActor func perform() async throws -> some IntentResult {
        LaunchRouter.shared.pending = LaunchRequest(pc: pc, game: game)
        return .result()
    }
}

/// Siri and Shortcuts: pick up where you left off.
struct ResumeLastGameIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Last Game"
    static let description = IntentDescription("Opens Moonswift and streams the last game you played.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        LaunchRouter.shared.pending = LaunchRequest.last
        return .result()
    }
}

struct MoonswiftShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ResumeLastGameIntent(), phrases: ["Resume my game in \(.applicationName)",
                                                             "Continue playing in \(.applicationName)"],
                    shortTitle: "Resume Last Game", systemImageName: "play.fill")
        AppShortcut(intent: StreamGameIntent(), phrases: ["Stream a game in \(.applicationName)"],
                    shortTitle: "Stream a Game", systemImageName: "gamecontroller")
    }
}
