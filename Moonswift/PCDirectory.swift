import SwiftData
import SwiftUI

/// A PC to stream from: its saved details and the address that answered last.
nonisolated struct PCRef: Sendable {
    let id: String
    let name: String
    var client: HostClient
    let localAddress: String
    let remoteAddress: String?
}

/// Every saved PC's live state, checked every 3 seconds for the whole app (any tab can read it): online or not,
/// which address answers, which game it's running, whether it can be put to sleep.
@Observable final class PCDirectory {
    private(set) var statuses: [String: HostStatus] = [:] // by uniqueID; missing = not checked yet
    private(set) var activeAddresses: [String: String] = [:] // by uniqueID: the address that last answered
    private(set) var playing: [String: Int] = [:] // by uniqueID: the running game's ID (0 or missing: none)
    private(set) var sleepable: Set<String> = [] // PCs that let this device put them to sleep
    @ObservationIgnored private var misses: [String: Int] = [:] // checks in a row that found it offline
    @ObservationIgnored private var checkedPublicIP: Set<String> = [] // public IP looked up this launch

    #if DEBUG
    func setDemo(pcID: String, running: Int) {
        statuses[pcID] = .online(paired: true)
        playing[pcID] = running
    }
    #endif

    func isAvailable(_ id: String) -> Bool { statuses[id] == .online(paired: true) }

    func ref(_ host: SavedHost) -> PCRef {
        PCRef(id: host.uniqueID, name: host.displayName,
              client: HostClient(hostID: host.uniqueID, address: activeAddresses[host.uniqueID] ?? host.address,
                                 httpsPort: host.httpsPort, serverCert: host.serverCert),
              localAddress: host.address, remoteAddress: host.remoteAddress)
    }

    /// Like moonlight-ios's DiscoveryWorker: ask every saved host for /serverinfo on a loop.
    func poll(_ hosts: [SavedHost], context: ModelContext) async {
        #if DEBUG
        if DemoMode.isOn { return }
        #endif
        while !Task.isCancelled {
            await checkAll(hosts, context: context)
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// Asks every saved PC for its status once. `isManual` (pull to refresh) reports exactly what it finds; the
    /// background loop forgives a single missed check.
    func checkAll(_ hosts: [SavedHost], context: ModelContext, isManual: Bool = false) async {
        let targets = hosts.map { (id: $0.uniqueID, address: $0.address, remote: $0.remoteAddress,
                                   httpsPort: $0.httpsPort, serverCert: $0.serverCert) }
        await withTaskGroup(of: (String, HostStatus, ServerInfo?, String?).self) { group in
            for target in targets {
                group.addTask {
                    let result = await checkHost(address: target.address, remoteAddress: target.remote,
                                                 httpsPort: target.httpsPort, serverCert: target.serverCert)
                    return (target.id, result.status, result.info, result.address)
                }
            }
            for await (id, status, info, address) in group {
                // One missed check (a slow cellular wake-up, a dropped packet) isn't enough to call a PC offline.
                if !isManual, status == .offline, let previous = statuses[id], previous != .offline, misses[id, default: 0] < 1 {
                    misses[id, default: 0] += 1
                    continue
                }
                misses[id] = 0
                statuses[id] = status
                activeAddresses[id] = address
                playing[id] = info?.currentGame
                if info?.canSleep == true { sleepable.insert(id) } else if info != nil { sleepable.remove(id) }
                guard let host = hosts.first(where: { $0.uniqueID == id }) else { continue }
                if let info, host.name != info.hostname { host.name = info.hostname } // PC was renamed
                if status == .online(paired: true), address == host.address { learnPublicIP(for: host, context: context) }
            }
        }
    }

    /// While a PC answers on its home address, the phone is on its network, so this network's public IP is the PC's.
    // shortcut: a VPN that routes the home subnet would make a remote network look like home; ignore until it matters.
    private func learnPublicIP(for host: SavedHost, context: ModelContext) {
        guard !checkedPublicIP.contains(host.uniqueID) else { return }
        checkedPublicIP.insert(host.uniqueID)
        Task {
            guard let publicIP = await Task.detached(operation: { findPublicIPv4() }).value,
                  publicIP != host.remoteAddress else { return }
            host.remoteAddress = publicIP
            try? context.save()
        }
    }
}
