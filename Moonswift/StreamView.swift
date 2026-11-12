import MoonlightCore
import SwiftUI

/// What the library screen hands over after a successful Launch or Resume.
struct StreamTarget: Hashable, Identifiable {
    let title: String
    let launch: LaunchSession
    let width: Int
    let height: Int
    let fps: Int
    let bitrate: Int // kbps
    let videoFormats: Int32 // the library's VIDEO_FORMAT_* flags allowed
    let fitsSafeArea: Bool // place the picture clear of the camera cutout and home indicator
    var id: LaunchSession { launch }
}

/// The game, full screen with sound, played with controllers, touch, keyboard and mouse. A four-finger tap or
/// holding Menu + View on the controller opens a menu: switch touch mode, disconnect (the game keeps running) or
/// quit the game. The screen stays awake while streaming.
struct StreamView: View {
    let client: HostClient
    let target: StreamTarget
    /// Called after this stream has closed for Apply & Reconnect: the game list resumes with the new settings.
    var onReconnect: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(GamepadInput.self) private var gamepad
    @AppStorage("touchMode") private var touchMode = TouchMode.touchscreen
    @State private var session = StreamSession()
    @State private var controllers = ControllerStreamer()
    @State private var keyboardMouse = KeyboardMouseStreamer()
    @State private var isSendingInput = false
    @State private var renderer = VideoRenderer()
    @State private var menu: MenuSpec?
    @State private var rates = ""
    @State private var isLeaving = false
    @State private var isShowingSettings = false
    // Not @AppStorage: the once-a-second loop runs on the copy of this view from when the stream started, whose
    // @AppStorage values don't follow later changes (Stream Settings). Reading UserDefaults is always current.
    private var adaptive: Bool { UserDefaults.standard.bool(forKey: SettingsKey.adaptiveBitrate) }
    private var savedBitrate: Int { UserDefaults.standard.integer(forKey: SettingsKey.bitrate) }
    @State private var adaptiveController: BitrateController?
    @State private var adaptiveNote: String?
    @State private var adaptiveUnsupported = false
    @AppStorage(SettingsKey.performanceOverlay) private var showsPerformance = false
    @State private var performance: PerformanceOverlay.Readout?

    /// The game gets no input while a menu or Settings is over it.
    private var isPlaying: Bool { menu == nil && !isShowingSettings }

