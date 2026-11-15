import SwiftUI

/// Starts, resumes and quits games from any screen, and owns the stream screen. A PC runs one game at a time: the
/// running one resumes straight away; another asks to quit it first. Shown on top of everything by
/// `.streamLauncher(_:)` at the app's root. A four-finger pinch moves the stream into Picture in Picture, still
/// streaming; its restore button (or Resume in the app) brings it back, its close button disconnects.
@Observable final class StreamLauncher {
    /// e.g. "Launching Hades…" while a request is in flight.
    var busy: String?
    var menu: MenuSpec?
    /// Set after a successful launch or resume: the stream screen shows it.
    var stream: StreamTarget?
    /// The stream is in Picture in Picture: it keeps streaming, and the app takes the input.
    var isMinimized = false
    /// A four-finger pinch's progress while the fingers are down (1 = full size), for the stream to shrink with it.
    var pinchProgress: CGFloat?
    /// Bumped to ask the stream screen to disconnect (the game keeps running); `afterDisconnect` runs once it has.
    private(set) var disconnectRequest = 0
    @ObservationIgnored private(set) var afterDisconnect: () -> Void = {}
    @ObservationIgnored private var streaming: (app: HostApp, pc: PCRef)?
    /// The game this device streamed and hasn't quit. Disconnecting leaves it running on the PC (the session stays on),
    /// so the app shows it running whatever a status check says, until it's quit here, another game replaces it, or a
    /// Resume finds it gone (`PCDirectory.session`).
    private(set) var session: StreamingGame?
    @ObservationIgnored private let catalog: GameCatalog
    /// Bumped after every launch, resume or quit, so screens re-read what's running.
    private(set) var revision = 0

    init(catalog: GameCatalog) { self.catalog = catalog }

    /// `running` is the PC's running game ID (0: none) and `runningTitle` its name, for the quit question.
    func play(_ app: HostApp, on pc: PCRef, running: Int, runningTitle: String?) {
        guard busy == nil else { return }
        if stream != nil, let streaming {
            // The game in the small window: back to it, no reconnecting.
            if streaming.pc.id == pc.id, streaming.app.id == app.id { return withAnimation(.snappy) { isMinimized = false } }
            // Another game on the same PC needs this one quit, so that's asked first; otherwise just close the stream.
            if streaming.pc.id == pc.id, running != 0, running != app.id {
                return askToQuit(runningTitle, toLaunch: app, on: pc, disconnectingFirst: true)
            }
            return disconnect { self.play(app, on: pc, running: running, runningTitle: runningTitle) }
        }
        if running == 0 {
            perform("Launching \(app.title)…", on: pc, streaming: app) { [settings = Self.settings] in
                try await pc.client.launch(app, width: settings.width, height: settings.height, fps: settings.fps,
                                           videoFormats: settings.formats)
            }
        } else if app.id == running {
            perform("Resuming \(app.title)…", on: pc, streaming: app, isResume: true) { [settings = Self.settings] in
                try await pc.client.resume(app, width: settings.width, height: settings.height, fps: settings.fps,
                                           videoFormats: settings.formats)
            }
        } else {
            askToQuit(runningTitle, toLaunch: app, on: pc, disconnectingFirst: false)
        }
    }

    private func askToQuit(_ runningTitle: String?, toLaunch app: HostApp, on pc: PCRef, disconnectingFirst: Bool) {
        menu = MenuSpec(title: "Quit \(runningTitle ?? "the running game") to launch \(app.title)?",
                        message: "Unsaved progress in the running game may be lost.", actions: [
            .init(title: "Quit and Launch", isDestructive: true) {
                let launch = {
                    self.perform("Launching \(app.title)…", on: pc, streaming: app) { [settings = Self.settings] in
                        try await pc.client.quit()
                        return try await pc.client.launch(app, width: settings.width, height: settings.height, fps: settings.fps,
                                                          videoFormats: settings.formats)
                    }
                }
                if disconnectingFirst { self.disconnect(then: launch) } else { launch() }
            },
        ])
    }

    /// Asks the stream screen to disconnect cleanly (the game keeps running), then runs `next`.
    func disconnect(then next: @escaping () -> Void = {}) {
        guard stream != nil else { return next() }
        afterDisconnect = next
        disconnectRequest += 1
    }

    /// Joins the session another device is streaming (the PC's Join control): both stream it.
    func join(_ control: HostApp, on pc: PCRef) {
        guard busy == nil, stream == nil else { return }
        perform("Joining the session…", on: pc, streaming: control) { [settings = Self.settings] in
            try await pc.client.launch(control, width: settings.width, height: settings.height, fps: settings.fps,
                                       videoFormats: settings.formats)
        }
    }

