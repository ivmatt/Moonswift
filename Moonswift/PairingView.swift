import SwiftData
import SwiftUI

/// Shows a PIN and runs the pairing handshake while the user types it into the host's web page, then saves the host
/// and reports its ID and name.
struct PairingView: View {
    let address: String
    let name: String
    /// B, inside a flow that steps back (Add Host); none: B closes it.
    var onBack: (() -> Void)? = nil
    let onPaired: (_ hostID: String, _ name: String) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var pin = Pairing.generatePIN()
    @State private var error: String?
    @State private var attempt = 0
    @State private var window = CGSize.zero

    /// The host's web page: Sunshine-based hosts serve it one port above their main (HTTP) port, 47990 by default,
    /// so a host moved to another port is followed too.
    private var webPort: Int { (URLComponents(string: "http://\(address)")?.port ?? 47989) + 1 }
    /// The same page from this device, over the network (the host lets its local network in by default).
    private var webUI: URL? {
        URLComponents(string: "http://\(address)")?.host.flatMap { URL(string: "https://\($0):\(webPort)") }
    }

    var body: some View {
        ScrollView { // a short screen can't fit it all
        VStack(spacing: window.isShort ? 14 : 24) {
            Text(pin)
                .font(.system(size: window.isShort ? 56 : 80, weight: .bold, design: .monospaced))
                .accessibilityLabel("PIN \(pin.map(String.init).joined(separator: " "))")
            if let error {
                Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    step(1, "Open the host's web page: on \(name) itself, go to localhost:\(webPort) in a browser.")
                    if let webUI {
                        Link(destination: webUI) { Label("Or open it on this device", systemImage: "safari") }
                            .font(.subheadline.weight(.semibold))
                            .tint(.blue)
                            .padding(.leading, 32)
                    }
                    step(2, "Sign in, then look for Clients or PIN.")
                    step(3, "Type this PIN and a name for this device. Moonswift will take care of the rest.")
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Some hosts limit what each device can do. Allow this one to:")
                                .fixedSize(horizontal: false, vertical: true) // wraps, never "…"
                            VStack(alignment: .leading, spacing: 3) {
                                Text("•  Launch apps")
                                Text("•  Send controller input")
                                Text("•  Send keyboard and mouse input")
                            }
                            .padding(.leading, 4)
                            Text("Otherwise, games may not launch or respond.")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(12)
                    .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
                    .padding(.top, 4)
                }
                .frame(maxWidth: 480, alignment: .leading)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onGeometryChange(for: CGSize.self) { $0.fullSize } action: { window = $0 }
        .navigationTitle("Pair with \(name)")
        .task(id: attempt) { await pair() } // cancelled (and the request with it) when the view closes
        .onGamepad { command in
            switch command {
            case .back: if let onBack { onBack() } else { dismiss() }
            case .select: if error != nil { retry() }
            default: break
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.subheadline.weight(.bold)).frame(width: 22, height: 22).background(.quaternary, in: .circle)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) // wraps, never "…"
        }
    }

    private func retry() {
        error = nil
        pin = Pairing.generatePIN()
        attempt += 1
    }

    private func pair() async {
        #if DEBUG
        if DemoMode.isFirstRun { // time to look at this page, then paired as if the PIN had been typed
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            context.insert(SavedHost(uniqueID: DemoMode.pcID, name: name, address: address, serverCert: Data([1])))
            return onPaired(DemoMode.pcID, name)
        }
        #endif
        do {
            let paired = try await Pairing.pair(address: address, pin: pin)
            // Same uniqueID as an existing host updates it (unique attribute), so re-pairing refreshes it.
            let id = paired.info.uniqueID ?? address
            context.insert(SavedHost(uniqueID: id, name: paired.info.hostname, address: address,
                                     httpsPort: paired.info.httpsPort, serverCert: paired.serverCert))
            try? context.save() // autosave is on a timer; a quick force-quit would lose the pairing
            onPaired(id, paired.info.hostname)
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}
