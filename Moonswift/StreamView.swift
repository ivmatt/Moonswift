import MoonlightCore
import Network
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

/// The game, full screen with sound, played with controllers, touch, keyboard and mouse. A three-finger tap shows the
/// on-screen keyboard. A four-finger tap or
/// holding Menu + View on the controller opens a menu: switch touch mode, disconnect (the game keeps running) or
/// quit the game. The screen stays awake while streaming. Leaving the app, switching networks and Apply & Reconnect
/// reconnect in place: the last frame stays up, blurred, with the status in the middle.
struct StreamView: View {
    /// Both change on a reconnect: the PC may answer at another address, and the new session has its own keys.
    @State private var client: HostClient
    @State private var target: StreamTarget
    /// Finds the PC again, resumes the game with the current settings, and returns the new connection.
    let resume: () async throws -> (HostClient, StreamTarget)

    init(client: HostClient, target: StreamTarget, resume: @escaping () async throws -> (HostClient, StreamTarget)) {
        _client = State(initialValue: client)
        _target = State(initialValue: target)
        self.resume = resume
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
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
    /// Shown over the blurred last frame while reconnecting (or leaving).
    @State private var status: String?
    /// Between stopping the old connection and starting the new one: its "ended" isn't an ending.
    @State private var isRestarting = false
    // Not @AppStorage: the once-a-second loop runs on the copy of this view from when the stream started, whose
    // @AppStorage values don't follow later changes (Stream Settings). Reading UserDefaults is always current.
    private var adaptive: Bool { UserDefaults.standard.bool(forKey: SettingsKey.adaptiveBitrate) }
    private var savedBitrate: Int { UserDefaults.standard.integer(forKey: SettingsKey.bitrate) }
    @State private var adaptiveController: BitrateController?
    @State private var adaptiveNote: String?
    @State private var adaptiveUnsupported = false
    @AppStorage(SettingsKey.performanceOverlay) private var showsPerformance = false
    @State private var performance: PerformanceOverlay.Readout?

    /// The game gets no input while a menu, Settings or Control Center is over it.
    private var isPlaying: Bool { menu == nil && !isShowingSettings && scenePhase == .active }

    private var stats: StreamStats { session.stats }
    private var shownStatus: String? { status ?? (stats.state == .connecting ? "Connecting to \(target.title)…" : nil) }

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
            if let status = shownStatus {
                ZStack {
                    // The video layer keeps its last frame: blurred and darkened, a reconnect reads as a pause. With no
                    // frame (iOS may clear it in the background) this is simply black.
                    Rectangle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                    Color.black.opacity(0.55)
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.large)
                        Text(status).font(.headline).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white)
                    .tint(.white)
                    .padding()
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: shownStatus == nil)
        .ignoresSafeArea(.keyboard) // the on-screen keyboard covers the picture rather than squeezing it
        .statusBarHidden()
        .persistentSystemOverlays(.hidden) // the home indicator fades out until touched
        .onGamepad { command in
            if command == .streamMenu { showMenu() } // other buttons will go to the game once input is sent
        }
        .actionMenu($menu)
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(live: LiveStream(target: target, setBitrate: setLiveBitrate, reconnect: { reconnect("Applying settings…") }))
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            stopInput()
        }
        .task { await run() }
        .task { await reconnectOnNetworkSwitch() }
        .onChange(of: scenePhase) { _, phase in
            // iOS freezes a backgrounded app within seconds, which would drop the stream. Disconnect cleanly instead
            // (the game keeps running) and resume once back; the extra background time covers the disconnect.
            if phase == .background, stats.state == .connected || stats.state == .connecting { reconnect("Paused") }
        }
        .onChange(of: stats.state) { _, state in
            switch state {
            case .connected:
                status = nil
                startInput()
            case .failed, .ended:
                guard !isRestarting else { return }
                status = nil
                stopInput()
                showMenu()
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
            // No X: closing this would leave a black screen. Close leaves the stream.
            menu = MenuSpec(title: "Stream ended", message: message, actions: [
                .init(title: "Reconnect") { reconnect("Reconnecting to \(target.title)…") },
                .init(title: "Close") { leave() },
            ], closable: false)
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
                            ])
        }
    }

    /// Stops the connection before closing, so the next stream can't start while this one shuts down.
    private func leave(quitting: Bool = false, then next: @escaping () -> Void = {}) {
        guard !isLeaving else { return }
        isLeaving = true
        stopInput() // lift held buttons and keys before the connection closes
        status = "Disconnecting…"
        Task {
            await session.stop()
            if quitting { try? await client.quit() }
            dismiss()
            next()
        }
    }

    /// A stream can't move to another network: when the phone switches (Wi-Fi ↔ cellular), reconnect, at whichever of the
    /// PC's addresses answers on the new network.
    private func reconnectOnNetworkSwitch() async {
        var current: String?
        // shortcut: only the preferred interface is compared, so moving between two Wi-Fi networks isn't noticed
        // (the stream ends with an error instead); compare path.gateways too if that comes up.
        for await path in NWPathMonitor() {
            guard path.status == .satisfied, let interface = path.availableInterfaces.first?.name else { continue }
            defer { current = interface }
            guard let previous = current, previous != interface, stats.state == .connected else { continue }
            reconnect("Network changed. Reconnecting…")
        }
    }

    /// Closes this connection and opens a new one without leaving the stream screen. The game keeps running on the PC.
    private func reconnect(_ reason: String) {
        guard !isRestarting, !isLeaving else { return }
        isRestarting = true
        menu = nil
        status = reason
        stopInput()
        // In the background iOS gives a few seconds before freezing the app; enough to disconnect cleanly.
        let time = UIApplication.shared.beginBackgroundTask(withName: "Disconnect")
        Task {
            await session.stop()
            UIApplication.shared.endBackgroundTask(time)
            // Left for the background: wait until the app is back in front.
            while UIApplication.shared.applicationState != .active { try? await Task.sleep(for: .milliseconds(300)) }
            status = "Reconnecting to \(target.title)…"
            do {
                (client, target) = try await resume()
                adaptiveController = nil // starts over from the new session's bitrate
                session.start(host: client, target: target, renderer: renderer)
                session.refresh() // shows "connecting" now, so the coming "connected" is a change that clears the status
                isRestarting = false // from here, an ending is real; "connected" clears the status
            } catch {
                isRestarting = false
                status = nil
                menu = MenuSpec(title: "Couldn't reconnect", message: error.localizedDescription + " The game is still running.", actions: [
                    .init(title: "Try Again") { reconnect("Reconnecting to \(target.title)…") },
                    .init(title: "Close") { leave() },
                ], closable: false)
            }
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
            if counters.frames < previous.counters.frames { previous.counters = StreamCounters() } // a reconnect restarted the counts
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
            // A setting above the live limit (up to 1000 Mbps) starts by dropping to it.
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
