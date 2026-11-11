import SwiftUI

/// Type an address, check it with /serverinfo, then pair with it (pairing is what saves a PC).
struct AddHostView: View {
    enum LoadState {
        case idle, loading
        case loaded(ServerInfo)
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var state = LoadState.idle

    private var trimmedAddress: String { address.trimmingCharacters(in: .whitespaces) }

    private var isLoading: Bool {
        if case .loading = state { true } else { false }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Host PC") {
                    TextField("IP address, e.g. 10.0.4.20", text: $address)
                        .autocorrectionDisabled()
                        .onSubmit(connect)
                    Button("Connect", action: connect)
                        .disabled(isLoading || trimmedAddress.isEmpty)
                }
                result
            }
            .navigationTitle("Add PC")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
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
