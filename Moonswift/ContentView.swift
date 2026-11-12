import SwiftData
import SwiftUI

/// Home screen: paired PCs with live status and the game each is running, "Pair a New PC" and Settings. Touch or
/// controller: up/down to move, A to open (or pair), Y/X (or a long press) for a PC's menu: Edit (name, addresses) or Remove.
struct ContentView: View {
    struct PairTarget: Identifiable {
        let address: String
        let name: String
        var id: String { address }
    }

    /// One focusable row, in screen order.
    private enum Item {
        case saved(SavedHost)
        case add

        var id: String {
            switch self {
            case .saved(let host): "saved-\(host.uniqueID)"
            case .add: "add"
            }
        }
    }

    @Environment(\.modelContext) private var context
    @Environment(GamepadInput.self) private var gamepad
    @Query(sort: \SavedHost.name) private var hosts: [SavedHost]
    @State private var statuses: [String: HostStatus] = [:] // by uniqueID; missing = not checked yet
    @State private var activeAddresses: [String: String] = [:] // by uniqueID: the address that last answered
    @State private var misses: [String: Int] = [:] // by uniqueID: checks in a row that found it offline
    @State private var checkedPublicIP: Set<String> = [] // hosts whose public IP was looked up this launch
    @State private var editing: SavedHost? // the PC whose Edit page is open
    @State private var playing: [String: Int] = [:] // by uniqueID: the running game's ID (0 or missing: none)
    @State private var gameTitles: [String: [Int: String]] = [:] // by uniqueID: game titles, looked up when one runs
    @State private var isAdding = false
    @State private var isShowingSettings = false
    @State private var pairing: PairTarget?
    @State private var path: [String] = [] // uniqueIDs of opened PCs
    @State private var focus = 0
    @State private var menu: MenuSpec?

