import Foundation
import MoonlightCore

/// A game or app the host offers, from GET /applist.
nonisolated struct HostApp: Identifiable, Equatable, Sendable {
    let id: Int
    let uuid: String
    let title: String
    /// Changes when the box art changes on the host, so it doubles as a cache key.
    let artVersion: String

    init?(fields: [String: String]) {
        guard let id = fields["ID"].flatMap({ Int($0) }), let title = fields["AppTitle"] else { return nil }
        self.id = id
        self.title = title
        uuid = fields["UUID"] ?? ""
        artVersion = fields["ArtVersion"] ?? ""
    }
}

/// What a successful /launch or /resume hands to the streaming library.
nonisolated struct LaunchSession: Hashable, Sendable {
    /// The host's RTSP URL for this session (`sessionUrl0`); older hosts don't send one.
    let rtspURL: String?
    /// The key and key ID sent with the launch; the host encrypts with them (audio, input).
    let riKey: Data
    let riKeyID: Int32
}

nonisolated enum GameError: LocalizedError, Equatable {
    case launchFailed, quitFailed
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed: "The PC didn't start the game."
        case .quitFailed: "The PC didn't quit the game."
        case .permissionDenied(let message): message
        }
    }
}

/// Everything the app asks of a paired host over pinned HTTPS: its games, their box art, launch, resume and quit.
nonisolated struct HostClient: Sendable {
    let hostID: String
    let address: String
    let httpsPort: Int
    let serverCert: Data

    /// What Vibepollo puts in place of the list when "List applications" is off for this client (nvhttp.cpp applist()).
    static let permissionDeniedAppID = 114514

    func serverInfo() async throws -> ServerInfo {
        try await fetchPairedServerInfo(address: address, httpsPort: httpsPort, serverCert: serverCert)
    }

    func apps() async throws -> [HostApp] {
        let apps = try Self.parseAppList(await data("/applist", timeout: 10))
        if apps.count == 1, apps[0].id == Self.permissionDeniedAppID { throw GameError.permissionDenied(apps[0].title) }
        return apps
    }

    static func parseAppList(_ xml: Data) throws -> [HostApp] {
        try parseHostRecords(xml).compactMap(HostApp.init(fields:))
    }

    /// PNG box art, from the Caches folder when this art version was fetched before.
    func boxArt(for app: HostApp) async throws -> Data {
        let name = "\(hostID)-\(app.uuid.isEmpty ? String(app.id) : app.uuid)-\(app.artVersion).png"
            .replacingOccurrences(of: "/", with: "_")
        let file = URL.cachesDirectory.appending(path: "BoxArt", directoryHint: .isDirectory).appending(path: name)
        if let cached = try? Data(contentsOf: file) { return cached }

        let png = try await data("/appasset", timeout: 10, query: [
            URLQueryItem(name: "appid", value: String(app.id)),
            URLQueryItem(name: "appuuid", value: app.uuid),
            URLQueryItem(name: "AssetType", value: "2"),
            URLQueryItem(name: "AssetIdx", value: "0"),
        ])
        // Caching is best effort: iOS may purge Caches, and a failed write just means fetching again.
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: file)
        return png
    }

    /// Starts `app`. Blocks while the host starts it; the host then waits for the stream to connect.
    func launch(_ app: HostApp, width: Int, height: Int, fps: Int) async throws -> LaunchSession {
        try await start("/launch", app: app, width: width, height: height, fps: fps)
    }

    /// Reconnects to the game that's already running.
    func resume(_ app: HostApp, width: Int, height: Int, fps: Int) async throws -> LaunchSession {
        try await start("/resume", app: app, width: width, height: height, fps: fps)
    }

    /// Vibepollo extension: changes the running stream's bitrate without reconnecting (other hosts answer 404).
    /// Returns the bitrate the host applied, in kbps; it caps live changes at its own maximum (500 Mbps).
    func setBitrate(_ kbps: Int) async throws -> Int {
        let fields = try parseHostResponse(await data("/bitrate", timeout: 5, query: [URLQueryItem(name: "bitrate", value: String(kbps))]))
        guard let applied = fields["bitrate"].flatMap({ Int($0) }), applied > 0 else { throw ServerInfoError.malformedResponse }
        return applied
    }

    func quit() async throws {
        let fields = try parseHostResponse(await data("/cancel", timeout: 60))
        guard fields["cancel"] == "1" else { throw GameError.quitFailed }
    }

    private func start(_ path: String, app: HostApp, width: Int, height: Int, fps: Int) async throws -> LaunchSession {
        let key = Pairing.randomBytes(16), keyID = Int32.random(in: .min ... .max)
        let query = Self.launchQuery(app: app, width: width, height: height, fps: fps, rikey: key, rikeyID: keyID)
            + Self.libraryLaunchQuery(String(cString: LiGetLaunchUrlQueryParameters()))
        let fields = try parseHostResponse(await data(path, timeout: 120, query: query))
        // /launch answers gamesession=1; /resume (or a launch of the running game) answers resume=1.
        guard fields["gamesession"] == "1" || fields["resume"] == "1" else { throw GameError.launchFailed }
        return LaunchSession(rtspURL: fields["sessionUrl0"], riKey: key, riKeyID: keyID)
    }

    /// The library's own launch parameters (like "&corever=1"), so the host uses the protocol version it speaks.
    static func libraryLaunchQuery(_ raw: String) -> [URLQueryItem] {
        raw.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            return URLQueryItem(name: String(parts[0]), value: parts.count > 1 ? String(parts[1]) : nil)
        }
    }

    /// The query moonlight-ios's HttpManager sends to /launch and /resume, minus the HDR and controller options.
    static func launchQuery(app: HostApp, width: Int, height: Int, fps: Int, rikey: Data, rikeyID: Int32) -> [URLQueryItem] {
        [
            URLQueryItem(name: "appid", value: String(app.id)),
            URLQueryItem(name: "appuuid", value: app.uuid),
            URLQueryItem(name: "mode", value: "\(width)x\(height)x\(fps)"),
            URLQueryItem(name: "additionalStates", value: "1"),
            URLQueryItem(name: "sops", value: "0"), // don't let the host change game settings
            URLQueryItem(name: "rikey", value: rikey.hex),
            URLQueryItem(name: "rikeyid", value: String(rikeyID)),
            URLQueryItem(name: "localAudioPlayMode", value: "0"), // audio plays on the iPad, not the PC
            URLQueryItem(name: "surroundAudioInfo", value: "196610"), // stereo: channel mask 0x3 << 16 | 2 channels
        ]
    }

    private func data(_ path: String, timeout: TimeInterval, query: [URLQueryItem] = []) async throws -> Data {
        let tls = PairedTLS(serverCert: serverCert, identity: try ClientIdentity.current.get().identity)
        let url = try hostURL(for: address, path: path, httpsPort: httpsPort,
                              query: [URLQueryItem(name: "uniqueid", value: Pairing.uniqueID)] + query)
        return try await hostData(url, timeout: timeout, tls: tls)
    }
}
