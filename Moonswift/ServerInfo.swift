import Foundation
import MoonlightCore
import Network
import Security
import Synchronization

/// What a Sunshine/Vibepollo host reports at GET /serverinfo.
nonisolated struct ServerInfo: Equatable {
    enum PairStatus { case paired, unpaired, unknown }

    let hostname: String
    let uniqueID: String?
    let httpsPort: Int
    let pairStatus: PairStatus
    /// The app ID this client is running on the host, 0 if none. Only reported over paired HTTPS.
    let currentGame: Int
    /// What moonlight-common-c needs to pick the right protocol version and codecs.
    let appVersion: String
    let gfeVersion: String?
    let codecModeSupport: Int
    /// The PC can be put to sleep from this device: Vibepollo's power actions, with sleep allowed for this device in its
    /// web UI. Only reported over paired HTTPS.
    let canSleep: Bool
    /// For Wake-on-LAN. Only reported over paired HTTPS; other replies carry an all-zero placeholder, which reads as nil.
    let macAddress: String?

    /// Parses `<root status_code="200"><hostname>…</hostname>…</root>`.
    init(xml: Data) throws(ServerInfoError) {
        try self.init(fields: parseHostResponse(xml))
    }

    init(fields: [String: String]) throws(ServerInfoError) {
        guard let hostname = fields["hostname"], !hostname.isEmpty else { throw .malformedResponse }
        self.hostname = hostname
        uniqueID = fields["uniqueid"]
        httpsPort = fields["HttpsPort"].flatMap { Int($0) } ?? 47984 // same default as moonlight-ios
        pairStatus = switch fields["PairStatus"].flatMap({ Int($0) }) {
        case nil: .unknown
        case 0: .unpaired
        default: .paired
        }
        currentGame = fields["currentgame"].flatMap { Int($0) } ?? 0
        appVersion = fields["appversion"] ?? ""
        gfeVersion = fields["GfeVersion"]
        codecModeSupport = fields["ServerCodecModeSupport"].flatMap { Int($0) } ?? 0
        canSleep = fields["PowerActionVersion"] == "1" && fields["SleepSupported"] == "1" && fields["SleepAllowed"] == "1"
        macAddress = fields["mac"].flatMap { macBytes($0) == nil ? nil : $0 }
    }
}

/// The six bytes of "aa:bb:cc:dd:ee:ff"; nil for anything else, and for the all-zero placeholder.
nonisolated func macBytes(_ mac: String) -> [UInt8]? {
    let parts = mac.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
    let bytes = parts.compactMap { UInt8($0, radix: 16) }
    return bytes.count == 6 && bytes.contains { $0 != 0 } ? bytes : nil
}

/// The standard Wake-on-LAN "magic packet": six 0xFF bytes, then the MAC address 16 times.
nonisolated func wakePacket(mac: String) -> Data? {
    macBytes(mac).map { bytes in Data(repeating: 0xFF, count: 6) + Data((0..<16).flatMap { _ in bytes }) }
}

/// Sends the wake packet straight to the PC's home address, a few times since UDP can drop it.
// shortcut: no broadcast, which iOS allows only with Apple's multicast entitlement; add it once that's approved.
nonisolated func sendWake(mac: String, to address: String) async {
    let host = hostAddress(address)
    guard let packet = wakePacket(mac: mac), isHomeNetworkHost(host) else { return }
    let connection = NWConnection(host: NWEndpoint.Host(host), port: 9, using: .udp)
    connection.start(queue: .global())
    for _ in 0..<3 {
        connection.send(content: packet, completion: .idempotent)
        try? await Task.sleep(for: .milliseconds(200))
    }
    connection.cancel()
}

