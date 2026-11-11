import Foundation
import Security

/// What a Sunshine/Vibepollo host reports at GET /serverinfo.
nonisolated struct ServerInfo: Equatable {
    enum PairStatus { case paired, unpaired, unknown }

    let hostname: String
    let uniqueID: String?
    let httpsPort: Int
    let pairStatus: PairStatus
    /// The app ID this client is running on the host, 0 if none. Only reported over paired HTTPS.
    let currentGame: Int

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
    }
}

nonisolated enum ServerInfoError: LocalizedError, Equatable {
    case invalidAddress
    case insecureBlocked
    case unreachable(String)
    case httpStatus(Int)
    case hostError(code: Int, message: String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter an IP address or hostname, optionally with :port."
        case .insecureBlocked: "iOS only allows plain HTTP to local addresses (an IP or a .local name)."
        case .unreachable(let detail): "Can't reach the host. \(detail)"
        case .httpStatus(let code): "The host answered with HTTP \(code)."
        case .hostError(let code, let message): "The host reported an error (\(code)): \(message)"
        case .malformedResponse: "The host's reply wasn't valid XML."
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

/// GETs a host endpoint and returns the reply's fields. With `tls`, it trusts only the pinned
/// certificate and presents the app's client certificate.
nonisolated func hostRequest(_ url: URL, timeout: TimeInterval, tls: PairedTLS? = nil) async throws(ServerInfoError) -> [String: String] {
    try parseHostResponse(await hostData(url, timeout: timeout, tls: tls))
}

/// The raw body of a host reply (XML, or a PNG for /appasset).
nonisolated func hostData(_ url: URL, timeout: TimeInterval, tls: PairedTLS? = nil) async throws(ServerInfoError) -> Data {
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    let session = tls.map { URLSession(configuration: .ephemeral, delegate: PinnedTLSDelegate(tls: $0), delegateQueue: nil) }
        ?? URLSession(configuration: .ephemeral)
    defer { session.finishTasksAndInvalidate() } // a session keeps its delegate alive until invalidated

    let data: Data, response: URLResponse
    do {
        (data, response) = try await session.data(for: request)
    } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
        throw .insecureBlocked
    } catch {
        throw .unreachable(error.localizedDescription)
    }

    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
        throw .httpStatus(http.statusCode)
    }
    return data
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

/// Paired hosts are asked over HTTPS first. If that fails (never paired, or the host was reinstalled),
/// plain HTTP still tells us whether it's online, like moonlight-ios's HTTP fallback.
nonisolated func checkHost(address: String, httpsPort: Int, serverCert: Data) async -> (status: HostStatus, info: ServerInfo?) {
    if !serverCert.isEmpty,
       let info = try? await fetchPairedServerInfo(address: address, httpsPort: httpsPort, serverCert: serverCert, timeout: 2) {
        return (.online(paired: info.pairStatus == .paired), info)
    }
    if let info = try? await fetchServerInfo(address: address, timeout: 2) {
        return (.online(paired: false), info)
    }
    return (.offline, nil)
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
    init(tls: PairedTLS) { self.tls = tls }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust,
                  let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
                  SecCertificateCopyData(leaf) as Data == tls.serverCert
            else { return completionHandler(.cancelAuthenticationChallenge, nil) }
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
