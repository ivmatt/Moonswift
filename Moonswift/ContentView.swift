import SwiftUI

struct ContentView: View {
    enum LoadState {
        case idle, loading
        case loaded(ServerInfo)
        case failed(String)
    }

    @State private var address = ""
    @State private var state = LoadState.idle

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
                        .disabled(isLoading || address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                result
            }
            .navigationTitle("Moonswift")
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
}

#Preview {
    ContentView()
}