nonisolated enum ServerInfoError: LocalizedError, Equatable, TitledError {
    case invalidAddress
    case insecureBlocked
    case unreachable(URLError.Code)
    /// The PC presented a different certificate from the one saved at pairing.
    case certificateChanged
    case httpStatus(Int)
    case hostError(code: Int, message: String)
    case malformedResponse
    /// "Don't Allow" on the Local Network prompt (or it's off in Settings): iOS blocks every LAN connection.
    case localNetworkDenied

    var title: String {
        switch self {
        case .hostError(code: 403, let message) where message.contains("permission"): "Permission needed"
        case .certificateChanged, .hostError(code: 401, _): "Pair again"
        case .unreachable(.notConnectedToInternet): "No network"
        case .unreachable: "Host not responding"
        case .invalidAddress: "Check the address"
        case .insecureBlocked: "Pair at home first"
        case .localNetworkDenied: "Local Network access is off"
        default: "Something went wrong"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter an address like 192.168.1.50, with :port after it if your host uses another."
        case .insecureBlocked: "Pair on your home network. After that, your host works away from home too."
        case .unreachable(.notConnectedToInternet): "This device isn't connected to a network."
        case .unreachable(.timedOut), .unreachable(.cannotConnectToHost), .unreachable(.networkConnectionLost):
            "It may be asleep or off, or its host app isn't running."
        case .unreachable(.cannotFindHost), .unreachable(.dnsLookupFailed): "That name wasn't found on your network."
        case .unreachable(let code): "Couldn't reach it (network error \(code.rawValue))."
        case .certificateChanged: "Your host changed, maybe after a reinstall. Remove it and add it again."
        case .httpStatus(let code): "Your host sent an unexpected reply (\(code))."
        case .hostError(code: 401, _): "Your host doesn't recognise this device anymore. Remove it and add it again."
        // The host names the missing permission ("Launch applications"); its own wording names its software.
        case .hostError(code: 403, let message) where message.contains("permission"):
            (message.split(separator: "\"").dropFirst().first.map { "Turn on \"\($0)\" for this device" } ?? "Turn on this device's permissions")
            + " in your host's settings, under Clients."
        case .hostError(let code, let message): "Your host reported a problem (\(code)): \(message)"
        case .malformedResponse: "Your host sent a reply Moonswift didn't understand."
        case .localNetworkDenied:
            "Moonswift can't reach PCs on your network. Turn it on in Settings › Privacy & Security › Local Network › Moonswift."
        }
    }
}

/// Is the host up, and does it accept this app's certificate?
nonisolated enum HostStatus: Equatable, Sendable {
    case offline
    case online(paired: Bool)
}

/// The pinned host certificate plus the app's identity: what HTTPS to a paired host needs.
nonisolated struct PairedTLS: @unchecked Sendable { // Security types are immutable CF references
    let serverCert: Data
    let identity: SecIdentity
}

/// Builds a host URL from user input like "10.0.4.20" or "10.0.4.20:47989".
/// Plain HTTP uses the typed port (default 47989); HTTPS uses the port the host reported.
nonisolated func hostURL(for address: String, path: String = "/serverinfo", httpsPort: Int? = nil,
                         query: [URLQueryItem] = []) throws(ServerInfoError) -> URL {
    let trimmed = address.trimmingCharacters(in: .whitespaces)
    // shortcut: bare IPv6 addresses aren't accepted (they need [brackets]), add when IPv6 hosts matter.
    guard var components = URLComponents(string: "http://\(trimmed)"),
          let host = components.host, !host.isEmpty,
          components.path.isEmpty, components.query == nil, components.user == nil
    else { throw .invalidAddress }
    if let httpsPort {
        components.scheme = "https"
        components.port = httpsPort
    } else {
        components.port = components.port ?? 47989
    }
    components.path = path
    if !query.isEmpty { components.queryItems = query }
    guard let url = components.url else { throw .invalidAddress }
    return url
}

/// Just the host part of user input like "10.0.4.20:47989", which is what the streaming library wants.
nonisolated func hostAddress(_ address: String) -> String {
    let trimmed = address.trimmingCharacters(in: .whitespaces)
    return URLComponents(string: "http://\(trimmed)")?.host ?? trimmed
}

/// GETs a host endpoint and returns the reply's fields. With `tls`, it trusts only the pinned
/// certificate and presents the app's client certificate.
nonisolated func hostRequest(_ url: URL, timeout: TimeInterval, tls: PairedTLS? = nil) async throws(ServerInfoError) -> [String: String] {
    try parseHostResponse(await hostData(url, timeout: timeout, tls: tls))
}

/// The raw body of a host reply (XML, or a PNG for /appasset).
nonisolated func hostData(_ url: URL, timeout: TimeInterval, tls: PairedTLS? = nil, method: String = "GET",
                              body: Data? = nil) async throws(ServerInfoError) -> Data {
    // ATS is off (Info.plist) because PCs use self-signed certificates that ATS can't except by IP address; HTTPS
    // is protected by pinning instead. This is the part of ATS we keep: plain HTTP never leaves the home network.
    if url.scheme == "http", !isHomeNetworkHost(url.host(percentEncoded: false) ?? "") { throw .insecureBlocked }
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    request.httpMethod = method
    request.httpBody = body
    let delegate = tls.map(PinnedTLSDelegate.init)
    let session = delegate.map { URLSession(configuration: .ephemeral, delegate: $0, delegateQueue: nil) }
        ?? URLSession(configuration: .ephemeral)
    defer { session.finishTasksAndInvalidate() } // a session keeps its delegate alive until invalidated

    let data: Data, response: URLResponse
    do {
        (data, response) = try await session.data(for: request)
    } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
        throw .insecureBlocked
    } catch {
        if isLocalNetworkDenied(error) { throw .localNetworkDenied }
        if delegate?.rejectedCertificate.withLock({ $0 }) == true { throw .certificateChanged }
        throw .unreachable((error as? URLError)?.code ?? .unknown)
    }

    if let http = response as? HTTPURLResponse, http.statusCode != 200, http.statusCode != 202 { // 202: accepted (sleep)
        throw .httpStatus(http.statusCode)
    }
    return data
}

