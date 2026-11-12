import SwiftData
import SwiftUI

/// The PCs tab: paired PCs with live status and the game each is running, "Pair a New PC" and Settings. Opening a
/// PC shows its own game list. Touch or controller: up/down to move, A to open (or pair), Y/X (or a long press) for a
/// PC's menu: Sleep, Edit (name, addresses) or Remove.
struct PCsView: View {
    var openSettings: () -> Void = {}
    var switchTab: (Int) -> Void = { _ in }

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
    @Environment(PCDirectory.self) private var directory
    @Environment(GameCatalog.self) private var catalog
    @Query(sort: \SavedHost.name) private var hosts: [SavedHost]
    @State private var editing: SavedHost? // the PC whose Edit page is open
    @State private var isAdding = false
    @State private var pairing: PairTarget?
    @State private var path: [String] = [] // uniqueIDs of opened PCs
    @State private var focus = 0
    @State private var menu: MenuSpec?
    @State private var topInset: CGFloat = 0
    private var statuses: [String: HostStatus] { directory.statuses }
    private var activeAddresses: [String: String] { directory.activeAddresses }
    private var sleepable: Set<String> { directory.sleepable }

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
                                if sleepable.contains(host.uniqueID) {
                                    Button("Sleep PC…", systemImage: "moon.zzz") { confirmSleep(host) }
                                }
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
                .refreshable { await directory.checkAll(hosts, context: context, isManual: true) } // pull down: fresh status now
                .onChange(of: focusIndex) { withAnimation { scroller.scrollTo(items[focusIndex].id) } }
            }
            .tint(.primary) // rows are buttons, but shouldn't look like links
            .safeAreaInset(edge: .bottom) { ControllerHints(hints: [([.y], "PC Menu"), ([.menu], "Settings")]) }
            .navigationTitle("PCs")
            .toolbar(.hidden, for: .navigationBar) // the title is TabTitle, placed like Home's
            .safeAreaInset(edge: .top, spacing: 0) { // the tab's title, fixed and placed like every tab's
                TabTitle(text: "PCs", topInset: topInset).padding(.horizontal, 36).padding(.bottom, 4).background(Color.black)
            }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
            .navigationDestination(for: String.self) { id in
                if let host = hosts.first(where: { $0.uniqueID == id }) {
                    AppLibraryView(client: HostClient(hostID: host.uniqueID, address: activeAddresses[id] ?? host.address,
                                                      httpsPort: host.httpsPort, serverCert: host.serverCert),
                                   name: host.displayName, localAddress: host.address, remoteAddress: host.remoteAddress)
                }
            }
            .sheet(isPresented: $isAdding) { AddHostView() }
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
                case .settings: openSettings()
                case .previousTab: switchTab(-1)
                case .nextTab: switchTab(1)
                case .left, .right, .back, .streamMenu, .options: break
                }
            }
            .actionMenu($menu)
            .sheet(item: $editing) { EditPCView(host: $0) }
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
        if sleepable.contains(host.uniqueID) { actions.append(.init(title: "Sleep PC…") { confirmSleep(host) }) }
        actions.append(.init(title: "Edit…") { editing = host })
        actions.append(.init(title: "Remove PC…", isDestructive: true) { confirmRemove(host) })
        let message = host.address + (host.remoteAddress.map { " · remote \($0)" } ?? "")
        menu = MenuSpec(title: host.displayName, message: message, actions: actions)
    }

    /// The PC only sleeps when asked deliberately, once per confirmation; a failure needs a new confirmation.
    private func confirmSleep(_ host: SavedHost) {
        let name = host.displayName
        menu = MenuSpec(title: "Put \(name) to sleep?", message: "Quit any running game first. Wake it with its power button or keyboard.",
                        actions: [.init(title: "Sleep") {
            let client = HostClient(hostID: host.uniqueID, address: activeAddresses[host.uniqueID] ?? host.address,
                                    httpsPort: host.httpsPort, serverCert: host.serverCert)
            Task {
                do {
                    try await client.sleep()
                } catch {
                    menu = .error(error.localizedDescription)
                }
            }
        }])
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
        catalog.forget(host.uniqueID)
        context.delete(host)
        try? context.save()
        if !unpairedOnPC {
            menu = .error("\(name) was removed here, but it couldn't be reached to unpair. It still lists this device; "
                          + "remove it in the PC's streaming software to stop it from connecting.")
        }
    }

    /// "Hades" when the PC is running it, once its game list has been fetched.
    private func playingTitle(_ host: SavedHost) -> String? {
        guard let game = directory.playing[host.uniqueID], game != 0 else { return nil }
        return catalog.title(of: game, on: host.uniqueID) ?? Self.unknownGame
    }

    private static let unknownGame = "a game"

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

