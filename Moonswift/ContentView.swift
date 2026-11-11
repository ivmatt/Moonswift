import SwiftData
import SwiftUI

/// Home screen: paired PCs with live status, plus PCs found on the network. Tapping an unpaired PC pairs it.
struct ContentView: View {
    struct PairTarget: Identifiable {
        let address: String
        let name: String
        var id: String { address }
    }

    @Environment(\.modelContext) private var context
    @Query(sort: \SavedHost.name) private var hosts: [SavedHost]
    @State private var discovery = HostDiscovery()
    @State private var statuses: [String: HostStatus] = [:] // by uniqueID; missing = not checked yet
    @State private var isAdding = false
    @State private var pairing: PairTarget?

    private var newlyFound: [HostDiscovery.Found] {
        discovery.found.filter { found in !hosts.contains { $0.uniqueID == found.id } }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("My PCs") {
                    if hosts.isEmpty {
                        Text("No paired PCs yet.").foregroundStyle(.secondary)
                    }
                    ForEach(hosts) { host in
                        let status = statuses[host.uniqueID]
                        if status == .online(paired: true) {
                            NavigationLink {
                                AppLibraryView(client: HostClient(hostID: host.uniqueID, address: host.address,
                                                                  httpsPort: host.httpsPort, serverCert: host.serverCert),
                                               name: host.name)
                            } label: {
                                HostRow(name: host.name, address: host.address, status: status)
                            }
                        } else {
                            Button {
                                if status == .online(paired: false) { pairing = PairTarget(address: host.address, name: host.name) }
                            } label: {
                                HostRow(name: host.name, address: host.address, status: status)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { context.delete(hosts[index]) }
                        try? context.save()
                    }
                }
                Section("Found on your network") {
                    if newlyFound.isEmpty {
                        Text("Searching…").foregroundStyle(.secondary)
                    }
                    ForEach(newlyFound) { found in
                        Button {
                            pairing = PairTarget(address: found.address, name: found.info.hostname)
                        } label: {
                            HostRow(name: found.info.hostname, address: found.address, status: .online(paired: false))
                        }
                    }
                }
            }
            .tint(.primary) // rows are buttons for controller focus, but shouldn't look like links
            .navigationTitle("Moonswift")
            .toolbar {
                Button("Add PC", systemImage: "plus") { isAdding = true }
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
            .task { discovery.start() }
            // Restarts at once when a host is added, removed or (re)paired.
            .task(id: hosts.map { "\($0.uniqueID)|\($0.serverCert.count)" }) { await pollStatus() }
        }
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
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: SavedHost.self, inMemory: true)
}
