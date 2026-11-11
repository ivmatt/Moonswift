import SwiftData
import SwiftUI

/// The Stage 1 screen: type an address, check it with /serverinfo, then save it.
struct AddHostView: View {
    enum LoadState {
        case idle, loading
        case loaded(ServerInfo)
        case failed(String)
    }

    @Environment(\.modelContext) private var context
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
                LabeledContent("Pairing", value: pairText(info.pairStatus))
            } footer: {
                Text("Over plain HTTP the host always reports “not paired”. Real status needs pairing first.")
            }
            Section {
                Button("Save PC") { save(info) }
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

    private func pairText(_ status: ServerInfo.PairStatus) -> String {
        switch status {
        case .paired: "Paired"
        case .unpaired: "Not paired"
        case .unknown: "Unknown"
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

    private func save(_ info: ServerInfo) {
        // Same uniqueID as an existing host updates it (unique attribute), so re-adding just fixes the address.
        context.insert(SavedHost(uniqueID: info.uniqueID ?? trimmedAddress, name: info.hostname, address: trimmedAddress))
        try? context.save() // autosave is on a timer; a quick force-quit would lose the host
        dismiss()
    }
}
