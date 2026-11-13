import Foundation

/// Favorites and when each game was last streamed, per PC. Kept on this device (UserDefaults), by game UUID
/// (or ID on hosts without UUIDs), so they survive the PC reordering or renaming games.
nonisolated struct GameHistory: Equatable, Sendable {
    var favorites: Set<String> = []
    var lastPlayed: [String: Date] = [:]

    static func key(_ app: HostApp) -> String { app.uuid.isEmpty ? "id-\(app.id)" : app.uuid }

    static func load(hostID: String, from defaults: UserDefaults = .standard) -> GameHistory {
        GameHistory(favorites: Set(defaults.stringArray(forKey: "favorites.\(hostID)") ?? []),
                    lastPlayed: defaults.dictionary(forKey: "lastPlayed.\(hostID)") as? [String: Date] ?? [:])
    }

    func save(hostID: String, to defaults: UserDefaults = .standard) {
        defaults.set(favorites.sorted(), forKey: "favorites.\(hostID)")
        defaults.set(lastPlayed, forKey: "lastPlayed.\(hostID)")
    }
}
