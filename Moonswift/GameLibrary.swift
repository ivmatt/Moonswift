import Foundation

/// Which games the library shows.
nonisolated enum LibraryFilter: String, CaseIterable, Sendable {
    case all = "All", favorites = "Favorites"
}

/// The library's order. The running game always comes first.
nonisolated enum LibrarySort: String, CaseIterable, Sendable {
    case pc = "PC's Order", name = "Name", recent = "Recently Played"
}

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

    /// The games to show, in order: the running game first, then the rest filtered, searched and sorted.
    func arrange(_ apps: [HostApp], running: Int, query: String, filter: LibraryFilter, sort: LibrarySort) -> [HostApp] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let shown = apps.filter { app in
            let key = Self.key(app)
            switch filter {
            case .all: break
            case .favorites: guard favorites.contains(key) else { return false }
            }
            return query.isEmpty || app.title.localizedStandardContains(query)
        }
        let sorted: [HostApp] = switch sort {
        case .pc: shown
        case .name: shown.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .recent: shown.enumerated().sorted { a, b in
            let (dateA, dateB) = (lastPlayed[Self.key(a.element)], lastPlayed[Self.key(b.element)])
            if dateA != dateB { return (dateA ?? .distantPast) > (dateB ?? .distantPast) }
            return a.offset < b.offset // never played: keep the PC's order
        }.map(\.element)
        }
        return sorted.filter { $0.id == running } + sorted.filter { $0.id != running }
    }
}