    /// Joins another device's session, after asking: both devices then see and control the same game.
    func confirmJoin(_ control: HostApp, title: String, on pc: PCRef) {
        menu = MenuSpec(title: "Join \(title)?", message: "It's playing on another device. Both devices will see and control it.",
                        actions: [.init(title: "Join") { self.join(control, on: pc) }])
    }

    /// Ends the session another device is streaming (the PC's Terminate control), after asking.
    func confirmEndSession(_ control: HostApp, on pc: PCRef) {
        menu = MenuSpec(title: "End the other device's session?",
                        message: "It disconnects that device and quits what it's playing. Unsaved progress may be lost.", actions: [
            .init(title: "End Session", isDestructive: true) {
                self.perform("Ending the session…", on: pc) { [settings = Self.settings] in
                    let end = { try await pc.client.launch(control, width: settings.width, height: settings.height, fps: settings.fps,
                                                           videoFormats: settings.formats) }
                    // The host answers 410 both when it's done and, the first time, to ask "again to confirm": this
                    // app has already asked, so it confirms at once. Anything else (no permission) is reported.
                    do { _ = try await end() } catch ServerInfoError.hostError(410, let message) where message.contains("again") {
                        do { _ = try await end() } catch ServerInfoError.hostError(410, _) {}
                    } catch ServerInfoError.hostError(410, _) {}
                    return nil
                }
            },
        ])
    }

    /// Leaves this device's own Remote Monitor or Remote Input session (the host's Disconnect control). Nothing quits,
    /// so it doesn't ask.
    func disconnectRemote(_ control: HostApp, on pc: PCRef) {
        guard busy == nil, stream == nil else { return }
        perform("Disconnecting…", on: pc) { [settings = Self.settings] in
            // Like End: the host answers 410 without a session to stream, which isn't an error; others are.
            do { _ = try await pc.client.launch(control, width: settings.width, height: settings.height, fps: settings.fps,
                                                videoFormats: settings.formats) } catch ServerInfoError.hostError(410, _) {}
            return nil
        }
    }

    /// Quitting can lose unsaved progress, so it asks once.
    func confirmQuit(_ title: String?, on pc: PCRef) {
        let title = title ?? "the running game"
        menu = MenuSpec(title: "Quit \(title)?", message: "Unsaved progress may be lost.", actions: [
            .init(title: "Quit", isDestructive: true) {
                let quit = {
                    self.perform("Quitting \(title)…", on: pc, onSuccess: { self.forgetSession(on: pc.id) }) {
                        try await pc.client.quit()
                        return nil
                    }
                }
                // Streaming from that PC (in the small window): close the stream first, so it doesn't end in an error.
                if self.streaming?.pc.id == pc.id, self.stream != nil { self.disconnect(then: quit) } else { quit() }
            },
        ])
    }

    /// A failed `isResume` means the session is gone (the game closed, or the PC restarted): it's forgotten, so the
    /// game shows Play again.
    private func perform(_ label: String, on pc: PCRef, streaming app: HostApp? = nil, isResume: Bool = false,
                         onSuccess: @escaping () -> Void = {}, _ action: @escaping () async throws -> LaunchSession?) {
        busy = label
        Task {
            do {
                let launch = try await action()
                onSuccess()
                if let launch, let app {
                    streaming = (app, pc)
                    // Another device's session (Join) isn't one of this PC's games: nothing to show as running.
                    if app.sessionControl == nil { session = StreamingGame(pcID: pc.id, appID: app.id) }
                    stream = Self.target(app, launch)
                    LaunchRequest.last = LaunchRequest(pc: pc.id, game: app.uuid.isEmpty ? app.title : app.uuid)
                    catalog.notePlayed(app, on: pc.id)
                }
            } catch where isResume {
                forgetSession(on: pc.id)
                menu = .error("Couldn't resume \(app?.title ?? "the game") on \(pc.name). It may have closed, or the host restarted. "
                              + error.localizedDescription)
            } catch {
                menu = .error(error.localizedDescription)
            }
            busy = nil
            revision += 1
        }
    }

    /// The stream screen's reconnect (after the background, a network switch, Apply & Reconnect): find the PC at
    /// whichever address answers now, and resume with the current settings.
    func reconnect() async throws -> (HostClient, StreamTarget) {
        guard var (app, pc) = streaming, let address = await Self.answeringAddress(pc) else {
            throw ServerInfoError.unreachable(.timedOut)
        }
        pc.client = HostClient(hostID: pc.id, address: address, httpsPort: pc.client.httpsPort, serverCert: pc.client.serverCert)
        streaming = (app, pc)
        let settings = Self.settings
        let launch = try await pc.client.resume(app, width: settings.width, height: settings.height, fps: settings.fps,
                                                videoFormats: settings.formats)
        return (pc.client, Self.target(app, launch))
    }

