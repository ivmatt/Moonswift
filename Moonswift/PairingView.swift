import SwiftData
import SwiftUI

/// Shows a PIN and runs the pairing handshake while the user types it into the host's web page, then saves the host
/// and reports its ID and name.
struct PairingView: View {
    let address: String
    let name: String
    /// B, inside a flow that steps back (Add Host); none: B closes it.
    var onBack: (() -> Void)? = nil
    /// Asks for the host's permissions once paired; Add Host does that on its own success page instead.
    var confirmsPermissions = true
    let onPaired: (_ hostID: String, _ name: String) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var pin = Pairing.generatePIN()
    @State private var error: String?
    @State private var attempt = 0
    @State private var window = CGSize.zero
    @State private var pairedHost: (id: String, name: String)?
    @State private var hasAllowedPermissions = false

    /// The host's web page: Sunshine-based hosts serve it one port above their main (HTTP) port, 47990 by default,
    /// so a host moved to another port is followed too.
    private var webPort: Int { (URLComponents(string: "http://\(address)")?.port ?? 47989) + 1 }
    /// The same page from this device, over the network (the host lets its local network in by default).
    private var webUI: URL? {
        URLComponents(string: "http://\(address)")?.host.flatMap { URL(string: "https://\($0):\(webPort)") }
    }

    var body: some View {
        ScrollView { // a short screen can't fit it all
        if let pairedHost {
            VStack(spacing: 16) {
                Text("\(pairedHost.name) is paired").font(.title2.bold())
                PermissionsConfirmation(isConfirmed: $hasAllowedPermissions)
                Button { onPaired(pairedHost.id, pairedHost.name) } label: { Text("Done").frame(width: 200) }
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                    .controlSize(.large)
                    .disabled(!hasAllowedPermissions)
            }
            .padding()
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        } else {
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
                }
                .frame(maxWidth: 480, alignment: .leading)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        }
        }
        .scrollBounceBehavior(.basedOnSize)
        .onGeometryChange(for: CGSize.self) { $0.fullSize } action: { window = $0 }
        .navigationTitle("Pair with \(name)")
        .task(id: attempt) { await pair() } // cancelled (and the request with it) when the view closes
        .onGamepad { command in
            switch command {
            case .back: if let onBack { onBack() } else { dismiss() }
            case .select:
                if let pairedHost {
                    if hasAllowedPermissions { onPaired(pairedHost.id, pairedHost.name) } else { hasAllowedPermissions = true }
                } else if error != nil {
                    retry()
                }
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
            return finish(DemoMode.pcID, name)
        }
        #endif
        do {
            let paired = try await Pairing.pair(address: address, pin: pin)
            // Same uniqueID as an existing host updates it (unique attribute), so re-pairing refreshes it.
            let id = paired.info.uniqueID ?? address
            context.insert(SavedHost(uniqueID: id, name: paired.info.hostname, address: address,
                                     httpsPort: paired.info.httpsPort, serverCert: paired.serverCert))
            try? context.save() // autosave is on a timer; a quick force-quit would lose the pairing
            finish(id, paired.info.hostname)
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func finish(_ id: String, _ name: String) {
        if confirmsPermissions { pairedHost = (id, name) } else { onPaired(id, name) }
    }
}

/// After pairing: what the host may need to allow, and a tick that it's done, before moving on.
struct PermissionsConfirmation: View {
    @Binding var isConfirmed: Bool
    var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Some hosts limit what each device can do. In the host's web page, under Clients, allow this one to:")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                Text("•  Launch apps")
                Text("•  Send controller input")
                Text("•  Send keyboard and mouse input")
            }
            .padding(.leading, 4)
            Text("Without these, games may not launch or respond.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { isConfirmed.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: isConfirmed ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isConfirmed ? Color.blue : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("I've allowed these").font(.body).foregroundStyle(.primary)
                        Text("Or my host doesn't have these settings.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isFocused ? Color.accentColor.opacity(0.25) : Color(.tertiarySystemFill), in: .rect(cornerRadius: 14))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isConfirmed ? .isSelected : [])
        }
        .font(.subheadline)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }
}