/// Local Network access denied: NWBrowser waits with a policy-denied DNS error; URLSession fails with the request's
/// path unsatisfied for that reason (TN3179).
nonisolated func isLocalNetworkDenied(_ error: Error) -> Bool {
    if case .dns(let code)? = error as? NWError { return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) }
    guard let path = (error as NSError).userInfo["_NSURLErrorNWPathKey"].map({ $0 as AnyObject }) as? nw_path_t else { return false }
    return nw_path_get_unsatisfied_reason(path) == nw_path_unsatisfied_reason_local_network_denied
}

/// Default timeout is moonlight-ios's NORMAL_TIMEOUT_SEC; status polling uses its 2s SHORT_TIMEOUT_SEC.
nonisolated func fetchServerInfo(address: String, timeout: TimeInterval = 5) async throws(ServerInfoError) -> ServerInfo {
    try ServerInfo(fields: await hostRequest(hostURL(for: address), timeout: timeout))
}

/// serverinfo over pinned HTTPS: the only way a host reports PairStatus=1.
nonisolated func fetchPairedServerInfo(address: String, httpsPort: Int, serverCert: Data,
                                       timeout: TimeInterval = 5) async throws -> ServerInfo {
    let tls = PairedTLS(serverCert: serverCert, identity: try ClientIdentity.current.get().identity)
    let url = try hostURL(for: address, httpsPort: httpsPort, query: [URLQueryItem(name: "uniqueid", value: Pairing.uniqueID)])
    return try ServerInfo(fields: await hostRequest(url, timeout: timeout, tls: tls))
}

/// True for addresses that can only be on the home network (or a private VPN): private, link-local and loopback
/// IPv4 and IPv6, Tailscale's 100.64.0.0/10, `.local` Bonjour names and single-label names.
nonisolated func isHomeNetworkHost(_ host: String) -> Bool {
    let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: "%").first.map(String.init) ?? ""
    if let ipv4 = IPv4Address(host) {
        let b = [UInt8](ipv4.rawValue)
        return b[0] == 10 || b[0] == 127 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
            || (b[0] == 169 && b[1] == 254) || (b[0] == 100 && b[1] & 0xC0 == 64)
    }
    if let ipv6 = IPv6Address(host) {
        let b = [UInt8](ipv6.rawValue)
        return ipv6 == .loopback || b[0] & 0xFE == 0xFC || (b[0] == 0xFE && b[1] & 0xC0 == 0x80) // ULA, link-local
    }
    let name = host.lowercased()
    return !name.isEmpty && (name.hasSuffix(".local") || !name.contains("."))
}

/// "Local" or "Remote": how this device reaches a host, by the streaming core's own test (`isPrivateNetworkAddress`),
/// so the label matches how the stream is tuned. Unlike `isHomeNetworkHost`, Tailscale counts as Remote. A name is
/// looked up, which can block: call it off the main thread.
// shortcut: a name with both private and public addresses reads by its first one; use the connected one if that comes up.
nonisolated func connectionLabel(for address: String) -> String {
    let host = hostAddress(address).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        .split(separator: "%").first.map(String.init) ?? ""
    var results: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, nil, &results) == 0, let info = results?.pointee else { return "Remote" }
    defer { freeaddrinfo(results) }
    let b: [UInt8] = switch info.ai_family {
    case AF_INET: info.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr, Array.init) }
    case AF_INET6: info.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr, Array.init) }
    default: []
    }
    let isLocal = switch b.count {
    case 4: b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
    case 16: b[0] & 0xFE == 0xFC || (b[0] == 0xFE && b[1] & 0x80 == 0x80) // ULA, link-local, site-local
    default: false
    }
    return isLocal ? "Local" : "Remote"
}

/// The addresses to try for a host, in order: the local one first, then its public one if it has a different one.
nonisolated func candidateAddresses(local: String, remote: String?) -> [String] {
    guard let remote = remote?.trimmingCharacters(in: .whitespaces), !remote.isEmpty,
          hostAddress(remote) != hostAddress(local) else { return [local] }
    return [local, remote]
}

