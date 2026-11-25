import MoonlightCore
import Network
import SwiftUI
import Synchronization

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

/// The game, full screen with sound, played with controllers, touch, keyboard and mouse. Three- (and four-) finger
/// gestures do what Settings → Experience → Gestures says (by default: left the control panel, up the keyboard, a hold
/// the performance overlay). Leaving the app moves it into the system's Picture in Picture window, still streaming,
/// while the app takes the input. Menu + View on a controller opens the control panel (ControlCenter): Actions (key shortcuts for the host, the
/// clipboard, Disconnect, Quit) and, a bumper away, Quick Settings (bitrate, overlay, trackpad, More Settings). The screen stays awake while streaming. Leaving the app, switching networks and Apply & Reconnect
/// reconnect in place: the last frame stays up, blurred, with the status in the middle.
struct StreamView: View {
    /// Both change on a reconnect: the PC may answer at another address, and the new session has its own keys.
    @State private var client: HostClient
    @State private var target: StreamTarget
    /// Finds the PC again, resumes the game with the current settings (or with `true`, quits it and launches it
    /// afresh), and returns the new connection.
    let resume: (Bool) async throws -> (HostClient, StreamTarget)

    init(client: HostClient, target: StreamTarget, resume: @escaping (Bool) async throws -> (HostClient, StreamTarget)) {
        _client = State(initialValue: client)
        _target = State(initialValue: target)
        self.resume = resume
    }

    @Environment(StreamLauncher.self) private var launcher
    @Environment(PCDirectory.self) private var directory
    @Environment(GameCatalog.self) private var catalog
    @Environment(\.scenePhase) private var scenePhase
    @Environment(GamepadInput.self) private var gamepad
    @AppStorage(SettingsKey.touchMode) private var touchMode = TouchMode.automatic
    @State private var session = StreamSession()
    @State private var controllers = ControllerStreamer()
    @State private var keyboardMouse = KeyboardMouseStreamer()
    @State private var isSendingInput = false
    @State private var renderer = VideoRenderer()
    @State private var foldLift: CGFloat = 0
    @State private var pictureInPicture = StreamPictureInPicture()
    @State private var menu: MenuSpec?
    /// The control panel, in from the right, on its Actions or Quick Settings tab; and the shortcut editor over it.
    @State private var panel: StreamPanel?
    /// A three-finger swipe left in progress: how far, so the panel comes out with the fingers.
    @State private var panelPull: CGFloat?
    /// A three-finger swipe right on the open panel: how far, so it goes back with the fingers.
    @State private var panelPush: CGFloat = 0
    /// This game's on-screen controller layout: the one last used with it, else Standard; choosing one remembers it.
    private var padLayoutID: Binding<String> {
        Binding(get: { catalog.padLayouts[target.title.lowercased()] ?? PadLayout.standard.id },
                set: { catalog.setPadLayout($0, forTitle: target.title) })
    }

    /// Touch: Controller draws a controller on screen, unless a real one is connected (it takes over).
    /// Automatic resolved: the on-screen controller without a game controller, the touchscreen with one.
    private var activeTouchMode: TouchMode { touchMode.resolved(controllerConnected: gamepad.isControllerConnected) }
    private var showsOnScreenPad: Bool { activeTouchMode == .controller && !gamepad.isControllerConnected && !launcher.isMinimized }

    /// A swipe left set to Quick Settings pulls the panel out on that tab.
    private var pullsQuickSettings: Bool {
        TouchGesture.active.contains { $0.kind == .swipeLeft && $0.action == .quickSettings }
    }
    /// 0 to 1: how far out the panel is.
    private var panelShown: CGFloat {
        let travel = ControlPanel<EmptyView>.travel
        let shown = panel != nil ? 1 - panelPush / travel : (panelPull ?? 0) / travel
        return min(max(shown, 0), 1)
    }
    @State private var isEditingShortcuts = false
    @State private var shortcuts = KeyShortcutStore()
    @State private var padLayouts = PadLayoutStore()
    /// Editing the on-screen controller's layout over the game (Quick Settings → Edit Layout).
    @State private var isEditingPad = false
    /// Bumped by touches on the stream outside the controls: they bring hidden controls back.
    @State private var padWake = 0
    @State private var padRouter = PadTouchRouter()
    @State private var readout = StreamReadout()
    @State private var isLeaving = false
    @State private var isShowingSettings = false
    /// A short confirmation at the top of the stream, like "Copied from PC".
    @State private var toast: String?
    /// Shown over the blurred last frame while reconnecting (or leaving).
    @State private var status: String?
    /// Between stopping the old connection and starting the new one: its "ended" isn't an ending.
    @State private var isRestarting = false
    /// It failed or ended on its own: the page that says why, with Quit & Retry.
    @State private var failure: StreamFailure?
    /// When this connection started: no picture 15 seconds on, it's given up.
    @State private var waitingSince = ContinuousClock.now
    /// When the first picture arrived, for the splash's hold.
    @State private var firstPictureAt: ContinuousClock.Instant?
    /// The stream's loud audio when the first picture came, so only sound after it counts.
    @State private var loudAtFirstPicture = 0
    static let pictureTimeout: Duration = .seconds(15)
    /// When this attempt first showed as connected, and whether it has been quietly quit and retried.
    @State private var connectedAt: ContinuousClock.Instant?
    @State private var hasQuietlyRetried = false

