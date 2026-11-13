import SwiftData
import SwiftUI

/// Shows a PIN and runs the pairing handshake while the user types it into Vibepollo, then saves the host.
struct PairingView: View {
    let address: String
    let name: String
    let onPaired: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var pin = Pairing.generatePIN()
    @State private var error: String?
    @State private var attempt = 0

    // shortcut: assumes the default web UI port (HTTP port + 1); a host with remapped ports would show the wrong link.
    private var webUI: String {
        "https://\(URLComponents(string: "http://\(address)")?.host ?? address):47990/pin"
    }

    var body: some View {
        VStack(spacing: 24) {
            Text(pin)
                .font(.system(size: 80, weight: .bold, design: .monospaced))
                .accessibilityLabel("PIN \(pin.map(String.init).joined(separator: " "))")
            if let error {
                Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)
            } else {
                ProgressView()
                Text("On your host, open \(webUI) and enter this PIN.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .navigationTitle("Pair with \(name)")
        .task(id: attempt) { await pair() } // cancelled (and the request with it) when the view closes
        .onGamepad { command in
            switch command {
            case .back: dismiss() // closes the sheet, or pops back to Add PC
            case .select: if error != nil { retry() }
            default: break
            }
        }
    }

    private func retry() {
        error = nil
        pin = Pairing.generatePIN()
        attempt += 1
    }

    private func pair() async {
        do {
            let paired = try await Pairing.pair(address: address, pin: pin)
            // Same uniqueID as an existing host updates it (unique attribute), so re-pairing refreshes it.
            context.insert(SavedHost(uniqueID: paired.info.uniqueID ?? address, name: paired.info.hostname, address: address,
                                     httpsPort: paired.info.httpsPort, serverCert: paired.serverCert))
            try? context.save() // autosave is on a timer; a quick force-quit would lose the pairing
            onPaired()
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}
