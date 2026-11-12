import SwiftUI

/// Starts, resumes and quits games from any screen, and owns the stream screen. A PC runs one game at a time: the
/// running one resumes straight away; another asks to quit it first. Shown on top of everything by
/// `.streamLauncher(_:)` at the app's root.
@Observable final class StreamLauncher {
    /// e.g. "Launching Hades…" while a request is in flight.
    var busy: String?
    var menu: MenuSpec?
    /// Set after a successful launch or resume: the stream screen shows it.
    var stream: StreamTarget?
    @ObservationIgnored private var streaming: (app: HostApp, pc: PCRef)?
    @ObservationIgnored private let catalog: GameCatalog
    /// Bumped after every launch, resume or quit, so screens re-read what's running.
    private(set) var revision = 0

    init(catalog: GameCatalog) { self.catalog = catalog }

    /// `running` is the PC's running game ID (0: none) and `runningTitle` its name, for the quit question.
    func play(_ app: HostApp, on pc: PCRef, running: Int, runningTitle: String?) {
        guard busy == nil, stream == nil else { return }
        if running == 0 {
            perform("Launching \(app.title)…", on: pc, streaming: app) { [settings = Self.settings] in
                try await pc.client.launch(app, width: settings.width, height: settings.height, fps: settings.fps,
                                           videoFormats: settings.formats)
            }
        } else if app.id == running {
            perform("Resuming \(app.title)…", on: pc, streaming: app) { [settings = Self.settings] in
                try await pc.client.resume(app, width: settings.width, height: settings.height, fps: settings.fps,
                                           videoFormats: settings.formats)
            }
        } else {
            menu = MenuSpec(title: "Quit \(runningTitle ?? "the running game") to launch \(app.title)?",
                            message: "Unsaved progress in the running game may be lost.", actions: [
                .init(title: "Quit and Launch", isDestructive: true) {
                    self.perform("Launching \(app.title)…", on: pc, streaming: app) { [settings = Self.settings] in
                        try await pc.client.quit()
                        return try await pc.client.launch(app, width: settings.width, height: settings.height, fps: settings.fps,
                                                          videoFormats: settings.formats)
                    }
                },
            ])
        }
    }

    /// Takes over the session another device is streaming (the PC's Resume control).
    func join(_ control: HostApp, on pc: PCRef) {
        guard busy == nil, stream == nil else { return }
        perform("Joining the session…", on: pc, streaming: control) { [settings = Self.settings] in
            try await pc.client.launch(control, width: settings.width, height: settings.height, fps: settings.fps,
                                       videoFormats: settings.formats)
        }
    }

    /// Ends the session another device is streaming (the PC's Terminate control), after asking.
    func confirmEndSession(_ control: HostApp, on pc: PCRef) {
        menu = MenuSpec(title: "End the other device's session?",
                        message: "It disconnects that device and quits what it's playing. Unsaved progress may be lost.", actions: [
            .init(title: "End Session", isDestructive: true) {
                self.perform("Ending the session…", on: pc) { [settings = Self.settings] in
                    // The PC tears the session down and answers without a session to stream: no error to report.
                    _ = try? await pc.client.launch(control, width: settings.width, height: settings.height, fps: settings.fps,
                                                    videoFormats: settings.formats)
                    return nil
                }
            },
        ])
    }

    /// Quitting can lose unsaved progress, so it asks once.
    func confirmQuit(_ title: String?, on pc: PCRef) {
        let title = title ?? "the running game"
        menu = MenuSpec(title: "Quit \(title)?", message: "Unsaved progress may be lost.", actions: [
            .init(title: "Quit", isDestructive: true) {
                self.perform("Quitting \(title)…", on: pc) { try await pc.client.quit(); return nil }
            },
        ])
    }

    private func perform(_ label: String, on pc: PCRef, streaming app: HostApp? = nil,
                         _ action: @escaping () async throws -> LaunchSession?) {
        busy = label
        Task {
            do {
                if let launch = try await action(), let app {
                    streaming = (app, pc)
                    stream = Self.target(app, launch)
                    LaunchRequest.last = LaunchRequest(pc: pc.id, game: app.uuid.isEmpty ? app.title : app.uuid)
                    catalog.notePlayed(app, on: pc.id)
                }
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

    func streamEnded() {
        stream = nil
        revision += 1
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
            .actionMenu($launcher.menu)
            .fullScreenCover(item: $launcher.stream, onDismiss: { launcher.streamEnded() }) { target in
                if let client = launcher.client {
                    StreamView(client: client, target: target, resume: launcher.reconnect)
                }
            }
    }
}
