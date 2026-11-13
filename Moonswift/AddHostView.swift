import SwiftData
import SwiftUI

/// Pair a new PC: pick one found on the network (searched only while this screen is open), or type its address.
/// Pairing is what saves a PC. Controller: up/down through found PCs, A to pair, B to close.
struct AddHostView: View {
    enum LoadState {
        case idle, loading
        case loaded(ServerInfo)
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(GamepadInput.self) private var gamepad
    @Query private var hosts: [SavedHost]
    @State private var discovery = HostDiscovery()
    @State private var address = ""
    @State private var state = LoadState.idle
    @State private var focus = 0
    @State private var pairingWith: String? // the found PC's unique ID

    private var trimmedAddress: String { address.trimmingCharacters(in: .whitespaces) }

    private var isLoading: Bool {
        if case .loading = state { true } else { false }
    }

    /// Found PCs that aren't paired yet.
    private var found: [HostDiscovery.Found] {
        discovery.found.filter { found in !hosts.contains { $0.uniqueID == found.id } }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("On your network") {
                    if found.isEmpty {
                        Label("Searching…", systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(.secondary)
                    }
                    ForEach(Array(found.enumerated()), id: \.element.id) { index, pc in
                        let isFocused = gamepad.isActive && index == min(focus, found.count - 1)
                        Button { pairingWith = pc.id } label: {
                            LabeledContent(pc.info.hostname, value: pc.address)
                        }
                        .listRowBackground(isFocused ? Color.accentColor.opacity(0.25) : Color(.secondarySystemGroupedBackground))
                    }
                }
                Section {
                    TextField("IP address, e.g. 10.0.4.20", text: $address)
                        .autocorrectionDisabled()
                        .onSubmit(connect)
                    Button("Connect", action: connect)
                        .disabled(isLoading || trimmedAddress.isEmpty)
                } header: {
                    Text("Or enter its address")
                } footer: {
                    Text("Pair at home over your local network; remote access works afterwards.")
                }
                result
            }
            .tint(.primary)
            .navigationTitle("Add Host")
            .navigationDestination(item: $pairingWith) { id in
                if let pc = discovery.found.first(where: { $0.id == id }) {
                    PairingView(address: pc.address, name: pc.info.hostname) { dismiss() }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { discovery.start() }
            .onDisappear { discovery.stop() }
            // shortcut: typing an address still needs touch or a keyboard; an on-screen controller keyboard can come later.
            .onGamepad { command in
                switch command {
                case .up, .down: focus = FocusMove.next(focus, count: found.count, columns: 1, command)
                case .select: if found.indices.contains(focus) { pairingWith = found[focus].id }
                case .back: dismiss()
                default: break
                }
            }
        }
    }

    @ViewBuilder private var result: some View {
        switch state {
        case .idle:
            EmptyView()
        case .loading:
            Section { ProgressView("Contacting host…") }
        case .loaded(let info):
            Section {
                LabeledContent("Hostname", value: info.hostname)
                LabeledContent("Status") {
                    Text("\(Image(systemName: "circle.fill")) Online").foregroundStyle(.green)
                }
            }
            Section {
                NavigationLink("Pair with \(info.hostname)") {
                    PairingView(address: trimmedAddress, name: info.hostname) { dismiss() }
                }
            }
        case .failed(let message):
            Section {
                LabeledContent("Status") {
                    Text("\(Image(systemName: "circle.fill")) Offline").foregroundStyle(.red)
                }
                Text(message).foregroundStyle(.secondary)
            }
        }
    }

    private func connect() {
        guard !isLoading else { return }
        state = .loading
        Task {
            do {
                state = .loaded(try await fetchServerInfo(address: address))
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}
