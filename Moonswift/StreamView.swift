import SwiftUI

/// What the library screen hands over after a successful Launch or Resume.
struct StreamTarget: Hashable, Identifiable {
    let title: String
    let launch: LaunchSession
    let width: Int
    let height: Int
    let fps: Int
    let bitrate: Int // kbps
    var id: LaunchSession { launch }
}

/// The game, full screen with sound. Tapping the screen or holding Menu + View on the controller opens a menu
/// to disconnect (the game keeps running) or quit the game. The screen stays awake while streaming.
struct StreamView: View {
    let client: HostClient
    let target: StreamTarget

    @Environment(\.dismiss) private var dismiss
    @State private var session = StreamSession()
    @State private var renderer = VideoRenderer()
    @State private var menu: MenuSpec?
    @State private var rates = ""
    @State private var isLeaving = false

    private var stats: StreamStats { session.stats }

    var body: some View {
        ZStack {
            Color.black
            VideoLayerView(renderer: renderer)
            if stats.state == .connecting || isLeaving {
                ProgressView(isLeaving ? "Disconnecting…" : "Connecting to \(target.title)…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .ignoresSafeArea()
        .contentShape(.rect)
        .onTapGesture { if menu == nil { showMenu() } }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden) // the home indicator fades out until touched
        .onGamepad { command in
            if command == .streamMenu { showMenu() } // other buttons will go to the game once input is sent
        }
        .actionMenu($menu)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task { await run() }
        .onChange(of: stats.state) { _, state in
            if case .failed = state { showMenu() }
            if case .ended = state { showMenu() }
        }
    }

    private func showMenu() {
        switch stats.state {
        case .failed(let message), .ended(let message):
            menu = MenuSpec(title: "Stream ended", message: message, actions: [.init(title: "Close") { leave() }], cancelTitle: nil)
        case .connecting, .connected:
            menu = MenuSpec(title: target.title, message: [stats.video, rates].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                            actions: [
                                .init(title: "Disconnect") { leave() },
                                .init(title: "Quit Game", isDestructive: true) { leave(quitting: true) },
                            ],
                            cancelTitle: "Resume Stream")
        }
    }

    /// Stops the connection before closing, so the next stream can't start while this one shuts down.
    private func leave(quitting: Bool = false) {
        guard !isLeaving else { return }
        isLeaving = true
        Task {
            await session.stop()
            if quitting { try? await client.quit() }
            dismiss()
        }
    }

    private func run() async {
        session.start(host: client, target: target, renderer: renderer)
        var previous = (frames: 0, bytes: 0, time: ContinuousClock.now)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            session.refresh()
            let now = ContinuousClock.now
            let seconds = (now - previous.time) / .seconds(1)
            let fps = Double(stats.videoFrames - previous.frames) / seconds
            let mbps = Double(stats.videoBytes - previous.bytes) * 8 / seconds / 1_000_000
            rates = "\(fps.formatted(.number.precision(.fractionLength(0)))) fps, \(mbps.formatted(.number.precision(.fractionLength(1)))) Mbps"
            previous = (stats.videoFrames, stats.videoBytes, now)
        }
    }
}

/// Hosts the renderer's AVSampleBufferDisplayLayer and keeps it sized to the screen.
private struct VideoLayerView: UIViewRepresentable {
    let renderer: VideoRenderer

    func makeUIView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.backgroundColor = .black
        view.layer.addSublayer(renderer.layer)
        view.hostedLayer = renderer.layer
        return view
    }

    func updateUIView(_ view: LayerHostView, context: Context) {}
}

private final class LayerHostView: UIView {
    var hostedLayer: CALayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true) // no animated resize on rotation
        hostedLayer?.frame = bounds
        CATransaction.commit()
    }
}