    /// Vibepollo, sometimes: the connection is up almost at once (the splash skips "Connecting…") but no picture ever
    /// comes, and only Quit & Retry fixes it. Seen that way, it's quit and relaunched once, behind the splash.
    // shortcut: the cause is likely the host reusing a stale virtual display (its "retained resume reuse"); this works
    // around it from the client. Drop it if the host is fixed.
    nonisolated static func shouldQuietlyRetry(connectedAfter: Duration?, waited: Duration, hasPicture: Bool,
                                               alreadyRetried: Bool) -> Bool {
        guard !hasPicture, !alreadyRetried, let connectedAfter else { return false }
        return connectedAfter <= .milliseconds(1500) && waited >= .seconds(5)
    }
    // Not @AppStorage: the once-a-second loop runs on the copy of this view from when the stream started, whose
    // @AppStorage values don't follow later changes (Stream Settings). Reading UserDefaults is always current.
    private var adaptive: Bool { UserDefaults.standard.object(forKey: SettingsKey.adaptiveBitrate) as? Bool ?? SettingsKey.adaptiveBitrateDefault }
    private var savedBitrate: Int { UserDefaults.standard.integer(forKey: SettingsKey.bitrate) }
    @State private var adaptiveController: BitrateController?
    @State private var adaptiveUnsupported = false
    @AppStorage(SettingsKey.performanceOverlay) private var showsPerformance = false
    /// Off: no floating window; leaving the app pauses the stream.
    @AppStorage(SettingsKey.pictureInPicture) private var allowsPictureInPicture = true
    @AppStorage(SettingsKey.controlCenterSide) private var controlCenterSide = ControlCenterSide.right
    private var isPanelOnLeft: Bool { controlCenterSide == .left }

    /// The game gets no input while a menu, Settings or Control Center is over it, or while it's the small window.
    private var isPlaying: Bool {
        menu == nil && panel == nil && !isEditingPad && !isShowingSettings && scenePhase == .active && !launcher.isMinimized
            && launcher.splash == nil && tutorial == nil
    }
    /// The guide cards (StreamTutorial) already dismissed, comma-separated.
    @AppStorage(SettingsKey.streamTutorialsSeen) private var tutorialsSeen = ""
    @State private var tutorial: StreamTutorial.Card?
    /// The next card not yet seen for how the stream is played now, once the game is up and in front.
    private var dueTutorial: StreamTutorial.Card? {
        guard isPlaying, shownStatus == nil, failure == nil else { return nil }
        return unseenTutorials.first
    }
    /// The cards for how the stream is played now that haven't been dismissed, in order.
    private var unseenTutorials: [StreamTutorial.Card] {
        let seen = tutorialsSeen.split(separator: ",").map(String.init)
        return StreamTutorial.Card.due(touchMode: activeTouchMode, controllerConnected: gamepad.isControllerConnected)
            .filter { !seen.contains($0.rawValue) }
    }
    private func closeTutorial() {
        if let tutorial { tutorialsSeen += tutorial.rawValue + "," }
        withAnimation { tutorial = nil }
    }
    /// The splash's line while it's up: what's happening, in calm words; nil once the picture is in.
    private var splashStatus: String? {
        if isRestarting { return hasQuietlyRetried ? "Refreshing the display…" : status } // a Quit & Retry, quiet or not
        return switch session.state {
        case .connecting: "Stabilizing connection…"
        case .connected where !session.hasPicture: "Tuning the display…"
        default: nil
        }
    }

