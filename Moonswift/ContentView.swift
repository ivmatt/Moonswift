import SwiftData
import SwiftUI

/// Home screen: paired PCs with live status, PCs found on the network, and "Pair a New PC". Touch or controller:
/// up/down to move, A to open (or pair), Y/X for a PC's menu.
struct ContentView: View {
    struct PairTarget: Identifiable {
        let address: String
        let name: String
        var id: String { address }
    }

    /// One focusable row, in screen order.
    private enum Item {
        case saved(SavedHost)
        case found(HostDiscovery.Found)
        case add

        var id: String {
            switch self {
            case .saved(let host): "saved-\(host.uniqueID)"
            case .found(let found): "found-\(found.id)"
            case .add: "add"
            }
        }
    }

    @Environment(\.modelContext) private var context
    @Environment(GamepadInput.self) private var gamepad
    @Query(sort: \SavedHost.name) private var hosts: [SavedHost]
    @State private var discovery = HostDiscovery()
    @State private var statuses: [String: HostStatus] = [:] // by uniqueID; missing = not checked yet
    @State private var isAdding = false
    @State private var pairing: PairTarget?
    @State private var path: [String] = [] // uniqueIDs of opened PCs
    @State private var focus = 0
    @State private var menu: MenuSpec?

    private var newlyFound: [HostDiscovery.Found] {
        discovery.found.filter { found in !hosts.contains { $0.uniqueID == found.id } }
    }

    /// Must match the on-screen order, or up/down feel inverted.
    private var items: [Item] { hosts.map(Item.saved) + [.add] + newlyFound.map(Item.found) }
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
                            row(.saved(host)) {
                                HostRow(name: host.name, address: host.address, status: statuses[host.uniqueID])
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { context.delete(hosts[index]) }
                            try? context.save()
                        }
                        row(.add) {
                            Label("Pair a New PC", systemImage: "plus.circle")
                        }
                    }
                    Section("Found on your network") {
                        if newlyFound.isEmpty {
                            Text("Searching…").foregroundStyle(.secondary)
                        }
                        ForEach(newlyFound) { found in
                            row(.found(found)) {
                                HostRow(name: found.info.hostname, address: found.address, status: .online(paired: false))
                            }
                        }
                    }
                }
                .onChange(of: focusIndex) { withAnimation { scroller.scrollTo(items[focusIndex].id) } }
            }
            .tint(.primary) // rows are buttons, but shouldn't look like links
            .navigationTitle("Moonswift")
            .navigationDestination(for: String.self) { id in
                if let host = hosts.first(where: { $0.uniqueID == id }) {
                    AppLibraryView(client: HostClient(hostID: host.uniqueID, address: host.address,
                                                      httpsPort: host.httpsPort, serverCert: host.serverCert),
                                   name: host.name)
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
                case .menu: showMenu(items[focusIndex])
                case .left, .right, .back, .streamMenu: break
                }
            }
            .actionMenu($menu)
            .task { discovery.start() }
            // Restarts at once when a host is added, removed or (re)paired.
            .task(id: hosts.map { "\($0.uniqueID)|\($0.serverCert.count)" }) { await pollStatus() }
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
            case .online(paired: false)?: pairing = PairTarget(address: host.address, name: host.name)
            case .offline?, nil: break // shortcut: nothing to do for an offline PC until Wake-on-LAN exists.
            }
        case .found(let found):
            pairing = PairTarget(address: found.address, name: found.info.hostname)
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
        actions.append(.init(title: "Remove PC", isDestructive: true) {
            context.delete(host)
            try? context.save()
        })
        menu = MenuSpec(title: host.name, message: host.address, actions: actions)
    }

    /// Like moonlight-ios's DiscoveryWorker: ask every saved host for /serverinfo on a loop.
    private func pollStatus() async {
        while !Task.isCancelled {
            let targets = hosts.map { (id: $0.uniqueID, address: $0.address, httpsPort: $0.httpsPort, serverCert: $0.serverCert) }
            await withTaskGroup(of: (String, HostStatus, ServerInfo?).self) { group in
                for target in targets {
                    group.addTask {
                        let result = await checkHost(address: target.address, httpsPort: target.httpsPort, serverCert: target.serverCert)
                        return (target.id, result.status, result.info)
                    }
                }
                for await (id, status, info) in group {
                    statuses[id] = status
                    if let info, let host = hosts.first(where: { $0.uniqueID == id }), host.name != info.hostname {
                        host.name = info.hostname // PC was renamed
                    }
                }
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }
}

private struct HostRow: View {
    let name: String
    let address: String
    let status: HostStatus?

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(name)
                Text(address).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch status {
            case nil:
                Text("Checking…").foregroundStyle(.secondary)
            case .offline?:
                Text("\(Image(systemName: "circle.fill")) Offline").foregroundStyle(.red)
            case .online(let paired)?:
                Text(paired ? "\(Image(systemName: "lock.fill")) Paired" : "\(Image(systemName: "lock.open")) Not paired")
                    .foregroundStyle(paired ? Color.primary : .orange)
                Text("\(Image(systemName: "circle.fill")) Online").foregroundStyle(.green)
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
