import Foundation
import MoonlightCore

/// A game or app the host offers, from GET /applist.
/// Vibepollo's remote-session controls: entries it adds to the game list (each with a fixed UUID), some only while
/// another device is streaming. Other hosts never send these.
nonisolated enum SessionControl: Int, Sendable {
    case join = 1, disconnectMonitor, disconnectInput, end, monitor, input, runningGame

    static let uuidPrefix = "9a1c5a25-58fe-40e0-b9aa-7d3f0000000"

    /// Only there while another device streams; Remote Monitor and Remote Input are always listed.
    var isContextual: Bool { self != .monitor && self != .input }
}

nonisolated struct HostApp: Identifiable, Hashable, Sendable, Codable {
    let id: Int
    let uuid: String
    let title: String
    /// Changes when the box art changes on the host, so it doubles as a cache key.
    let artVersion: String

    var sessionControl: SessionControl? {
        guard uuid.lowercased().hasPrefix(SessionControl.uuidPrefix), let last = uuid.last?.wholeNumberValue else { return nil }
        return SessionControl(rawValue: last)
    }

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

nonisolated enum PowerError: LocalizedError, Equatable {
    case notAllowed, busy, failed(Int)

    var errorDescription: String? {
        switch self {
        case .notAllowed: "This device isn't allowed to put the PC to sleep. Turn on \"Allow this device to put the PC to sleep\" for it in the streaming software's web page on the PC."
        case .busy: "The PC is busy. Quit the running game and end any stream, then try again."
        case .failed(let code): "The PC didn't go to sleep (error \(code))."
        }
    }
}

nonisolated struct ClipboardError: LocalizedError, Equatable {
    let status: Int

    var errorDescription: String? {
        switch status {
        case 401: "This device isn't allowed to use the PC's clipboard. Turn on the clipboard permissions for it in the streaming software's web page on the PC."
        case 403: "The clipboard is only shared during a stream."
        case 404, 405: "This PC doesn't share its clipboard."
        default: "The clipboard couldn't be shared (error \(status))."
        }
    }
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
    func launch(_ app: HostApp, width: Int, height: Int, fps: Int, videoFormats: Int32) async throws -> LaunchSession {
        try await start("/launch", app: app, width: width, height: height, fps: fps, videoFormats: videoFormats)
    }

    /// Reconnects to the game that's already running.
    func resume(_ app: HostApp, width: Int, height: Int, fps: Int, videoFormats: Int32) async throws -> LaunchSession {
        try await start("/resume", app: app, width: width, height: height, fps: fps, videoFormats: videoFormats)
    }

    /// Vibepollo extension: changes the running stream's bitrate without reconnecting (other hosts answer 404).
    /// Returns the bitrate the host applied, in kbps; it caps live changes at its own maximum (500 Mbps).
    func setBitrate(_ kbps: Int) async throws -> Int {
        let fields = try parseHostResponse(await data("/bitrate", timeout: 5, query: [URLQueryItem(name: "bitrate", value: String(kbps))]))
        guard let applied = fields["bitrate"].flatMap({ Int($0) }), applied > 0 else { throw ServerInfoError.malformedResponse }
        return applied
    }

    /// Removes this device from the PC's paired devices; pairing again needs a PIN.
    func unpair() async throws {
        let fields = try parseHostResponse(await data("/unpair", timeout: 5))
        guard fields["unpaired"] != "0" else { throw ServerInfoError.hostError(code: 200, message: "The PC didn't unpair this device.") }
    }

    /// Puts the PC to sleep (Vibepollo's power actions). The PC only accepts while nothing is streaming or waiting to
    /// resume, so quit the game first. Accepted means asked, not done: the PC reports offline once it's asleep.
    func sleep() async throws {
        let offer = try parseHostResponse(await data("/power-actions/v1", timeout: 5))
        guard offer["SleepSupported"] == "1", offer["SleepAllowed"] == "1" else { throw PowerError.notAllowed }
        guard offer["SleepAvailable"] == "1", let token = offer["SleepToken"] else { throw PowerError.busy }
        do {
            // Exactly one query argument and an empty body: the PC rejects anything else.
            let reply = try parseHostResponse(await data("/power-actions/v1/sleep", timeout: 10, method: "POST",
                                                         query: [URLQueryItem(name: "token", value: token)], identify: false))
            guard reply["SleepAccepted"] == "1" else { throw PowerError.busy }
        } catch ServerInfoError.httpStatus(let code), ServerInfoError.hostError(let code, _) {
            switch code {
            case 403, 401: throw PowerError.notAllowed
            case 409, 503: throw PowerError.busy
            default: throw PowerError.failed(code)
            }
        }
    }

    /// Vibepollo's clipboard sharing: text only, only while this device is streaming, and only with the clipboard
    /// permissions granted to this device on the PC.
    func pcClipboard() async throws -> String {
        do {
            return String(decoding: try await data("/actions/clipboard", timeout: 5, query: [URLQueryItem(name: "type", value: "text")]),
                          as: UTF8.self)
        } catch ServerInfoError.httpStatus(let code) {
            throw ClipboardError(status: code)
        }
    }

    func setPCClipboard(_ text: String) async throws {
        do {
            _ = try await data("/actions/clipboard", timeout: 5, method: "POST", query: [URLQueryItem(name: "type", value: "text")],
                               body: Data(text.utf8))
        } catch ServerInfoError.httpStatus(let code) {
            throw ClipboardError(status: code)
        }
    }

    func quit() async throws {
        let fields = try parseHostResponse(await data("/cancel", timeout: 60))
        guard fields["cancel"] == "1" else { throw GameError.quitFailed }
    }

    private func start(_ path: String, app: HostApp, width: Int, height: Int, fps: Int, videoFormats: Int32) async throws -> LaunchSession {
        let key = Pairing.randomBytes(16), keyID = Int32.random(in: .min ... .max)
        let query = Self.launchQuery(app: app, width: width, height: height, fps: fps, rikey: key, rikeyID: keyID,
                                     playAudioOnPC: UserDefaults.standard.bool(forKey: SettingsKey.playAudioOnPC),
                                     hdr: videoFormats & VIDEO_FORMAT_MASK_10BIT != 0)
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

    /// The query moonlight-ios's HttpManager sends to /launch and /resume, minus the controller options.
    static func launchQuery(app: HostApp, width: Int, height: Int, fps: Int, rikey: Data, rikeyID: Int32,
                            playAudioOnPC: Bool = false, hdr: Bool = false) -> [URLQueryItem] {
        // HDR: the PC switches its encoder to 10-bit when its display is in HDR. The client display fields are zeros,
        // as moonlight-ios sends them; the PC then uses its own display's metadata.
        let hdrItems = hdr ? [
            URLQueryItem(name: "hdrMode", value: "1"),
            URLQueryItem(name: "clientHdrCapVersion", value: "0"),
            URLQueryItem(name: "clientHdrCapSupportedFlagsInUint32", value: "0"),
            URLQueryItem(name: "clientHdrCapMetaDataId", value: "NV_STATIC_METADATA_TYPE_1"),
            URLQueryItem(name: "clientHdrCapDisplayData", value: "0x0x0x0x0x0x0x0x0x0x0"),
        ] : []
        return hdrItems + [
            URLQueryItem(name: "appid", value: String(app.id)),
            URLQueryItem(name: "appuuid", value: app.uuid),
            URLQueryItem(name: "mode", value: "\(width)x\(height)x\(fps)"),
            URLQueryItem(name: "additionalStates", value: "1"),
            URLQueryItem(name: "sops", value: "0"), // don't let the host change game settings
            URLQueryItem(name: "rikey", value: rikey.hex),
            URLQueryItem(name: "rikeyid", value: String(rikeyID)),
            URLQueryItem(name: "localAudioPlayMode", value: playAudioOnPC ? "1" : "0"), // 1: the PC's speakers play too
            URLQueryItem(name: "surroundAudioInfo", value: "196610"), // stereo: channel mask 0x3 << 16 | 2 channels
        ]
    }

    /// `identify: false` leaves out the uniqueid argument, for requests that must carry exactly their own arguments.
    private func data(_ path: String, timeout: TimeInterval, method: String = "GET", query: [URLQueryItem] = [],
                      body: Data? = nil, identify: Bool = true) async throws -> Data {
        let tls = PairedTLS(serverCert: serverCert, identity: try ClientIdentity.current.get().identity)
        let url = try hostURL(for: address, path: path, httpsPort: httpsPort,
                              query: (identify ? [URLQueryItem(name: "uniqueid", value: Pairing.uniqueID)] : []) + query)
        return try await hostData(url, timeout: timeout, tls: tls, method: method, body: body)
    }
}
