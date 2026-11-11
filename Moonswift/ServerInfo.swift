import Foundation

/// What a Sunshine/Vibepollo host reports at GET /serverinfo.
nonisolated struct ServerInfo: Equatable {
    enum PairStatus { case paired, unpaired, unknown }

    let hostname: String
    let uniqueID: String?
    let httpsPort: Int
    let pairStatus: PairStatus

    /// Parses `<root status_code="200"><hostname>…</hostname>…</root>`.
    init(xml: Data) throws(ServerInfoError) {
        let collector = RootCollector()
        let parser = XMLParser(data: xml)
        parser.delegate = collector
        guard parser.parse(), let code = collector.rootAttributes["status_code"] else {
            throw .malformedResponse
        }
        guard code == "200" else {
            throw .hostError(code: Int(code) ?? -1, message: collector.rootAttributes["status_message"] ?? "Server error")
        }
        let fields = collector.fields
        guard let hostname = fields["hostname"], !hostname.isEmpty else { throw .malformedResponse }

        self.hostname = hostname
        uniqueID = fields["uniqueid"]
        httpsPort = fields["HttpsPort"].flatMap { Int($0) } ?? 47984 // same default as moonlight-ios
        pairStatus = switch fields["PairStatus"].flatMap({ Int($0) }) {
        case nil: .unknown
        case 0: .unpaired
        default: .paired
        }
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
        case .malformedResponse: "The host's reply wasn't valid serverinfo XML."
        }
    }
}

/// Builds http://<host>:<port>/serverinfo from user input like "10.0.4.20" or "10.0.4.20:47989".
nonisolated func serverInfoURL(for address: String) throws(ServerInfoError) -> URL {
    let trimmed = address.trimmingCharacters(in: .whitespaces)
    // shortcut: bare IPv6 addresses aren't accepted (they need [brackets]), add when IPv6 hosts matter.
    guard var components = URLComponents(string: "http://\(trimmed)"),
          let host = components.host, !host.isEmpty,
          components.path.isEmpty, components.query == nil, components.user == nil
    else { throw .invalidAddress }
    components.port = components.port ?? 47989
    components.path = "/serverinfo"
    guard let url = components.url else { throw .invalidAddress }
    return url
}

/// Default timeout is moonlight-ios's NORMAL_TIMEOUT_SEC; status polling uses its 2s SHORT_TIMEOUT_SEC.
func fetchServerInfo(address: String, timeout: TimeInterval = 5) async throws(ServerInfoError) -> ServerInfo {
    var request = URLRequest(url: try serverInfoURL(for: address))
    request.timeoutInterval = timeout

    let data: Data, response: URLResponse
    do {
        (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
    } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
        throw .insecureBlocked
    } catch {
        throw .unreachable(error.localizedDescription)
    }

    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
        throw .httpStatus(http.statusCode)
    }
    return try ServerInfo(xml: data)
}

/// Collects the root's attributes and the text of its direct children into a flat dictionary,
/// the same shape moonlight-ios's HttpResponse builds.
private nonisolated final class RootCollector: NSObject, XMLParserDelegate {
    var rootAttributes: [String: String] = [:]
    var fields: [String: String] = [:]
    private var depth = 0
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        depth += 1
        if depth == 1 { rootAttributes = attributes }
        if depth == 2 { text = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if depth == 2 { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if depth == 2 { fields[name] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        depth -= 1
    }
}
