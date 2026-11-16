import Foundation
import Security

/// SteamGridDB's API (steamgriddb.com): community art for games, looked up by name. Needs a free API key from the
/// user's SteamGridDB profile; kept in the Keychain.
nonisolated struct SteamGridDB {
    let key: String

    struct Match: Decodable, Sendable {
        let id: Int
        let name: String
    }

    enum Failure: Error { case unauthorized, server(Int) }

    private struct Response<T: Decodable>: Decodable {
        let success: Bool
        let data: T?
    }

    /// One picture: its preview, and the full one to save.
    struct Picture: Decodable, Hashable, Sendable {
        let id: Int
        let url: URL
        let thumb: URL
    }

    private static let base = URL(string: "https://www.steamgriddb.com/api/v2")!

    /// The best match for a game's name, or nil when there's none.
    func search(_ name: String) async throws -> Match? { try await matches(name).first }

    /// Every game the name might be, best first.
    func matches(_ name: String) async throws -> [Match] {
        let term = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? name
        let matches: [Match]? = try await get("search/autocomplete/\(term)")
        return matches ?? []
    }

    /// The top-rated picture of one kind for a matched game: a cover for each cover shape, or a hero.
    func imageURL(_ kind: GameCatalog.Artwork, game: Int) async throws -> URL? {
        try await pictures(kind, game: game).first?.url
    }

    /// One page of a game's pictures of one kind, best rated first; an empty page is the end.
    func pictures(_ kind: GameCatalog.Artwork, game: Int, page: Int = 0) async throws -> [Picture] {
        let query = "types=static&nsfw=false&humor=false&page=\(page)"
        let path = switch kind {
        case .cover: "grids/game/\(game)?dimensions=600x900&\(query)" // 2:3, Steam's
        case .cover34: "grids/game/\(game)?dimensions=660x930,342x482&\(query)" // its nearest to 3:4
        case .coverSquare: "grids/game/\(game)?dimensions=1024x1024,512x512&\(query)"
        case .hero: "heroes/game/\(game)?\(query)"
        }
        let pictures: [Picture]? = try await get(path)
        return pictures ?? []
    }

    /// The game's Steam app ID, when it's on Steam: for Steam's own store pictures.
    func steamAppID(game: Int) async throws -> Int? {
        struct Game: Decodable {
            struct Platform: Decodable {
                let id: String
                init(from decoder: Decoder) throws { // a string or a number, depending on the platform
                    let container = try decoder.container(keyedBy: Key.self)
                    if let text = try? container.decode(String.self, forKey: .id) { id = text }
                    else { id = String(try container.decode(Int.self, forKey: .id)) }
                }
                enum Key: String, CodingKey { case id }
            }
            let external_platform_data: [String: [Platform]]?
        }
        let game: Game? = try await get("games/id/\(game)?platformdata=steam")
        return game?.external_platform_data?["steam"]?.first.flatMap { Int($0.id) }
    }

    /// Steam's own store picture of this kind (what the site's "Original Steam Assets" shows): its 2:3 library cover
    /// and its hero; Steam has none in 3:4 or square.
    static func steamPicture(_ kind: GameCatalog.Artwork, appID: Int) -> URL? {
        let base = "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)"
        return switch kind {
        case .cover: URL(string: "\(base)/library_600x900_2x.jpg")
        case .hero: URL(string: "\(base)/library_hero.jpg")
        case .cover34, .coverSquare: nil
        }
    }

    /// Whether a picture is really there: Steam's newer games keep theirs at other addresses, so these can be missing.
    static func exists(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        return ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode == 200
    }

    private func get<T: Decodable>(_ path: String) async throws -> T? {
        guard let url = URL(string: "\(Self.base.absoluteString)/\(path)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw Failure.unauthorized }
        if status == 404 { return nil } // no such game, or no art of that kind
        guard (200..<300).contains(status) else { throw Failure.server(status) }
        return try JSONDecoder().decode(Response<T>.self, from: data).data
    }

    /// A host's title made searchable: without ™, ® and ©, a trailing "(…)", or an edition after a dash or colon
    /// ("Control - Ultimate Edition" finds Control).
    static func cleaned(_ title: String) -> String {
        var name = title.replacing(/[™®©]/, with: "")
        name = name.replacing(/\s*\([^)]*\)\s*$/, with: "")
        name = name.replacing(/\s*[-–:]\s*[^-–:]*\bEdition\s*$/.ignoresCase(), with: "")
        return name.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    // MARK: The key, in the Keychain

    private static let service = "SteamGridDB"

    static var savedKey: String? {
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecReturnData: true] as CFDictionary
        var item: CFTypeRef?
        guard SecItemCopyMatching(query, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Saves the key; an empty one removes it.
    static func save(key: String) {
        let match = [kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary
        SecItemDelete(match)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                    kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock, kSecValueData: Data(key.utf8)] as CFDictionary, nil)
    }
}