    private var stats: StreamStats { session.stats }
    /// Until the first picture arrives (connected isn't enough: a game that didn't start sends none), so the stream
    /// only shows once there's something to see.
    private var shownStatus: String? {
        if let status { return status }
        guard failure == nil else { return nil }
        if session.state == .connecting { return "Connecting to \(target.title)…" }
        return session.state == .connected && !session.hasPicture ? "Starting \(target.title)…" : nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                // A half-open Duo with its fold across the screen: the picture sits above the fold, not bent over it.
                .onGeometryChange(for: CGFloat.self) { FoldAvoidance(fold: $0.fold, in: $0.size).lift } action: { foldLift = $0 }
            ZStack {
                VideoLayerView(renderer: renderer)
                TouchInputLayer(mode: activeTouchMode, streamSize: CGSize(width: target.width, height: target.height),
                                isPaused: !isPlaying || !isSendingInput, onGesture: gesture,
                                onSwipeProgress: followSwipe, onTouch: { padWake &+= 1 }, padRouter: padRouter,
                                allowsGestures: activeTouchMode != .controller, // the actions row stands in for them
                                keyboardGestures: Set(TouchGesture.active.filter { $0.action == .keyboard }),
                                followsSwipeLeft: Set(TouchGesture.active.filter {
                                    $0.kind == .swipeLeft && [.controlPanel, .quickSettings].contains($0.action)
                                }.map(\.fingers)),
                                pullsFromLeft: isPanelOnLeft,
                                allowsFourFingers: TouchGesture.fourFingersOn)
            }
            .padding(.bottom, foldLift)
            // Safe Area mode keeps the picture (and the touches mapped onto it) clear of the cutout and home indicator.
            .ignoresSafeArea(edges: target.fitsSafeArea ? [] : .all)
            if isEditingPad {
                PadEditor(store: padLayouts, layoutID: padLayoutID) { isEditingPad = false }
            } else if showsOnScreenPad {
                // Touch: Controller, with no real controller connected: an on-screen one, inside the safe area.
                OnScreenController(saved: padLayouts.layout(padLayoutID.wrappedValue), isPaused: !isPlaying, wake: padWake,
                                   router: padRouter, shortcuts: shortcuts.all, perform: perform) { pad in
                    if isSendingInput { controllers.setOnScreen(pad) }
                }
            }
            if showsPerformance, !launcher.isMinimized, !isEditingPad { LivePerformance(readout: readout) }
            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.7), in: .capsule)
                    .padding(.top, 40) // below the performance bar
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
            if panel != nil || panelPull != nil {
                // The game stays in view; a tap on it closes the panel.
                // No box around the panel: the stream darkens and blurs towards the right, under its controls.
                // Like iOS's Control Center: the whole stream dims evenly, and a blur (not darkened) builds up gradually
                // towards the right edge, light at the panel's left and full at its right.
                ZStack(alignment: isPanelOnLeft ? .leading : .trailing) {
                    Color.black.opacity(0.6)
                    // Starts well before the panel and builds up over it, reaching full strength 40% of the way in.
                    let lead: CGFloat = 180, panel = ControlPanel<EmptyView>.travel
                    // A plain blur (no material's grey tint, which looked off) whose strength itself varies across it: a
                    // gradient mask over a full blur showed a hard edge where the blur began.
                    GradualBlur(fullAt: (lead + panel * 0.4) / (lead + panel), fromLeading: !isPanelOnLeft)
                        .ignoresSafeArea()
                        .frame(width: lead + panel)
                }
                .opacity(panelShown)
                .ignoresSafeArea()
                .contentShape(.rect)
                    .onTapGesture { closePanel() }
                    .allowsHitTesting(panel != nil) // not while it fades away: the game takes touches at once
                    .gesture(ThreeFingerSwipe(moved: pushPanel, ended: endPush))
                    .transition(.opacity)
                    .zIndex(1) // above the video's layer as it goes, or it vanishes rather than fading
                ControlPanel(tab: panelTab, isOnLeft: isPanelOnLeft) {
                    switch panel ?? (pullsQuickSettings ? .settings : .actions) { // pulling out
                    case .actions:
                        ActionsPanel(tab: panelTab, shortcuts: shortcuts,
                                     copyFromHost: copyFromPC, sendClipboard: sendClipboardToPC,
                                     editShortcuts: { isEditingShortcuts = true },
                                     disconnect: { closePanel(); leave() },
                                     quit: { closePanel(); leave(quitting: true) },
                                     close: closePanel)
                    case .settings:
                        QuickSettingsPanel(tab: panelTab,
                                           target: target, showsPerformance: $showsPerformance, touchMode: $touchMode,
                                           setBitrate: setLiveBitrate,
                                           padLayouts: padLayouts, padLayoutID: padLayoutID,
                                           editLayout: { closePanel(); isEditingPad = true },
                                           moreSettings: { isShowingSettings = true }, // the panel stays under it
                                           close: closePanel)
                    }
                }
                .gesture(ThreeFingerSwipe(moved: pushPanel, ended: endPush))
                .allowsHitTesting(panel != nil) // not while it slides away
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isPanelOnLeft ? .leading : .trailing)
                .offset(x: panel == nil && panelPull == nil ? 0
                           : ControlPanel<EmptyView>.travel * (1 - panelShown) * (isPanelOnLeft ? -1 : 1))
                .transition(.move(edge: isPanelOnLeft ? .leading : .trailing))
                .zIndex(2) // above the video's layer as it slides away, or it vanishes rather than sliding
            }
            if let status = shownStatus {
                ZStack {
                    // Like the launch splash: the game's art, blurred and darkened (with none, the video layer's last frame).
                    if let art = LaunchSplash.art(for: target.title, catalog: catalog) {
                        Color.black
                        Color.clear.overlay { Image(uiImage: art).resizable().scaledToFill() }.clipped()
                    }
                    DimmedBlur() // the same as the launch splash's
                    // Like the launch splash: the game large in the middle, what's happening below.
                    CenteredStatus(title: target.title, detail: status.replacing(" to \(target.title)", with: "")
                        .replacing(" \(target.title)", with: ""))
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }
            if let failure {
                StreamFailurePage(failure: failure, title: target.title, canRelaunch: launcher.canRelaunch,
                                  quitAndRetry: { retry(fresh: true) }, reconnect: { retry(fresh: false) }, close: { leave(quitting: launcher.canRelaunch) })
                    .transition(.opacity)
            }
            if let tutorial {
                StreamTutorial(card: tutorial, isLast: unseenTutorials.allSatisfy { $0 == tutorial }, dismiss: closeTutorial)
                    .id(tutorial) // the next card fades in, rather than changing in place
                    .transition(.opacity)
                    .zIndex(3)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: shownStatus == nil)
        .animation(.easeInOut(duration: 0.3), value: failure == nil)
        .ignoresSafeArea(.keyboard) // the on-screen keyboard covers the picture rather than squeezing it
        // An edge swipe needs a second swipe, so play doesn't drop out by accident; not while it's the small window.
        .defersSystemGestures(on: launcher.isMinimized ? [] : .all)
        .statusBarHidden(!launcher.isMinimized)
        .persistentSystemOverlays(launcher.isMinimized ? .automatic : .hidden) // the home indicator fades out until touched
        .background {
            // Only full screen: as the small window, the app's screens take the controller (the newest handler wins).
            if !launcher.isMinimized {
                Color.clear.onGamepad { command in
                    // Over the splash, once the picture is in, any button skips the hold (and doesn't reach the game).
                    if launcher.splash != nil { if firstPictureAt != nil { launcher.endSplash() }; return }
                    if tutorial != nil { if command == .select || command == .back { closeTutorial() }; return }
                    if command == .streamMenu { showMenu(.actions) } // other buttons go to the game once input is sent
                }
            }
        }
        .onChange(of: launcher.disconnectRequest) { leave() }
        .onChange(of: launcher.isMinimized) { _, isMinimized in
            if !isMinimized { pictureInPicture.stopQuietly() } // Resume from the app: back full screen
        }
        .actionMenu($menu)
        .sheet(isPresented: $isEditingShortcuts) { ShortcutsEditView(store: shortcuts) }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(live: LiveStream(target: target, setBitrate: setLiveBitrate, reconnect: { reconnect("Applying settings…") }))
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            stopInput()
            pictureInPicture.detach()
        }
        // Leaving the app floats the game only while it's actually playing.
        .onChange(of: session.state == .connected && session.hasPicture && failure == nil && status == nil && !isLeaving,
                  initial: true) { _, isLive in pictureInPicture.allowsAutomaticStart(isLive) }
        .task { await run() }
        .task(id: client.address) { // a reconnect may reach the PC at its other address
            readout.connection = nil
            let address = client.address
            let connection = await Task.detached { connectionLabel(for: address) }.value
            if !Task.isCancelled { readout.connection = connection }
        }
        .task(id: launcher.splash != nil) { await holdSplash() } // again for a Quit & Retry's splash
        .onChange(of: splashStatus, initial: true) { _, status in launcher.splashStatus = status }
        // The on-screen controller joins the host as a controller while it shows, and leaves when it goes.
        .onChange(of: showsOnScreenPad && isSendingInput, initial: true) { _, isOn in
            controllers.setOnScreen(isOn ? PadSnapshot() : nil)
        }
        .task { await reconnectOnNetworkSwitch() }
        .onChange(of: scenePhase) { _, phase in
            // iOS freezes a backgrounded app within seconds, which would drop the stream. Disconnect cleanly instead
            // (the game keeps running) and resume once back; the extra background time covers the disconnect. In
            // Picture in Picture it keeps streaming: the playing audio keeps the app awake.
            if phase == .background, !launcher.isMinimized, !pictureInPicture.isActive,
               stats.state == .connected || stats.state == .connecting { reconnect("Paused") }
        }
        .onChange(of: session.state) { _, state in
            switch state {
            case .connected:
                status = nil
                startInput()
                setUpPictureInPicture()
            case .failed(let message), .ended(let message):
                // Ending it ourselves (Disconnect, Quit, reconnecting) isn't news: the screen just closes or reconnects.
                guard !isRestarting, !isLeaving, failure == nil else { return }
                showFailure(message)
            case .connecting: break
            }
        }
        // A way of playing in use for the first time (the first stream, a controller connecting, the on-screen
        // controller turned off): its guide card, once. It pauses input like a menu; dismissing it brings the next.
        .onChange(of: dueTutorial) { _, card in
            if let card { withAnimation { tutorial = card } }
        }
        .onChange(of: isPlaying, initial: true) { _, isPlaying in // initial: a first launch starts behind the splash
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

    /// Stops what's left of the connection and puts up the page that says what went wrong.
    private func showFailure(_ message: String) {
        var failure = StreamFailure(message: message, hadPicture: stats.videoFrames > 0)
        if !failure.hadPicture, !failure.isConnection { failure.hostSeemsStuck = launcher.countPictureless() >= 2 }
        present(failure)
    }

    private func present(_ failure: StreamFailure) {
        status = nil
        stopInput()
        menu = nil
        withAnimation(.spring(duration: 0.45, bounce: 0.15)) { launcher.isMinimized = false } // the page needs the room
        self.failure = failure
        panel = nil
        launcher.endSplash() // its page shows instead
        Task { await session.stop() } // its "ended" is ignored now the page is up
    }

    /// Quit & Retry (`fresh`) or Reconnect, from the failure page.
    private func retry(fresh: Bool) {
        failure = nil
        if fresh { firstPictureAt = nil; launcher.showSplash(target.title) } // like a launch: the splash and its wait
        reconnect(fresh ? "Quitting \(target.title)…" : "Reconnecting to \(target.title)…", fresh: fresh)
    }

    private func showMenu(_ which: StreamPanel) {
        guard failure == nil, status == nil else { return } // the page or a reconnect is in charge
        switch stats.state {
        case .failed(let message), .ended(let message):
            // No X: closing this would leave a black screen. Close leaves the stream.
            menu = MenuSpec(title: "Stream ended", message: message, actions: [
                .init(title: "Reconnect") { reconnect("Reconnecting to \(target.title)…") },
                .init(title: "Close") { leave() },
            ], closable: false)
        case .connecting, .connected:
            withAnimation(.spring(duration: 0.35, bounce: 0.1)) {
                panel = which
                panelPull = nil
            }
        }
    }

    private var panelTab: Binding<StreamPanel> {
        Binding(get: { panel ?? .actions }, set: { tab in withAnimation(.snappy(duration: 0.2)) { panel = tab } })
    }

    /// The panel follows a three-finger swipe left out of the right edge; let go short of a swipe and it slides back.
    private func followSwipe(_ pull: CGFloat?) {
        guard panel == nil else { return }
        if pull == nil {
            withAnimation(.spring(duration: 0.3, bounce: 0)) { panelPull = nil }
        } else {
            panelPull = pull.map { $0 * 1.3 } // a little ahead of the fingers, so it doesn't take a long swipe
        }
    }

    /// Three fingers on the open panel (or the game beside it) moving right push it back towards the edge.
    private func pushPanel(_ dx: CGFloat) { panelPush = max(isPanelOnLeft ? -dx : dx, 0) }

    /// Far enough (60 points, like opening) and it closes; short of that it springs back out.
    private func endPush(_ dx: CGFloat) {
        if (isPanelOnLeft ? -dx : dx) >= 60 { closePanel() } else { withAnimation(.spring(duration: 0.3, bounce: 0)) { panelPush = 0 } }
    }

    private func closePanel() {
        withAnimation(.spring(duration: 0.3, bounce: 0)) {
            panel = nil
            panelPush = 0
        }
    }

    /// A gesture's action (Settings → Experience → Gestures); Keyboard is the touch layer's own.
    private func gesture(_ gesture: TouchGesture) { perform(gesture.action) }

    /// A gesture's or the actions row's action.
    private func perform(_ action: GestureAction) {
        switch action {
        case .nothing: break
        case .keyboard: padRouter.touchView?.toggleKeyboard() // gestures set to Keyboard do it in the touch layer itself
        case .controlPanel: showMenu(.actions)
        case .quickSettings: showMenu(.settings)
        case .editLayout:
            closePanel()
            isEditingPad = true
        case .overlay:
            showsPerformance.toggle()
            show(showsPerformance ? "Performance overlay on" : "Performance overlay off")
        case .shortcut(let id):
            guard let shortcut = shortcuts.all.first(where: { $0.id == id }) else { return }
            Task { await shortcut.send() }
            show("Sent \(shortcut.keys)")
        }
    }

    private func setUpPictureInPicture() {
        guard allowsPictureInPicture else { return } // never attached: leaving the app pauses instead
        pictureInPicture.attach(renderer.layer)
        pictureInPicture.onActiveChange = { isActive in if isActive { launcher.isMinimized = true } }
        pictureInPicture.onRestore = { launcher.isMinimized = false }
        pictureInPicture.onClose = { launcher.disconnect() } // its close button: the game keeps running
    }

    private func copyFromPC() {
        Task {
            do {
                UIPasteboard.general.string = try await client.pcClipboard()
                show("Copied from the host")
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    /// Puts this device's clipboard on the PC, to paste there with Ctrl+V.
    private func sendClipboardToPC() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return show("The clipboard has no text to send.") }
        Task {
            do {
                try await client.setPCClipboard(text)
                show("Sent to the host's clipboard. Paste with Ctrl+V.")
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    private func show(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(message.count > 40 ? 5 : 2))
            if toast == message { withAnimation { toast = nil } }
        }
    }

    /// Stops the connection before closing, so the next stream can't start while this one shuts down. Quitting stays
    /// on the frozen, blurred last frame until the host has ended the game, so Home shows Play straight away.
    private func leave(quitting: Bool = false, then next: @escaping () -> Void = {}) {
        guard !isLeaving else { return }
        isLeaving = true
        pictureInPicture.detach() // closing: none of its Picture in Picture from here on
        stopInput() // lift held buttons and keys before the connection closes
        status = quitting ? "Quitting…" : "Disconnecting…"
        failure = nil // from its page: the words over the frozen picture take over
        Task {
            await session.stop() // the picture stops on its last frame
            var quitError: Error?
            if quitting {
                do {
                    try await client.quit()
                    // The host can take a few seconds to close the game: wait until it says nothing's running.
                    for _ in 0..<15 {
                        guard let running = try? await client.serverInfo().currentGame, running != 0 else { break }
                        try? await Task.sleep(for: .seconds(1))
                    }
                    launcher.forgetSession(on: client.hostID)
                    directory.noteNothingRunning(on: client.hostID)
                } catch {
                    quitError = error
                }
            }
            launcher.streamEnded()
            next()
            if let quitError { launcher.menu = .error(quitError) }
        }
    }

    /// The launch splash stays its wait past the first picture, checked often so a short wait stays short.
    private func holdSplash() async {
        while !Task.isCancelled, let splash = launcher.splash {
            try? await Task.sleep(for: .milliseconds(100))
            session.refresh()
            let now = ContinuousClock.now
            if stats.videoFrames > 0, firstPictureAt == nil, !isRestarting { // not the old session's picture
                firstPictureAt = now
                loudAtFirstPicture = stats.loudMilliseconds
            }
            guard let firstPictureAt else { continue }
            let sounds = splash.endsOnSound && stats.loudMilliseconds - loudAtFirstPicture >= 500
            if sounds || now - firstPictureAt >= splash.wait { launcher.endSplash() }
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
    private func reconnect(_ reason: String, fresh: Bool = false) {
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
            while !isLeaving, UIApplication.shared.applicationState != .active { try? await Task.sleep(for: .milliseconds(300)) }
            guard !isLeaving else { return isRestarting = false }
            status = fresh ? "Starting \(target.title)…" : "Reconnecting to \(target.title)…"
            do {
                let resumed = try await resume(fresh)
                guard !isLeaving else { return isRestarting = false } // closed meanwhile: no stream with no screen
                (client, target) = resumed
                adaptiveController = nil // starts over from the new session's bitrate
                session.start(host: client, target: target, renderer: renderer)
                session.refresh() // shows "connecting" now, so the coming "connected" is a change that clears the status
                waitingSince = .now
                connectedAt = nil
                status = nil // "Connecting…" and "Starting…" take over until the picture arrives
                isRestarting = false // from here, an ending is real
            } catch {
                isRestarting = false
                if !isLeaving { showFailure(error.localizedDescription) }
            }
        }
    }

    /// Vibepollo changes the encoder's bitrate for this session without reconnecting; other hosts don't support it.
    private func setLiveBitrate(_ kbps: Int) async -> String {
        if adaptive, !adaptiveUnsupported { return "Adaptive bitrate will use this as its ceiling." } // the loop applies it
        do {
            let applied = try await client.setBitrate(kbps)
            return applied < kbps ? "Now \(applied / 1000) Mbps, the most the host allows during a stream."
                                  : "Now \(applied / 1000) Mbps."
        } catch {
            return "This host can't change bitrate during a stream; it applies next time."
        }
    }

    private func run() async {
        session.start(host: client, target: target, renderer: renderer)
        waitingSince = .now
        let started = ContinuousClock.now
        var previous = (counters: StreamCounters(), time: started)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            session.refresh()
            let now = ContinuousClock.now
            if stats.videoFrames > 0 { launcher.notePicture() }
            if connectedAt == nil, stats.state == .connected { connectedAt = now }
            if failure == nil, !isRestarting, !isLeaving, launcher.canRelaunch,
               Self.shouldQuietlyRetry(connectedAfter: connectedAt.map { $0 - waitingSince }, waited: now - waitingSince,
                                       hasPicture: stats.videoFrames > 0, alreadyRetried: hasQuietlyRetried) {
                hasQuietlyRetried = true
                liveStats.withLock { $0.append("Connected at once with no picture: quit and retry, quietly") }
                reconnect("Starting \(target.title)…", fresh: true)
            }
            // Connected (or still trying) with no picture: the game didn't start, or the host can't capture yet.
            if stats.videoFrames == 0, failure == nil, !isRestarting, !isLeaving, now - waitingSince > Self.pictureTimeout,
               stats.state == .connecting || stats.state == .connected {
                showFailure("The host didn't send a picture within 15 seconds.")
            }
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

            readout.performance = PerformanceOverlay.Readout(window: window, targetFPS: target.fps, video: stats.videoLabel,
                                                     rtt: hasRTT ? (Int(rtt), Int(rttVariance)) : nil,
                                                     connection: readout.connection)
            if isLive {
                readout.fpsHistory = Array((readout.fpsHistory + [window.fps]).suffix(60))
                adaptStep(window.sample(rttMs: hasRTT ? Int(rtt) : nil, isPoor: stats.isPoor), now: (now - started) / .seconds(1))
            }
        }
    }

    /// One second of adaptive bitrate: let the controller decide, send any change.
    private func adaptStep(_ sample: NetworkSample, now: TimeInterval) {
        guard !adaptiveUnsupported else { return }
        let setting = StreamSettings.effectiveBitrate(saved: savedBitrate, width: target.width, height: target.height, fps: target.fps)
        let ceiling = min(setting, StreamSettings.liveBitrateLimit)
        let capNote = setting > ceiling ? " (host's limit while streaming)" : ""
        guard adaptive else {
            if adaptiveController != nil { // switched off mid-stream: back to your setting
                adaptiveController = nil
                readout.adaptiveNote = nil
                sendBitrate(ceiling)
            }
            return
        }
        guard adaptiveController != nil else {
            // A setting above the live limit (up to 1000 Mbps) starts by dropping to it.
            let controller = BitrateController(ceiling: ceiling, start: target.bitrate)
            adaptiveController = controller
            if controller.target != target.bitrate { sendBitrate(controller.target) }
            readout.adaptiveNote = "Adaptive: \(controller.target / 1000) of \(ceiling / 1000) Mbps\(capNote) · starting"
            return
        }
        if let changed = adaptiveController?.setCeiling(ceiling) { sendBitrate(changed) } // the setting changed in Stream Settings
        if let changed = adaptiveController?.update(sample, now: now) { sendBitrate(changed) }
        if let controller = adaptiveController {
            readout.adaptiveNote = "Adaptive: \(controller.target / 1000) of \(controller.ceiling / 1000) Mbps\(capNote) · \(controller.reason)"
        }
    }

    private func sendBitrate(_ kbps: Int) {
        Task {
            do {
                _ = try await client.setBitrate(kbps)
            } catch ServerInfoError.httpStatus(404) {
                adaptiveUnsupported = true
                readout.adaptiveNote = "Adaptive bitrate is off: this host can't change bitrate during a stream."
            } catch {
                // A timeout on a struggling network says nothing about the host: the next change tries again.
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

/// Why a stream stopped, for its page: the message, and whether any picture had come through.
nonisolated struct StreamFailure: Equatable {
    let message: String
    let hadPicture: Bool
    /// The second start in a row on this host with no picture.
    var hostSeemsStuck = false

    /// The connection itself couldn't be set up (rather than set up with nothing to show).
    var isConnection: Bool { message.hasPrefix("Couldn't connect to the host") || message.contains("block") }

    /// The ports the port test named, e.g. "UDP 47998, UDP 48000"; nil when it didn't run.
    private var blockedPorts: String? {
        guard let range = message.range(of: #"(blocking|blocks) [^.]+"#, options: .regularExpression) else { return nil }
        return String(message[range].drop { $0 != " " }.dropFirst())
    }

    private static let logs = "Check the host's logs for errors."

    /// The likely cause, in one line.
    var problem: String {
        if message.contains("network this device is on blocks") { return "This network blocks the streaming ports." }
        if message.contains("host's side is blocking") { return "The host's firewall is blocking the streaming ports." }
        if isConnection { return "Couldn't reach the host's streaming ports." }
        if hostSeemsStuck { return "The host's display seems stuck: it sent no video twice in a row." }
        if !hadPicture { return "The host didn't send any video." }
        return message.components(separatedBy: "\n")[0]
    }

    /// What to try, most likely first.
    var solutions: [String] {
        if message.contains("network this device is on blocks") {
            return ["Try another network, or turn off a VPN.", Self.logs]
        }
        if isConnection {
            return ["Allow \(blockedPorts ?? "the streaming ports") in the host's firewall.",
                    "Away from home, forward them on the router or use a VPN.", Self.logs]
        }
        if hostSeemsStuck {
            return ["Restart the host's streaming app or the PC, then Quit & Retry.", Self.logs]
        }
        if !hadPicture {
            return ["Quit & Retry to start it fresh.", "If it keeps happening, restart the host's streaming app or the PC.",
                    "Make sure the host's firewall allows UDP 47998.", Self.logs]
        }
        return ["Reconnect if your network dropped.", Self.logs]
    }
}

/// Full screen over the stream when it couldn't start or ended on its own: what happened, what usually fixes it, and
/// Quit & Retry, Reconnect and Close and Quit. Works by touch and with a controller.
private struct StreamFailurePage: View {
    let failure: StreamFailure
    let title: String
    /// Not for a session joined from another device: quitting would end that device's game.
    let canRelaunch: Bool
    let quitAndRetry: () -> Void
    let reconnect: () -> Void
    let close: () -> Void
    @Environment(GamepadInput.self) private var gamepad
    @State private var focus = 0

    /// Quit & Retry first when it never started (that's what fixes it); Reconnect first after playing.
    private var buttons: [(title: String, isPrimary: Bool, run: () -> Void)] {
        let retry = (title: "Quit & Retry", run: quitAndRetry), rejoin = (title: "Reconnect", run: reconnect)
        let order = !canRelaunch ? [rejoin] : failure.hadPicture ? [rejoin, retry] : [retry, rejoin]
        // Closing quits the game too (it failed or ended, so nothing's worth keeping), except another device's session.
        return order.enumerated().map { ($1.title, $0 == 0, $1.run) } + [(canRelaunch ? "Close and Quit" : "Close", false, close)]
    }

    private func section(_ heading: String, _ lines: [String], icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading).font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.6)).textCase(.uppercase)
            ForEach(lines, id: \.self) { line in
                Label(line, systemImage: icon).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
            Color.black.opacity(0.6)
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(.yellow)
                Text(failure.hadPicture ? "Stream Ended" : "Couldn't Start \(title)").font(.title2.weight(.bold))
                VStack(alignment: .leading, spacing: 14) {
                    section("Possible Problem", [failure.problem], icon: "questionmark.circle")
                    section("Possible Solutions", failure.solutions, icon: "lightbulb")
                }
                .frame(maxWidth: 520, alignment: .leading)
                HStack(spacing: 12) {
                    ForEach(Array(buttons.enumerated()), id: \.offset) { index, button in
                        Group {
                            if button.isPrimary {
                                Button(action: button.run) { Text(button.title).font(.headline).frame(minWidth: 110) }.buttonStyle(.glassProminent)
                            } else {
                                Button(action: button.run) { Text(button.title).font(.headline).frame(minWidth: 110) }.buttonStyle(.glass)
                            }
                        }
                        .focusRing(gamepad.isActive && focus == index, cornerRadius: .infinity)
                    }
                }
                .controlSize(.large)
                .padding(.top, 6)
            }
            .foregroundStyle(.white)
            .padding(32)
        }
        .ignoresSafeArea()
        .onGamepad { command in
            switch command {
            case .left: focus = max(focus - 1, 0)
            case .right: focus = min(focus + 1, buttons.count - 1)
            case .select: buttons[min(focus, buttons.count - 1)].run()
            case .back: close()
            default: break
            }
        }
    }
}

/// The stream's once-a-second numbers. Kept out of the stream screen's own state and read only by the views that
/// show them, so the screen (and any menu open over it) doesn't redraw every second.
@Observable final class StreamReadout {
    var connection: String? // "Local" or "Remote", once known
    var performance: PerformanceOverlay.Readout?
    var adaptiveNote: String?
    var fpsHistory: [Double] = [] // the last minute, for the HUD's graph
}

/// The performance overlay, reading the readout itself so only it redraws as the numbers change.
private struct LivePerformance: View {
    let readout: StreamReadout

    var body: some View {
        if let performance = readout.performance {
            PerformanceOverlay(readout: performance, adaptiveNote: readout.adaptiveNote, history: readout.fpsHistory)
        }
    }
}

/// A blur of what's behind it, using iOS's lightest dark material: it darkens a little rather than washing the stream grey.
struct ClearBlur: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    }
    func updateUIView(_ view: UIVisualEffectView, context: Context) {}
}

/// A blur that builds up gradually across its width: one blur faded in by a mask that eases in and out (smoothstep),
/// so there's no line where it begins or where it's full. (Core Animation's private variable blur ignored its mask
/// here and blurred evenly, leaving a hard edge; thin strips of rising strength showed their seams.)
struct GradualBlur: View {
    /// How far across (0 to 1) it reaches full strength, easing in from none.
    var fullAt: CGFloat = 1
    var fromLeading = true
    /// The most the blur shows at full strength; below 1 lets a little of the sharp stream through and softens the
    /// material's darkening (the public material has no radius setting).
    var strength: CGFloat = 0.8
    /// Extra darkening on top of the blur, faded in with it.
    var dim: CGFloat = 0.25
    var body: some View {
        let stops = (0...16).map { i -> Gradient.Stop in
            let p = CGFloat(i) / 16
            return .init(color: .black.opacity(strength * p * p * (3 - 2 * p)), location: p * fullAt)
        }
        ClearBlur()
            .overlay(.black.opacity(dim))
            .mask(LinearGradient(stops: stops, startPoint: fromLeading ? .leading : .trailing,
                                 endPoint: fromLeading ? .trailing : .leading))
    }
}
