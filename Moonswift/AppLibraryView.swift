import SwiftUI

/// A paired PC's games as a box-art grid. Tapping a game (or A) launches it, or offers Resume/Quit if it's
/// running; Y/X opens the game's menu; B goes back.
struct AppLibraryView: View {
    let name: String
    /// The PC's home and public addresses, to find which one answers before reconnecting.
    let localAddress: String
    let remoteAddress: String?
    /// Starts at the address that answered last; reconnects switch it (home ↔ remote) when the network changes.
    @State private var client: HostClient

    init(client: HostClient, name: String, localAddress: String, remoteAddress: String?) {
        _client = State(initialValue: client)
        self.name = name
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(GamepadInput.self) private var gamepad
    @State private var apps: [HostApp] = []
    @State private var runningID = 0 // 0 = nothing running
    @State private var loadError: String?
    @State private var isLoaded = false
    @State private var busy: String? // e.g. "Launching Hades…" while a request is in flight
    @State private var menu: MenuSpec?
    @State private var focus = 0
    @State private var columns = 1
    @State private var stream: StreamTarget? // set after a successful Launch or Resume
    @State private var isShowingSettings = false
    @State private var streamingApp: HostApp? // the game the open stream shows
    @Environment(\.scenePhase) private var scenePhase
    // Not @AppStorage: the stream screen calls reconnect() on its copy of this view, whose @AppStorage values don't
    // follow later changes (Apply & Reconnect). Reading UserDefaults is always current.
    private var resolution: ResolutionOption {
        UserDefaults.standard.string(forKey: SettingsKey.resolution).flatMap(ResolutionOption.init) ?? .fullScreen
    }
    private var savedFPS: Int { UserDefaults.standard.object(forKey: SettingsKey.fps) as? Int ?? 60 }
    private var codec: CodecOption { UserDefaults.standard.string(forKey: SettingsKey.codec).flatMap(CodecOption.init) ?? .automatic }
    private var savedBitrate: Int { UserDefaults.standard.integer(forKey: SettingsKey.bitrate) }

    private static let tileWidth: CGFloat = 170
    private static let spacing: CGFloat = 24

    private var running: HostApp? { apps.first { $0.id == runningID } }
    /// The running game first, the rest in the host's order.
    private var ordered: [HostApp] { apps.filter { $0.id == runningID } + apps.filter { $0.id != runningID } }
    private var focusIndex: Int { min(focus, max(ordered.count - 1, 0)) }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroller in
                ScrollView {
                    // A fixed column count (not .adaptive) so up/down move exactly one row.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: columns),
                              spacing: 28) {
                        ForEach(Array(ordered.enumerated()), id: \.element.id) { index, app in
                            Button {
                                focus = index
                                tapped(app)
                            } label: {
                                AppTile(client: client, app: app, isRunning: app.id == runningID,
                                        isFocused: gamepad.isActive && index == focusIndex)
                            }
                            .buttonStyle(.plain)
                            .id(app.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: focusIndex) {
                    if ordered.indices.contains(focusIndex) { withAnimation { scroller.scrollTo(ordered[focusIndex].id) } }
                }
            }
            .onChange(of: geometry.size.width, initial: true) { _, width in
                columns = max(1, Int((width - 32 + Self.spacing) / (Self.tileWidth + Self.spacing)))
            }
        }
        .overlay {
            if !isLoaded {
                ProgressView()
            } else if let loadError {
                ContentUnavailableView("Can't load games", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else if apps.isEmpty {
                ContentUnavailableView("No games", systemImage: "gamecontroller",
                                       description: Text("Add games in the streaming software on \(name)."))
            }
        }
        .overlay {
            if let busy {
                ProgressView(busy).padding(24).background(.regularMaterial, in: .rect(cornerRadius: 16))
            }
        }
        .disabled(busy != nil)
        .navigationTitle(name)
        .refreshable { await load() }
        .task { await load() }
        .onGamepad { command in
            guard busy == nil else { return }
            switch command {
            case .up, .down, .left, .right:
                focus = FocusMove.next(focusIndex, count: ordered.count, columns: columns, command)
            case .select:
                if ordered.indices.contains(focusIndex) { tapped(ordered[focusIndex]) }
            case .menu:
                if ordered.indices.contains(focusIndex) { menu = gameMenu(ordered[focusIndex]) }
            case .back:
                dismiss()
            case .settings:
                isShowingSettings = true
            case .streamMenu:
                break
            }
        }
        .actionMenu($menu)
        .sheet(isPresented: $isShowingSettings) { SettingsView() }
        .toolbar {
            Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
        }
        .fullScreenCover(item: $stream, onDismiss: { Task { await load() } }) { target in
            StreamView(client: client, target: target, resume: reconnect)
        }
        // The PC can change while you're elsewhere: a game quits, Playnite adds one. Reload when coming back...
        .onChange(of: scenePhase) { _, phase in if phase == .active, stream == nil { Task { await load() } } }
        // ...and keep the Running badge current while this list is open (a cheap status request).
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if stream == nil, busy == nil { refreshRunning() }
            }
        }
    }

    private func tapped(_ app: HostApp) {
        if runningID == 0 { launch(app) } else { menu = gameMenu(app) }
    }