    private var stats: StreamStats { session.stats }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ZStack {
                VideoLayerView(renderer: renderer)
                TouchInputLayer(mode: touchMode, streamSize: CGSize(width: target.width, height: target.height),
                                isPaused: !isPlaying || !isSendingInput, onMenu: showMenu)
            }
            // Safe Area mode keeps the picture (and the touches mapped onto it) clear of the cutout and home indicator.
            .ignoresSafeArea(edges: target.fitsSafeArea ? [] : .all)
            if showsPerformance, let performance {
                PerformanceOverlay(readout: performance, adaptiveNote: adaptiveNote)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if stats.state == .connecting || isLeaving {
                ProgressView(isLeaving ? "Disconnecting…" : "Connecting to \(target.title)…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden) // the home indicator fades out until touched
        .onGamepad { command in
            if command == .streamMenu { showMenu() } // other buttons will go to the game once input is sent
        }
        .actionMenu($menu)
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(live: LiveStream(target: target, setBitrate: setLiveBitrate, reconnect: { leave(then: onReconnect) }))
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            stopInput()
        }
        .task { await run() }
        .onChange(of: stats.state) { _, state in
            switch state {
            case .connected: startInput()
            case .failed, .ended: stopInput(); showMenu()
            case .connecting: break
            }
        }
        .onChange(of: isPlaying) { _, isPlaying in
            // While the menu is up, input drives the menu; held buttons and keys are released on the host.
            controllers.isPaused = !isPlaying
            keyboardMouse.isPaused = !isPlaying
        }
    }

    /// Input can only be sent once the connection is up (controller arrival events need the control stream).
    private func startInput() {
        guard !isSendingInput else { return }
        isSendingInput = true
        activeControllers = controllers
        controllers.start()
        keyboardMouse.start(gamepad: gamepad)
    }

    private func stopInput() {
        guard isSendingInput else { return }
        isSendingInput = false
        controllers.stop()
        keyboardMouse.stop()
        activeControllers = nil
    }

    private func showMenu() {
        switch stats.state {
        case .failed(let message), .ended(let message):
            menu = MenuSpec(title: "Stream ended", message: message, actions: [.init(title: "Close") { leave() }], cancelTitle: nil)
        case .connecting, .connected:
            menu = MenuSpec(title: target.title,
                            message: ([stats.video, rates].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                + (adaptiveNote.map { "\n" + $0 } ?? ""),
                            actions: [
                                .init(title: touchMode == .touchscreen ? "Switch to Trackpad" : "Switch to Touchscreen") {
                                    touchMode = touchMode == .touchscreen ? .trackpad : .touchscreen
                                },
                                .init(title: "Stream Settings") { isShowingSettings = true },
                                .init(title: showsPerformance ? "Hide Performance Overlay" : "Show Performance Overlay") {
                                    showsPerformance.toggle()
                                },
                                .init(title: "Disconnect") { leave() },
                                .init(title: "Quit Game", isDestructive: true) { leave(quitting: true) },
                            ],
                            cancelTitle: "Resume Stream")
        }
    }

    /// Stops the connection before closing, so the next stream can't start while this one shuts down.
    private func leave(quitting: Bool = false, then next: @escaping () -> Void = {}) {
        guard !isLeaving else { return }
        isLeaving = true
        stopInput() // lift held buttons and keys before the connection closes
        Task {
            await session.stop()
            if quitting { try? await client.quit() }
            dismiss()
            next()
        }
    }

    /// Vibepollo changes the encoder's bitrate for this session without reconnecting; other hosts don't support it.
    private func setLiveBitrate(_ kbps: Int) async -> String {
        if adaptive, !adaptiveUnsupported { return "Adaptive bitrate will use this as its ceiling." } // the loop applies it
        do {
            let applied = try await client.setBitrate(kbps)
            return applied < kbps ? "Now \(applied / 1000) Mbps, the most the PC allows during a stream."
                                  : "Now \(applied / 1000) Mbps."
        } catch {
            return "This PC can't change bitrate during a stream; it applies next time."
        }
    }

    private func run() async {
        session.start(host: client, target: target, renderer: renderer)
        let started = ContinuousClock.now
        var previous = (counters: StreamCounters(), time: started)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            session.refresh()
            let now = ContinuousClock.now
            let isLive = stats.state == .connected && !isLeaving // the library's stats exist only while connected
            var rtp = RTP_VIDEO_STATS()
            var rtt: UInt32 = 0, rttVariance: UInt32 = 0
            var hasRTT = false
            if isLive {
                LiGetRTPVideoStats(&rtp)
                hasRTT = LiGetEstimatedRttInfo(&rtt, &rttVariance)
            }
            let counters = StreamCounters(
                frames: stats.videoFrames, bytes: stats.videoBytes, lostFrames: stats.lostFrames,
                packets: Int(rtp.packetCountVideo), fecRecovered: Int(rtp.packetCountFecRecovered), fecFailed: Int(rtp.packetCountFecFailed),
                timedFrames: stats.timedFrames, receiveMicroseconds: stats.receiveMicroseconds, queueMicroseconds: stats.queueMicroseconds,
                hostLatencyTenthsMs: stats.hostLatencyTenthsMs, hostLatencyFrames: stats.hostLatencyFrames)
            let window = PerformanceWindow(from: previous.counters, to: counters, seconds: (now - previous.time) / .seconds(1))
            previous = (counters, now)

            rates = "\(window.fps.formatted(.number.precision(.fractionLength(0)))) fps, "
                + "\(window.mbps.formatted(.number.precision(.fractionLength(1)))) Mbps"
            performance = PerformanceOverlay.Readout(window: window, targetFPS: target.fps, video: stats.video,
                                                     rtt: hasRTT ? (Int(rtt), Int(rttVariance)) : nil,
                                                     isRemote: !isHomeNetworkHost(hostAddress(client.address)))
            if isLive {
                adaptStep(window.sample(rttMs: hasRTT ? Int(rtt) : nil, isPoor: stats.isPoor), now: (now - started) / .seconds(1))
            }
        }
    }

    /// One second of adaptive bitrate: let the controller decide, send any change.
    private func adaptStep(_ sample: NetworkSample, now: TimeInterval) {
        guard !adaptiveUnsupported else { return }
        let setting = StreamSettings.effectiveBitrate(saved: savedBitrate, width: target.width, height: target.height, fps: target.fps)
        let ceiling = min(setting, StreamSettings.liveBitrateLimit)
        let capNote = setting > ceiling ? " (PC's limit while streaming)" : ""
        guard adaptive else {
            if adaptiveController != nil { // switched off mid-stream: back to your setting
                adaptiveController = nil
                adaptiveNote = nil
                sendBitrate(ceiling)
            }
            return
        }
        guard adaptiveController != nil else {
            // Unlimited's 1000 Mbps is above the live limit, so it starts by dropping to 500.
            let controller = BitrateController(ceiling: ceiling, start: target.bitrate)
            adaptiveController = controller
            if controller.target != target.bitrate { sendBitrate(controller.target) }
            adaptiveNote = "Adaptive: \(controller.target / 1000) of \(ceiling / 1000) Mbps\(capNote) · starting"
            return
        }
        if let changed = adaptiveController?.setCeiling(ceiling) { sendBitrate(changed) } // the setting changed in Stream Settings
        if let changed = adaptiveController?.update(sample, now: now) { sendBitrate(changed) }
        if let controller = adaptiveController {
            adaptiveNote = "Adaptive: \(controller.target / 1000) of \(controller.ceiling / 1000) Mbps\(capNote) · \(controller.reason)"
        }
    }

    private func sendBitrate(_ kbps: Int) {
        Task {
            do {
                _ = try await client.setBitrate(kbps)
            } catch {
                adaptiveUnsupported = true
                adaptiveNote = "Adaptive bitrate is off: this PC can't change bitrate during a stream."
            }
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
