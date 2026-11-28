import SwiftData
import SwiftUI

/// The Hosts tab: saved hosts with live status and the game each is running, "Add a New Host" and Settings. Tapping a
/// host opens its Edit page (name, addresses), or pairing for one that needs it. Touch or controller: up/down to
/// move, A to open, Y/X (or a long press) for a host's menu: Wake, Sleep, Edit or Remove.
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
    @State private var focus = 0
    @State private var menu: MenuSpec?
    @State private var topInset: CGFloat = 0
    @State private var insets = EdgeInsets()
    @State private var width: CGFloat = 0
    private var statuses: [String: HostStatus] { directory.statuses }
    private var activeAddresses: [String: String] { directory.activeAddresses }
    private var sleepable: Set<String> { directory.sleepable }

    /// Must match the on-screen order, or up/down feel inverted.
    private var items: [Item] { hosts.map(Item.saved) } // none: the app shows only its welcome (RootView)
    private var focusIndex: Int { max(0, min(focus, items.count - 1)) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
                List {
                    Section { } header: { TabTitle(text: "Hosts", topInset: topInset).asListHeader() }
                    // A card each, no heading: the page's title says what they are.
                    ForEach(hosts) { host in
                        Section {
                            let active = activeAddresses[host.uniqueID] ?? host.address
                            row(.saved(host)) {
                                HostRow(name: host.displayName, address: directory.connection(of: host.uniqueID).map { "\($0) · \(active)" } ?? active,
                                        status: statuses[host.uniqueID],
                                        line: PCStatusButton.line(host, directory: directory, catalog: catalog, now: nil),
                                        wasPaired: !host.serverCert.isEmpty, playing: playingTitle(host),
                                        isElsewhere: catalog.remoteSession(on: host.uniqueID).map { !$0.isOwn } ?? false)
                            }
                            .contextMenu { // touch's way to the PC menu (a controller uses Y)
                                if offersWake(host) {
                                    Button("Wake Host", systemImage: "power") { wake(host) }
                                }
                                if sleepable.contains(host.uniqueID) {
                                    Button("Sleep Host…", systemImage: "moon.zzz") { confirmSleep(host) }
                                }
                                Button("Edit…", systemImage: "pencil") { editing = host }
                                Button("Remove Host…", systemImage: "trash", role: .destructive) { confirmRemove(host) }
                            }
                            // Swipe left: Delete, as across iOS (it asks first, since it also unpairs).
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                // Red, but not the destructive role: that hides the row at once, before the user confirms.
                                Button("Delete", systemImage: "trash") { confirmRemove(host) }.tint(.red)
                            }
                        }
                    }
                }
                // The cards start at the title's edge, 36 points in, and stop at a readable width on a big iPad.
                // A list's margins count from the screen's edge, the safe area only a minimum, so the window's
                // inset is added: the cards start at the title's edge, and end as far in on the other side.
                .contentMargins(.leading, 36 + insets.leading, for: .scrollContent)
                .contentMargins(.trailing, max(36 + insets.trailing, width - 36 - insets.leading - HomeView.readableWidth), for: .scrollContent)
                .onGeometryChange(for: CGFloat.self) { $0.size.width + $0.safeAreaInsets.leading + $0.safeAreaInsets.trailing } action: { width = $0 }
                // iPhone: from the window's top, like Library's wall. Under the bar's room, the title had further to
                // move up than it is tall, so it stopped about 20 points low with a gap above the cards. iPad's tab bar
                // keeps its room.
                .ignoresSafeArea(edges: UIDevice.current.userInterfaceIdiom == .pad ? [] : .top)
                .refreshable { await directory.checkAll(hosts, context: context, isManual: true) } // pull down: fresh status now
                .onChange(of: focusIndex) { if items.indices.contains(focusIndex) { withAnimation { scroller.scrollTo(items[focusIndex].id) } } }
            }
            .tint(.primary) // rows are buttons, but shouldn't look like links
            .hidesTabBarOnPhone(gamepad.isActive && focusIndex > 0).buttonLegend([([.y], "Host Menu"), ([.view], "Add Host"), ([.l1, .r1], "Tabs"), ([.menu], "Settings")])
            .navigationTitle("") // the title is TabTitle, placed like Home's; the bar holds only the gear
            .toolbar {
                TabToolbar(hasTopBar: TabToolbar<EmptyView>.hasTopBar(insets: insets), openSettings: openSettings) {
                    Button("Add Host", systemImage: "plus") { isAdding = true }
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            // iPhone: the list runs up under the bar (above), where the system's edge blur covered the title at rest;
            // the title blurs itself as it goes, as Library's does.
            .scrollEdgeEffectHidden(UIDevice.current.userInterfaceIdiom != .pad, for: .top)
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets = $0 }
            .addHostCover(isPresented: $isAdding)
            .sheet(item: $pairing) { target in
                NavigationStack {
                    PairingView(address: target.address, name: target.name) { _, _ in pairing = nil }
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pairing = nil } }
                        }
                }
            }
            .onGamepad { command in
                switch command {
                case .up, .down: focus = FocusMove.next(focusIndex, count: items.count, columns: 1, command)
                case .select: if items.indices.contains(focusIndex) { activate(items[focusIndex]) }
                case .menu, .alternate: if items.indices.contains(focusIndex) { showMenu(items[focusIndex]) }
                case .settings: openSettings()
                case .options: isAdding = true // View: Add Host
                case .previousTab: switchTab(-1)
                case .nextTab: switchTab(1)
                case .left, .right, .back, .streamMenu: break
                }
            }
            .actionMenu($menu)
            .sheet(item: $editing) { host in EditPCView(host: host) { confirmRemove(host) } }
            .ignoresSafeArea(.keyboard) // a sheet's keyboard mustn't move the page behind it
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
        // Its own rounded card, so a swipe moves a rounded card (the list's clipping went square as it slid).
        .listRowBackground(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(isFocused ? Color.accentColor.opacity(0.25) : Color(.secondarySystemGroupedBackground)))
        .animation(.snappy(duration: 0.15), value: isFocused)
        .id(item.id) // outermost: under the row background a list doesn't find it to scroll to
    }

    private func activate(_ item: Item) {
        switch item {
        case .saved(let host):
            // Pairing when it needs it; otherwise its Edit page, offline or not (fixing an address is how to reach it).
            if statuses[host.uniqueID] == .online(paired: false) {
                pairing = PairTarget(address: host.address, name: host.displayName)
            } else {
                editing = host
            }
        case .add:
            isAdding = true
        }
    }

    private func showMenu(_ item: Item) {
        guard case .saved(let host) = item else { return }
        var actions: [MenuSpec.Action] = []
        if offersWake(host) { actions.append(.init(title: "Wake Host") { wake(host) }) }
        if sleepable.contains(host.uniqueID) { actions.append(.init(title: "Sleep Host…") { confirmSleep(host) }) }
        actions.append(.init(title: "Edit…") { editing = host })
        actions.append(.init(title: "Remove Host…", isDestructive: true) { confirmRemove(host) })
        let message = host.address + (host.remoteAddress.map { " · remote \($0)" } ?? "")
        menu = MenuSpec(title: host.displayName, message: message, actions: actions)
    }

    private func offersWake(_ host: SavedHost) -> Bool { directory.canWake(host) && !directory.waking.contains(host.uniqueID) }

    private func wake(_ host: SavedHost) {
        let name = host.displayName
        Task { if await !directory.wake(host) { menu = .wakeFailed(name) } }
    }

    /// The PC only sleeps when asked deliberately, once per confirmation; a failure needs a new confirmation.
    private func confirmSleep(_ host: SavedHost) {
        let name = host.displayName
        menu = MenuSpec(title: "Put \(name) to sleep?", message: "Quit any running game first. Wake it from this app on the same network, or with its power button.",
                        actions: [.init(title: "Sleep") {
            let client = HostClient(hostID: host.uniqueID, address: activeAddresses[host.uniqueID] ?? host.address,
                                    httpsPort: host.httpsPort, serverCert: host.serverCert)
            Task {
                do {
                    try await client.sleep()
                } catch {
                    menu = .error(error)
                }
            }
        }])
    }

    private func confirmRemove(_ host: SavedHost) {
        let isPaired = !host.serverCert.isEmpty
        menu = MenuSpec(title: "Remove \(host.displayName)?",
                        message: isPaired ? "This device is also unpaired on the host. Adding it again needs a new PIN." : nil,
                        actions: [.init(title: "Remove Host", isDestructive: true) { Task { await remove(host) } },
                                  // Its games' art (found or yours), names and history too: a fresh start if it's added again.
                                  .init(title: "Remove Host and Its Data", isDestructive: true) {
                                      Task { await remove(host, withData: true) }
                                  }])
    }

    /// Unpairs on the PC when it answers, then forgets it here.
    private func remove(_ host: SavedHost, withData: Bool = false) async {
        var unpairedOnPC = host.serverCert.isEmpty // nothing to undo on a PC that was never paired
        if !unpairedOnPC {
            let client = HostClient(hostID: host.uniqueID, address: activeAddresses[host.uniqueID] ?? host.address,
                                    httpsPort: host.httpsPort, serverCert: host.serverCert)
            unpairedOnPC = (try? await client.unpair()) != nil
        }
        let name = host.displayName
        if withData {
            catalog.forgetEverything(of: host.uniqueID, keepingGamesOf: hosts.map(\.uniqueID).filter { $0 != host.uniqueID })
        } else {
            catalog.forget(host.uniqueID)
        }
        context.delete(host)
        try? context.save()
        if !unpairedOnPC {
            menu = .error("It couldn't be reached to unpair, so it still lists this device. Remove it there, under Clients.",
                          title: "\(name) removed here only")
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
    /// The same words and dot as Home's status menu.
    let line: PCStatusLine
    /// Paired the last time it was, for while it's offline and can't say.
    let wasPaired: Bool
    let playing: String?
    /// Another device is streaming it.
    var isElsewhere = false

    /// Online answers say; offline, it's as it was.
    private var isPaired: Bool { status == .online(paired: false) ? false : wasPaired }

    private var isFine: Bool { line.health == .fine && !line.isWaiting }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(PCStatusButton.color(line))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading) {
                Text(name)
                if let playing {
                    Text("\(Image(systemName: "play.fill")) \(isElsewhere ? "Playing \(playing) on another device" : "Streaming \(playing)")")
                        .font(.caption).foregroundStyle(isElsewhere ? .orange : .green)
                }
                if !isFine { Text(line.text).font(.caption).foregroundStyle(.secondary) }
                Text(address).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // Paired: a link; not (or no longer) paired, so it needs pairing: a link to add, in orange.
            Image(systemName: isPaired ? "link" : "link.badge.plus")
                .foregroundStyle(isPaired ? Color.secondary : .orange)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary) // opens its Edit page, or pairing
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue([isFine ? "Online" : line.text,
                             isPaired ? "Paired" : "Needs pairing"].joined(separator: ", "))
    }
}