    /// Must match the on-screen order, or up/down feel inverted.
    private var items: [Item] { hosts.map(Item.saved) + [.add] }
    private var focusIndex: Int { min(focus, items.count - 1) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { scroller in
                List {
                    Section("My PCs") {
                        if hosts.isEmpty {
                            Text("No paired PCs yet.").foregroundStyle(.secondary)
                        }
                        ForEach(hosts) { host in
                            let active = activeAddresses[host.uniqueID] ?? host.address
                            row(.saved(host)) {
                                HostRow(name: host.displayName, address: active, status: statuses[host.uniqueID],
                                        isRemote: active != host.address, playing: playingTitle(host))
                            }
                            .contextMenu { // touch's way to the PC menu (a controller uses Y)
                                Button("Edit…", systemImage: "pencil") { editing = host }
                                Button("Remove PC…", systemImage: "trash", role: .destructive) { confirmRemove(host) }
                            }
                        }
                        .onDelete { offsets in
                            if let index = offsets.first { confirmRemove(hosts[index]) }
                        }
                        row(.add) {
                            Label("Pair a New PC", systemImage: "plus.circle")
                        }
                    }
                }
                .refreshable { await checkAll(isManual: true) } // pull down: fresh status now
                .onChange(of: focusIndex) { withAnimation { scroller.scrollTo(items[focusIndex].id) } }
            }
            .tint(.primary) // rows are buttons, but shouldn't look like links
            .safeAreaInset(edge: .bottom) { ControllerHints(hints: [([.y], "PC Menu"), ([.menu], "Settings")]) }
            .navigationTitle("Moonswift")
            .navigationDestination(for: String.self) { id in
                if let host = hosts.first(where: { $0.uniqueID == id }) {
                    AppLibraryView(client: HostClient(hostID: host.uniqueID, address: activeAddresses[id] ?? host.address,
                                                      httpsPort: host.httpsPort, serverCert: host.serverCert),
                                   name: host.displayName, localAddress: host.address, remoteAddress: host.remoteAddress)
                }
            }
            .sheet(isPresented: $isAdding) { AddHostView() }
            .sheet(isPresented: $isShowingSettings) { SettingsView() }
            .toolbar {
                // On iPhone Duo this sits in the side rail; elsewhere, top right. A controller uses its Menu button.
                Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
            }
            .sheet(item: $pairing) { target in
                NavigationStack {
                    PairingView(address: target.address, name: target.name) { pairing = nil }
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pairing = nil } }
                        }
                }
            }
            .onGamepad { command in
                switch command {
                case .up, .down: focus = FocusMove.next(focusIndex, count: items.count, columns: 1, command)
                case .select: activate(items[focusIndex])
                case .menu, .alternate: showMenu(items[focusIndex])
                case .settings: isShowingSettings = true
                case .left, .right, .back, .streamMenu, .options, .previousTab, .nextTab: break
                }
            }
            .actionMenu($menu)
            .sheet(item: $editing) { EditPCView(host: $0) }
            // Restarts at once when a host is added, removed, (re)paired or gets a new address.
            .task(id: hosts.map { "\($0.uniqueID)|\($0.serverCert.count)|\($0.address)|\($0.remoteAddress ?? "")" }) { await pollStatus() }
        }
    }

    /// A tappable row with the controller focus highlight.
    private func row(_ item: Item, @ViewBuilder label: () -> some View) -> some View {
        let index = items.firstIndex { $0.id == item.id } ?? 0
        let isFocused = gamepad.isActive && index == focusIndex
        return Button {
            focus = index
            activate(item)
        } label: {
            label()
        }
        .id(item.id)
        .listRowBackground(isFocused ? Color.accentColor.opacity(0.25) : Color(.secondarySystemGroupedBackground))
        .animation(.snappy(duration: 0.15), value: isFocused)
    }

    private func activate(_ item: Item) {
        switch item {
        case .saved(let host):
            switch statuses[host.uniqueID] {
            case .online(paired: true)?: path.append(host.uniqueID)
            case .online(paired: false)?: pairing = PairTarget(address: host.address, name: host.displayName)
            case .offline?, nil: break // shortcut: nothing to do for an offline PC until Wake-on-LAN exists.
            }
        case .add:
            isAdding = true
        }
    }

    private func showMenu(_ item: Item) {
        guard case .saved(let host) = item else { return }
        var actions: [MenuSpec.Action] = []
        if statuses[host.uniqueID] == .online(paired: true) {
            actions.append(.init(title: "Open") { path.append(host.uniqueID) })
        }
        actions.append(.init(title: "Edit…") { editing = host })
        actions.append(.init(title: "Remove PC…", isDestructive: true) { confirmRemove(host) })
        let message = host.address + (host.remoteAddress.map { " · remote \($0)" } ?? "")
        menu = MenuSpec(title: host.displayName, message: message, actions: actions)
    }

    private func confirmRemove(_ host: SavedHost) {
        let isPaired = !host.serverCert.isEmpty
        menu = MenuSpec(title: "Remove \(host.displayName)?",
                        message: isPaired ? "This device is also unpaired on the PC. Adding it again needs a new PIN." : nil,
                        actions: [.init(title: "Remove PC", isDestructive: true) { Task { await remove(host) } }])
    }

    /// Unpairs on the PC when it answers, then forgets it here.
    private func remove(_ host: SavedHost) async {
        var unpairedOnPC = host.serverCert.isEmpty // nothing to undo on a PC that was never paired
        if !unpairedOnPC {
            let client = HostClient(hostID: host.uniqueID, address: activeAddresses[host.uniqueID] ?? host.address,
                                    httpsPort: host.httpsPort, serverCert: host.serverCert)
            unpairedOnPC = (try? await client.unpair()) != nil
        }
        let name = host.displayName
        context.delete(host)
        try? context.save()
        if !unpairedOnPC {
            menu = .error("\(name) was removed here, but it couldn't be reached to unpair. It still lists this device; "
                          + "remove it in the PC's streaming software to stop it from connecting.")
        }
    }

    /// While a PC answers on its home address, the phone is on its network, so this network's public IP is the PC's.
    // shortcut: a VPN that routes the home subnet would make a remote network look like home; ignore until it matters.
    private func learnPublicIP(for host: SavedHost) {
        guard !checkedPublicIP.contains(host.uniqueID) else { return }
        checkedPublicIP.insert(host.uniqueID)
        Task {
            guard let publicIP = await Task.detached(operation: { findPublicIPv4() }).value,
                  publicIP != host.remoteAddress else { return }
            host.remoteAddress = publicIP
            try? context.save()
        }
    }

    /// "Hades" when the PC is running it, once its game list has been fetched.
    private func playingTitle(_ host: SavedHost) -> String? {
        guard let game = playing[host.uniqueID], game != 0 else { return nil }
        return gameTitles[host.uniqueID]?[game] ?? Self.unknownGame
    }

    private static let unknownGame = "a game"

    /// Fetches the PC's game list for the running game's title (only when a game the app hasn't seen starts).
    private func lookUpTitles(for host: SavedHost, at address: String, running game: Int) {
        let id = host.uniqueID
        gameTitles[id, default: [:]][game] = Self.unknownGame // so the next check (in 3 s) doesn't ask again
        let client = HostClient(hostID: id, address: address, httpsPort: host.httpsPort, serverCert: host.serverCert)
        Task {
            guard let apps = try? await client.apps() else { return gameTitles[id]?[game] = nil } // try again next check
            var titles = Dictionary(apps.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
            titles[game] = titles[game] ?? Self.unknownGame // a game missing from the list isn't looked up again
            gameTitles[id] = titles
        }
    }

    /// Like moonlight-ios's DiscoveryWorker: ask every saved host for /serverinfo on a loop.
    private func pollStatus() async {
        while !Task.isCancelled {
            await checkAll()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// Asks every saved PC for its status once. `isManual` (pull to refresh) reports exactly what it finds;
    /// the background loop forgives a single missed check.
    private func checkAll(isManual: Bool = false) async {
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
                guard let host = hosts.first(where: { $0.uniqueID == id }) else { continue }
                if let info, host.name != info.hostname { host.name = info.hostname } // PC was renamed
                playing[id] = info?.currentGame
                if let game = info?.currentGame, game != 0, gameTitles[id]?[game] == nil, let address { lookUpTitles(for: host, at: address, running: game) }
                if status == .online(paired: true), address == host.address { learnPublicIP(for: host) }
            }
        }
    }
}

private struct HostRow: View {
    let name: String
    let address: String
    let status: HostStatus?
    let isRemote: Bool
    let playing: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(name)
                if let playing {
                    Text("\(Image(systemName: "play.fill")) Streaming \(playing)").font(.caption).foregroundStyle(.green)
                }
                Text(address).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch status {
            case nil:
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            case .offline?:
                Text("\(Image(systemName: "circle.fill")) Offline").foregroundStyle(.red)
            case .online(let paired)?:
                Text(paired ? "\(Image(systemName: "lock.fill")) Paired" : "\(Image(systemName: "lock.open")) Not paired")
                    .foregroundStyle(paired ? Color.primary : .orange)
                Text("\(Image(systemName: isRemote ? "globe" : "circle.fill")) \(isRemote ? "Remote" : "Online")").foregroundStyle(.green)
                if paired { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: SavedHost.self, inMemory: true)
        .environment(GamepadInput())
}
