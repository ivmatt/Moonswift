import Foundation
import Network
import Observation

/// Finds Sunshine/Vibepollo hosts advertising `_nvstream._tcp` over Bonjour, the same service moonlight-ios browses.
@Observable final class HostDiscovery {
    struct Found: Identifiable {
        let address: String
        let info: ServerInfo
        var id: String { info.uniqueID ?? address }
    }

    private var byService: [String: Found] = [:]
    @ObservationIgnored private var listed: Set<String> = []
    @ObservationIgnored private var resolving: Set<String> = []
    @ObservationIgnored private var browser: NWBrowser?
    /// Local Network access was denied: nothing will be found until it's turned back on in Settings.
    var isDenied = false

    var found: [Found] {
        #if DEBUG
        if DemoMode.isFirstRun, let info = try? ServerInfo(fields: ["hostname": "Mock PC", "uniqueid": DemoMode.pcID]) {
            return [Found(address: DemoMode.mockAddress, info: info)]
        }
        #endif
        return byService.values.sorted { $0.info.hostname < $1.info.hostname }
    }

    /// Stops browsing (Add PC closed): the app only searches the network while you're adding a PC.
    func stop() {
        browser?.cancel()
        browser = nil
    }

    func start() {
        #if DEBUG
        if DemoMode.isFirstRun { return }
        #endif
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_nvstream._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(results) } // handlers run on .main, set below
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .waiting(let error), .failed(let error): if isLocalNetworkDenied(error) { self?.isDenied = true }
                case .ready: self?.isDenied = false // turned back on in Settings: the browser carries on by itself
                default: break
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var endpoints: [String: NWEndpoint] = [:]
        for result in results {
            if case .service(let name, _, _, _) = result.endpoint { endpoints[name] = result.endpoint }
        }
        listed = Set(endpoints.keys)
        byService = byService.filter { listed.contains($0.key) }

        // shortcut: a host that fails to resolve isn't retried until Bonjour reports a change; add a retry if that bites.
        for (name, endpoint) in endpoints where byService[name] == nil && !resolving.contains(name) {
            resolving.insert(name)
            Task {
                let found = await Self.resolve(endpoint)
                resolving.remove(name)
                if let found, listed.contains(name) { byService[name] = found }
            }
        }
    }

    /// Bonjour gives a service name, not an IP: connect once to learn the IPv4 address, then ask it for serverinfo.
    private static func resolve(_ endpoint: NWEndpoint) async -> Found? {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4

        let connection = NWConnection(to: endpoint, using: parameters)
        let address: String? = await withCheckedContinuation { continuation in
            connection.stateUpdateHandler = { state in
                let address: String?
                switch state {
                case .ready:
                    // Built from raw bytes: describing the host gives "10.0.4.20%en0", which isn't a valid URL host.
                    if case .hostPort(.ipv4(let ip), let port)? = connection.currentPath?.remoteEndpoint {
                        let host = ip.rawValue.map(String.init).joined(separator: ".")
                        address = port.rawValue == 47989 ? host : "\(host):\(port.rawValue)"
                    } else {
                        address = nil
                    }
                case .waiting, .failed:
                    address = nil
                default:
                    return
                }
                connection.stateUpdateHandler = nil // resume exactly once
                connection.cancel()
                continuation.resume(returning: address)
            }
            connection.start(queue: .main)
        }

        guard let address, let info = try? await fetchServerInfo(address: address, timeout: 2) else { return nil }
        return Found(address: address, info: info)
    }
}