    /// What can be done with `app` given what's running.
    private func gameMenu(_ app: HostApp) -> MenuSpec {
        if app.id == runningID {
            return MenuSpec(title: "\(app.title) is running", actions: [
                .init(title: "Resume") {
                    perform("Resuming \(app.title)…", streaming: app) {
                        try await client.resume(app, width: mode.width, height: mode.height, fps: fps)
                    }
                },
                .init(title: "Quit", isDestructive: true) {
                    perform("Quitting \(app.title)…") { try await client.quit(); return nil }
                },
            ])
        }
        if runningID != 0 {
            return MenuSpec(title: "Quit \(running?.title ?? "the running game") to launch \(app.title)?", actions: [
                .init(title: "Quit and Launch", isDestructive: true) {
                    perform("Launching \(app.title)…", streaming: app) {
                        try await client.quit()
                        return try await client.launch(app, width: mode.width, height: mode.height, fps: fps)
                    }
                },
            ])
        }
        return MenuSpec(title: app.title, actions: [.init(title: "Launch") { launch(app) }])
    }

    private func launch(_ app: HostApp) {
        perform("Launching \(app.title)…", streaming: app) {
            try await client.launch(app, width: mode.width, height: mode.height, fps: fps)
        }
    }

    /// Runs a host action behind a progress overlay, then re-checks which game is running. A launch or
    /// resume returns its session, and the stream screen opens for `streaming`.
    private func perform(_ label: String, streaming app: HostApp? = nil, _ action: @escaping () async throws -> LaunchSession?) {
        busy = label
        Task {
            do {
                if let launch = try await action(), let app {
                    streamingApp = app
                    stream = streamTarget(app, launch)
                }
            } catch {
                menu = .error(error.localizedDescription)
            }
            if let info = try? await client.serverInfo() { runningID = info.currentGame }
            busy = nil
        }
    }

    private func load() async {
        do {
            async let info = client.serverInfo()
            apps = try await client.apps()
            runningID = try await info.currentGame
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoaded = true
    }

    /// From the saved settings; a frame rate the screen can't show falls back to 60.
    private var fps: Int { StreamSettings.frameRates(screenMaximum: ScreenInfo.maximumFramesPerSecond).contains(savedFPS) ? savedFPS : 60 }
    private var mode: (width: Int, height: Int) {
        StreamSettings.size(for: resolution, nativePixels: ScreenInfo.nativePixels, safeAreaPixels: ScreenInfo.safeAreaPixels)
    }

    /// The stream screen's reconnect (after the background, a network switch, Apply & Reconnect): find the PC at
    /// whichever address answers now, and resume with the current settings.
    private func reconnect() async throws -> (HostClient, StreamTarget) {
        guard let app = streamingApp, let address = await answeringAddress() else { throw ServerInfoError.unreachable(.timedOut) }
        client = HostClient(hostID: client.hostID, address: address, httpsPort: client.httpsPort, serverCert: client.serverCert)
        let launch = try await client.resume(app, width: mode.width, height: mode.height, fps: fps)
        return (client, streamTarget(app, launch))
    }

    private func streamTarget(_ app: HostApp, _ launch: LaunchSession) -> StreamTarget {
        StreamTarget(
            title: app.title, launch: launch, width: mode.width, height: mode.height, fps: fps,
            bitrate: StreamSettings.effectiveBitrate(saved: savedBitrate, width: mode.width, height: mode.height, fps: fps),
            videoFormats: StreamSettings.videoFormats(for: codec, hevcInHardware: ScreenInfo.hevcInHardware),
            fitsSafeArea: resolution == .safeArea)
    }

    /// The home or public address that answers now, trying a few times while a new network settles.
    private func answeringAddress() async -> String? {
        for attempt in 1...3 {
            let result = await checkHost(address: localAddress, remoteAddress: remoteAddress,
                                         httpsPort: client.httpsPort, serverCert: client.serverCert)
            if result.status == .online(paired: true), let address = result.address { return address }
            if attempt < 3 { try? await Task.sleep(for: .seconds(4)) }
        }
        return nil
    }

    private func refreshRunning() {
        Task { if let info = try? await client.serverInfo() { runningID = info.currentGame } }
    }
}

private struct AppTile: View {
    let client: HostClient
    let app: HostApp
    let isRunning: Bool
    let isFocused: Bool
    @State private var art: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.secondary.opacity(0.15)
                .aspectRatio(3 / 4, contentMode: .fit) // GameStream box art is portrait
                .overlay {
                    if let art {
                        Image(uiImage: art).resizable().scaledToFill()
                    } else {
                        Image(systemName: "gamecontroller").font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
                .clipShape(.rect(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if isRunning {
                        Label("Running", systemImage: "play.fill")
                            .font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.green, in: .capsule)
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                }
                .overlay {
                    if isRunning { RoundedRectangle(cornerRadius: 12).stroke(.green, lineWidth: 4) }
                }
                .focusRing(isFocused)
            Text(app.title).font(.subheadline).lineLimit(2)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isRunning ? "Running" : "")
        .task(id: app.artVersion) {
            if let png = try? await client.boxArt(for: app) { art = UIImage(data: png) }
        }
    }
}
