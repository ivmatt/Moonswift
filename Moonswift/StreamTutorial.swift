import SwiftUI

/// Shown over the first stream, once: where the options are, the three-finger gestures and the on-screen controller's
/// actions row, and which of the two works in the touch mode in use now.
struct StreamTutorial: View {
    /// The touch mode in use (Automatic already resolved): Controller means the actions row, not gestures.
    let touchMode: TouchMode
    let dismiss: () -> Void
    @State private var shortcuts = KeyShortcutStore()

    private var usesActionsRow: Bool { touchMode == .controller }
    /// What's set now: the defaults on a first run, or the user's own.
    private var gestures: [TouchGesture] { TouchGesture.active.filter { $0.action != .nothing } }

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Getting Around").font(.title2.bold())
                    section("Options", symbol: "switch.2", isNow: false) {
                        Text("Press Menu + View on a controller to open the control panel: Actions (shortcuts, clipboard, "
                             + "Disconnect, Quit), and a bumper away, Quick Settings.")
                    }
                    section("Gestures", symbol: "hand.raised", isNow: !usesActionsRow) {
                        ForEach(gestures, id: \.self) { gesture in
                            Text("\(gesture.fingers) fingers, \(gesture.title): \(gesture.action.title(shortcuts.all))")
                        }
                        Text("Change them in Settings → Interface → Experience → Gestures.").foregroundStyle(.secondary)
                    }
                    section("Actions Row", symbol: "rectangle.topthird.inset.filled", isNow: usesActionsRow) {
                        Text("With the on-screen controller, a row of buttons runs along the top. The first opens the "
                             + "control panel; the others are Quick Settings, the keyboard and Edit Layout.")
                    }
                    Text("Gestures work in Touchscreen and Trackpad modes. The on-screen controller (Controller, or "
                         + "Automatic with no controller connected) turns them off so your fingers only play the game: "
                         + "use the actions row instead.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Got It", action: dismiss)
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                }
                .padding(24)
                .frame(maxWidth: 520)
                .background(.ultraThinMaterial, in: .rect(cornerRadius: 24))
                .padding()
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .buttonGuide([([.a], "Got It")], reportsLayout: false)
    }

    private func section<Content: View>(_ title: String, symbol: String, isNow: Bool,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: symbol).font(.headline)
                if isNow {
                    Text("In Use Now").font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.tint, in: .capsule)
                }
            }
            content().font(.subheadline)
        }
    }
}