    var client: HostClient? { streaming?.pc.client }

    /// The session's game was quit on that PC.
    func forgetSession(on pcID: String) {
        if session?.pcID == pcID { session = nil }
    }

    func streamEnded() {
        stream = nil
        streaming = nil
        isMinimized = false
        pinchProgress = nil
        revision += 1
        let next = afterDisconnect
        afterDisconnect = {}
        next()
    }

    /// The home or public address that answers now, trying a few times while a new network settles.
    private static func answeringAddress(_ pc: PCRef) async -> String? {
        for attempt in 1...3 {
            let result = await checkHost(address: pc.localAddress, remoteAddress: pc.remoteAddress,
                                         httpsPort: pc.client.httpsPort, serverCert: pc.client.serverCert)
            if result.status == .online(paired: true), let address = result.address { return address }
            if attempt < 3 { try? await Task.sleep(for: .seconds(4)) }
        }
        return nil
    }

    // MARK: Settings, read fresh at each launch

    private struct Settings: Sendable {
        let width: Int, height: Int, fps: Int, bitrate: Int, formats: Int32, fitsSafeArea: Bool
    }

    private static var settings: Settings {
        let defaults = UserDefaults.standard
        let resolution = defaults.string(forKey: SettingsKey.resolution).flatMap(ResolutionOption.init) ?? .fullScreen
        let saved = defaults.object(forKey: SettingsKey.fps) as? Int ?? 60
        let fps = StreamSettings.frameRates(screenMaximum: ScreenInfo.maximumFramesPerSecond).contains(saved) ? saved : 60
        let size = StreamSettings.size(for: resolution, nativePixels: ScreenInfo.nativePixels, safeAreaPixels: ScreenInfo.safeAreaPixels)
        let codec = defaults.string(forKey: SettingsKey.codec).flatMap(CodecOption.init) ?? .automatic
        let formats = StreamSettings.videoFormats(for: codec, hevcInHardware: ScreenInfo.hevcInHardware,
                                                  av1InHardware: ScreenInfo.av1InHardware,
                                                  hdr: ScreenInfo.supportsHDR && defaults.bool(forKey: SettingsKey.hdr))
        return Settings(width: size.width, height: size.height, fps: fps,
                        bitrate: StreamSettings.effectiveBitrate(saved: defaults.integer(forKey: SettingsKey.bitrate),
                                                                 width: size.width, height: size.height, fps: fps),
                        formats: formats, fitsSafeArea: resolution == .safeArea)
    }

    private static func target(_ app: HostApp, _ launch: LaunchSession) -> StreamTarget {
        let settings = settings
        return StreamTarget(title: app.title, launch: launch, width: settings.width, height: settings.height, fps: settings.fps,
                            bitrate: settings.bitrate, videoFormats: settings.formats, fitsSafeArea: settings.fitsSafeArea)
    }
}

extension View {
    /// The launcher's progress overlay, questions and stream screen, over everything.
    func streamLauncher(_ launcher: StreamLauncher) -> some View {
        modifier(StreamLauncherPresentation(launcher: launcher))
    }
}

private struct StreamLauncherPresentation: ViewModifier {
    @Bindable var launcher: StreamLauncher

    func body(content: Content) -> some View {
        content
            .overlay {
                if let busy = launcher.busy {
                    ZStack {
                        Color.black.opacity(0.3).ignoresSafeArea()
                        ProgressView(busy).padding(24).background(.regularMaterial, in: .rect(cornerRadius: 16))
                    }
                }
            }
            // Over the app rather than a full-screen cover, so it can shrink into a window and keep streaming.
            .overlay {
                if let target = launcher.stream, let client = launcher.client {
                    StreamWindow(launcher: launcher, client: client, target: target)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: launcher.stream == nil)
            .actionMenu($launcher.menu)
    }
}

/// The stream over the app. While pinched it shrinks with the fingers; in Picture in Picture the system's window shows
/// it, and this stays in place invisible (its video layer feeds that window) and lets touches through to the app.
private struct StreamWindow: View {
    let launcher: StreamLauncher
    let client: HostClient
    let target: StreamTarget

    var body: some View {
        let pinch = launcher.pinchProgress
        StreamView(client: client, target: target, resume: launcher.reconnect)
            .clipShape(.rect(cornerRadius: pinch == nil ? 0 : 36))
            .scaleEffect(max(pinch ?? 1, 0.25))
            .shadow(color: .black.opacity(pinch == nil ? 0 : 0.5), radius: 20, y: 8)
            .opacity(launcher.isMinimized ? 0 : 1)
            .allowsHitTesting(!launcher.isMinimized)
            .ignoresSafeArea()
    }
}