/// Paired hosts are asked over HTTPS, at each address in turn (local, then remote). If none answers (never paired,
/// or the host was reinstalled), plain HTTP to the local address still tells us whether it's online, like
/// moonlight-ios's HTTP fallback. Plain HTTP is never sent to the remote address: it isn't authenticated, so it
/// stays on the home network.
/// Returns the address that answered.
nonisolated func checkHost(address: String, remoteAddress: String?, httpsPort: Int,
                           serverCert: Data) async -> (status: HostStatus, info: ServerInfo?, address: String?) {
    if !serverCert.isEmpty {
        // All addresses at once, so a remote PC doesn't wait out the home address's timeout first. The public
        // address gets longer: the first request after a pause can wait on the cellular radio waking up.
        let candidates = candidateAddresses(local: address, remote: remoteAddress)
        let answers = await withTaskGroup(of: (String, ServerInfo?).self) { group in
            for candidate in candidates {
                group.addTask {
                    let timeout: TimeInterval = candidate == address ? 2 : 4
                    return (candidate, try? await fetchPairedServerInfo(address: candidate, httpsPort: httpsPort,
                                                                        serverCert: serverCert, timeout: timeout))
                }
            }
            var answers: [String: ServerInfo] = [:]
            for await (candidate, info) in group { answers[candidate] = info }
            return answers
        }
        // The home address wins when both answer.
        if let candidate = candidates.first(where: { answers[$0] != nil }), let info = answers[candidate] {
            return (.online(paired: info.pairStatus == .paired), info, candidate)
        }
    }
    if let info = try? await fetchServerInfo(address: address, timeout: 2) {
        return (.online(paired: false), info, address)
    }
    return (.offline, nil, nil)
}

/// Asks Moonlight's STUN server for this network's public IPv4 address, like moonlight-ios does. While the phone
/// is on the same network as a PC, that's the PC's public address too. Blocks for up to a few seconds.
nonisolated func findPublicIPv4() -> String? {
    var address: UInt32 = 0
    guard LiFindExternalAddressIP4("stun.moonlight-stream.org", 3478, &address) == 0, address != 0 else { return nil }
    return ipv4String(networkOrder: address)
}

/// A looked-up public IP may replace nothing, or an older public IP. A name, a port or a VPN address was typed: it stays.
nonisolated func canLearnRemoteAddress(over current: String?) -> Bool {
    guard let current = current?.trimmingCharacters(in: .whitespaces), !current.isEmpty else { return true }
    return IPv4Address(current) != nil && !isHomeNetworkHost(current)
}

/// "a.b.c.d" from an IPv4 address in network byte order (the first byte in memory is the first number).
nonisolated func ipv4String(networkOrder address: UInt32) -> String {
    withUnsafeBytes(of: address) { $0.map(String.init).joined(separator: ".") }
}

/// Every host reply is `<root status_code="200" …><field>…</field>…</root>`: check the status, return the fields.
nonisolated func parseHostResponse(_ xml: Data) throws(ServerInfoError) -> [String: String] {
    try collectRoot(xml).fields
}

/// For list replies like /applist: one field dictionary per repeated child, e.g. each `<App>…</App>`.
nonisolated func parseHostRecords(_ xml: Data) throws(ServerInfoError) -> [[String: String]] {
    try collectRoot(xml).records
}

private nonisolated func collectRoot(_ xml: Data) throws(ServerInfoError) -> RootCollector {
    let collector = RootCollector()
    let parser = XMLParser(data: xml)
    parser.delegate = collector
    guard parser.parse(), let code = collector.rootAttributes["status_code"] else {
        throw .malformedResponse
    }
    guard code == "200" else {
        throw .hostError(code: Int(code) ?? -1, message: collector.rootAttributes["status_message"] ?? "Server error")
    }
    return collector
}

/// Hosts use self-signed certificates, so normal trust checks can't work: accept exactly the certificate
/// saved at pairing (pinning), and answer the host's request for our client certificate.
private nonisolated final class PinnedTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let tls: PairedTLS
    /// Set when the PC's certificate wasn't the pinned one, so the error can say so.
    let rejectedCertificate = Mutex(false)
    init(tls: PairedTLS) { self.tls = tls }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust,
                  let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
                  SecCertificateCopyData(leaf) as Data == tls.serverCert
            else {
                rejectedCertificate.withLock { $0 = true }
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        case NSURLAuthenticationMethodClientCertificate:
            completionHandler(.useCredential, URLCredential(identity: tls.identity, certificates: nil, persistence: .forSession))
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// Collects the root's attributes and the text of its direct children into a flat dictionary,
/// the same shape moonlight-ios's HttpResponse builds. Children that have children of their own
/// (like `<App>`) become one record each.
private nonisolated final class RootCollector: NSObject, XMLParserDelegate {
    var rootAttributes: [String: String] = [:]
    var fields: [String: String] = [:]
    var records: [[String: String]] = []
    private var record: [String: String] = [:]
    private var depth = 0
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        depth += 1
        if depth == 1 { rootAttributes = attributes }
        if depth == 2 { record = [:] }
        if depth == 2 || depth == 3 { text = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if depth == 2 || depth == 3 { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if depth == 3 { record[name] = value; text = "" }
        if depth == 2 {
            if record.isEmpty { fields[name] = value } else { records.append(record) }
        }
        depth -= 1
    }
}
