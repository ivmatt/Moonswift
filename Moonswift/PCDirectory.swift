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

/// Every saved PC's live state, checked every 2 seconds for the whole app (any tab can read it): online or not,
/// which address answers, which game it's running, whether it can be put to sleep.
@Observable final class PCDirectory {
    private(set) var statuses: [String: HostStatus] = [:] // by uniqueID; missing = not checked yet
    private(set) var activeAddresses: [String: String] = [:] // by uniqueID: the address that last answered
    /// What each PC last said it's running, by uniqueID (0 or missing: nothing).
    private(set) var reportedPlaying: [String: Int] = [:]
    /// The game this device streamed and hasn't quit (`StreamLauncher.session`): running, even when one check comes
    /// back empty. The PC naming a different game overrules it, and so do two empty answers in a row, which clear it
    /// (the game was ended from another device, or the PC restarted).
    var session: StreamingGame? { didSet { if session != oldValue { sessionIdleReadings = 0 } } }
    @ObservationIgnored private var sessionIdleReadings = 0
    /// The running game's ID by PC (0 or missing: none).
    var playing: [String: Int] {
        var playing = reportedPlaying
        if let session, (reportedPlaying[session.pcID] ?? 0) == 0 { playing[session.pcID] = session.appID }
        return playing
    }
    private(set) var sleepable: Set<String> = [] // PCs that let this device put them to sleep
    /// When each PC last answered, or was last found offline: Home's status says "checked 5s ago".
    private(set) var lastChecked: [String: Date] = [:]
    /// PCs that missed one check: they keep their status (one miss isn't enough), and Home's status says "Not
    /// responding…".
    private(set) var notResponding: Set<String> = []
    /// PCs being checked again because what's known may be out of date: a Refresh, a stream ending, coming back to the
    /// app, or a new network. Play, Resume and Quit wait for the answer (`isUncertain`).
    private(set) var rechecking: Set<String> = []
    /// The wait between checks: short while a tab shows, longer under Settings (RootView sets it).
    @ObservationIgnored var interval: Duration = .seconds(2)
    /// No checks while the app's in the background or a stream is open: its own link knows whether the PC is there.
    @ObservationIgnored var isPaused = false
    @ObservationIgnored private var isChecking = false
    @ObservationIgnored private var misses: [String: Int] = [:] // checks in a row that found it offline
    @ObservationIgnored private var idleReadings: [String: Int] = [:] // checks in a row that found no game running
    @ObservationIgnored private var checkedPublicIP: Set<String> = [] // public IP looked up this launch

    #if DEBUG
    func setDemo(pcID: String, running: Int) {
        statuses[pcID] = .online(paired: true)
        lastChecked[pcID] = .now
        reportedPlaying[pcID] = running
    }
    #endif

    /// This device just quit the PC's game and the PC confirmed it: Play shows at once, without waiting for two checks.
    func noteNothingRunning(on pcID: String) {
        reportedPlaying[pcID] = 0
        idleReadings[pcID] = 0
        if session?.pcID == pcID { session = nil }
    }

    /// One check's answer about what a PC runs. A single "nothing running" while a game was isn't trusted (the PC can
    /// answer between two games) until the next check agrees; a refresh you asked for is trusted at once.
    nonisolated static func reading(game: Int, shown: Int, emptyInARow: Int, isManual: Bool) -> (shown: Int, emptyInARow: Int) {
        if !isManual, game == 0, shown != 0, emptyInARow < 1 { return (shown, emptyInARow + 1) }
        return (game, 0)
    }

    /// This device's own session is over once its PC has said "nothing running" twice in a row (the game was ended
    /// elsewhere, or the PC restarted); any game in between starts the count again.
    nonisolated static func sessionReading(game: Int, emptyInARow: Int) -> (emptyInARow: Int, isOver: Bool) {
        let count = game == 0 ? emptyInARow + 1 : 0
        return (count, count >= 2)
    }

    func isAvailable(_ id: String) -> Bool { statuses[id] == .online(paired: true) }

    /// Its status isn't confirmed yet, so acting on it could be wrong.
    func isUncertain(_ id: String) -> Bool {
        Self.isUncertain(status: statuses[id], isRechecking: rechecking.contains(id), isNotResponding: notResponding.contains(id))
    }

    nonisolated static func isUncertain(status: HostStatus?, isRechecking: Bool, isNotResponding: Bool) -> Bool {
        status == nil || isRechecking || isNotResponding
    }

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
            if !isPaused { await checkAll(hosts, context: context) }
            try? await Task.sleep(for: isPaused ? .seconds(1) : interval)
        }
    }

    /// Back in the app or on a new network: every PC is uncertain until a check that starts from now answers. One
    /// already out asked too early to count, so it finishes first.
    func recheck(_ hosts: [SavedHost], context: ModelContext) async {
        #if DEBUG
        if DemoMode.isOn { return }
        #endif
        rechecking.formUnion(hosts.map(\.uniqueID))
        while isChecking { try? await Task.sleep(for: .milliseconds(100)) }
        await checkAll(hosts, context: context)
    }

    /// Asks every saved PC for its status once. `isManual` (pull to refresh) reports exactly what it finds; the
    /// background loop forgives a single missed check.
    func checkAll(_ hosts: [SavedHost], context: ModelContext, isManual: Bool = false) async {
        #if DEBUG
        if DemoMode.isOn { return } // the pretend PC can't answer, and would turn offline
        #endif
        if isManual { rechecking.formUnion(hosts.map(\.uniqueID)) }
        // A check on top of one still out would count the same missed answer twice.
        if !isManual, isChecking { return }
        isChecking = true
        defer { isChecking = false }
        let confirming = rechecking // only a check started after a PC was marked can clear it
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
                if confirming.contains(id) { rechecking.remove(id) }
                // One missed check (a slow cellular wake-up, a dropped packet) isn't enough to call a PC offline. Nor is
                // a paired PC answering only the plain request: its secure one timed out (busy right after a stream),
                // and the plain answer never names the running game, so trusting it flips Resume back to Play.
                let isMiss = status == .offline || status == .online(paired: false) && statuses[id] == .online(paired: true)
                if !isManual, isMiss, let previous = statuses[id], previous != .offline, misses[id, default: 0] < 1 {
                    misses[id, default: 0] += 1
                    notResponding.insert(id)
                    continue
                }
                misses[id] = 0
                notResponding.remove(id)
                lastChecked[id] = .now
                statuses[id] = status
                activeAddresses[id] = address
                let game = info?.currentGame ?? 0
                let reading = Self.reading(game: game, shown: reportedPlaying[id] ?? 0, emptyInARow: idleReadings[id] ?? 0,
                                           isManual: isManual)
                (reportedPlaying[id], idleReadings[id]) = (reading.shown, reading.emptyInARow)
                if let session, session.pcID == id, status == .online(paired: true) {
                    let ended = Self.sessionReading(game: game, emptyInARow: sessionIdleReadings)
                    sessionIdleReadings = ended.emptyInARow
                    if ended.isOver { self.session = nil }
                }
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

/// A game being streamed to this device, and the PC it's on.
nonisolated struct StreamingGame: Equatable, Sendable {
    let pcID: String
    let appID: Int
}
