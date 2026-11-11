import SwiftData
import SwiftUI

/// Home screen: saved PCs with live status, plus PCs found on the network.
struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedHost.name) private var hosts: [SavedHost]
    @State private var discovery = HostDiscovery()
    @State private var online: [String: Bool] = [:] // by uniqueID; missing = not checked yet
    @State private var isAdding = false

    private var newlyFound: [HostDiscovery.Found] {
        discovery.found.filter { found in !hosts.contains { $0.uniqueID == found.id } }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("My PCs") {
                    if hosts.isEmpty {
                        Text("No saved PCs yet.").foregroundStyle(.secondary)
                    }
                    ForEach(hosts) { host in
                        HostRow(name: host.name, address: host.address, online: online[host.uniqueID])
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
                        HStack {
                            HostRow(name: found.info.hostname, address: found.address, online: true)
                            Button("Add") {
                                context.insert(SavedHost(uniqueID: found.id, name: found.info.hostname, address: found.address))
                                try? context.save() // autosave is on a timer; a quick force-quit would lose the host
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .navigationTitle("Moonswift")
            .toolbar {
                Button("Add PC", systemImage: "plus") { isAdding = true }
            }
            .sheet(isPresented: $isAdding) { AddHostView() }
            .task { discovery.start() }
            .task(id: hosts.map(\.uniqueID)) { await pollStatus() } // restarts at once when hosts change
        }
    }

    /// Like moonlight-ios's DiscoveryWorker: ask every saved host for /serverinfo on a loop.
    private func pollStatus() async {
        while !Task.isCancelled {
            let targets = hosts.map { (id: $0.uniqueID, address: $0.address) }
            await withTaskGroup(of: (String, ServerInfo?).self) { group in
                for target in targets {
                    group.addTask { (target.id, try? await fetchServerInfo(address: target.address, timeout: 2)) }
                }
                for await (id, info) in group {
                    online[id] = info != nil
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
    let online: Bool?

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(name)
                Text(address).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch online {
            case nil: Text("Checking…").foregroundStyle(.secondary)
            case true?: Text("\(Image(systemName: "circle.fill")) Online").foregroundStyle(.green)
            case false?: Text("\(Image(systemName: "circle.fill")) Offline").foregroundStyle(.red)
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: SavedHost.self, inMemory: true)
}
