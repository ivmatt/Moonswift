import SwiftUI

/// A one-time guide over the stream, one card per way of playing, each shown the first time that way is in use.
struct StreamTutorial: View {
    enum Card: String {
        case gestures, controller, onScreenController

        /// The cards for how the stream is played now, in order. The on-screen controller turns gestures off, so with
        /// Touch set to Controller there's no gestures card: its own card, or the controller's once one takes over.
        static func due(touchMode: TouchMode, controllerConnected: Bool) -> [Card] {
            if touchMode == .controller { return [controllerConnected ? .controller : .onScreenController] }
            return controllerConnected ? [.gestures, .controller] : [.gestures]
        }
    }

    let card: Card
    /// No card after this one: the button says Got It, not Next.
    let isLast: Bool
    let dismiss: () -> Void
    private var buttonTitle: String { isLast ? "Got It" : "Next" }
    @State private var shortcuts = KeyShortcutStore()

    /// What's set now: the defaults on a first run, or the user's own.
    private var gestures: [TouchGesture] { TouchGesture.active.filter { $0.action != .nothing } }

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            // Centred when it fits; scrolls from the top on a screen too short for it.
            ViewThatFits(in: .vertical) {
                panel
                ScrollView { panel }
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .buttonGuide([([.a], buttonTitle)], reportsLayout: false)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
            Button(buttonTitle, action: dismiss)
                .primaryButton()
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: 520, alignment: .leading)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 24))
        .padding()
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch card {
        case .gestures:
            title("Gestures", symbol: "hand.raised")
            Text("Use three fingers anywhere on the stream:")
            ForEach(gestures, id: \.self) { gesture in
                Text("**\(gesture.title)** (\(gesture.fingers) fingers): \(gesture.action.title(shortcuts.all))")
            }
            note("Gestures work in Touchscreen and Trackpad modes, not with the on-screen controller. "
                 + "Change them in Settings → Interface → Experience → Gestures.")
        case .controller:
            title("Controller", symbol: "gamecontroller")
            Text("Press **Menu + View** together to open the control panel.")
            // One literal, not joined with +: only a literal is read as Markdown.
            Text("""
                **Actions**: key shortcuts, the clipboard, Disconnect and Quit. A bumper away, **Quick Settings**: \
                bitrate, the performance overlay, touch mode and more.
                """)
            note("Everything else on the controller goes to the game.")
        case .onScreenController:
            title("On-Screen Controller", symbol: "rectangle.topthird.inset.filled")
            callout("Gestures are off while the on-screen controller is in use: every touch goes to the game.")
            Text("""
                Use the **actions row** along the top of the screen instead. Its first button opens the control \
                panel; the rest are your layout's, like Quick Settings and the keyboard.
                """)
            callout("The row doesn't stay: it fades away with the controls when you stop touching the screen, or "
                    + "hides until you touch the top, depending on your layout. Touch the screen to bring it back.")
            note("Switch to Touchscreen or Trackpad in Quick Settings to use gestures.")
        }
    }

    private func title(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.title2.bold())
    }

    /// A point that's easy to miss, set apart.
    private func callout(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.tint.opacity(0.25), in: .rect(cornerRadius: 12))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
    }
}
