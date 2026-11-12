import SwiftUI

/// A paired PC's games as a box-art grid, with search, All/Favorites filters and a sort order. A PC runs one game at a
/// time: tapping it (or A) resumes it, tapping another asks to quit it first. Quit sits in the toolbar (X on a
/// controller). A long press (or Y) adds or removes a favorite. B goes back; L1/R1 or up from the top row switch filters.
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
    @State private var history = GameHistory()
    @State private var query = ""
    @State private var filter = LibraryFilter.all
    @State private var isOnFilters = false // controller focus is on the filter row
    @State private var isSearching = false
    @AppStorage("librarySort") private var sort = LibrarySort.pc
    @Environment(\.scenePhase) private var scenePhase
    // Not @AppStorage: the stream screen calls reconnect() on its copy of this view, whose @AppStorage values don't
    // follow later changes (Apply & Reconnect). Reading UserDefaults is always current.
    private var resolution: ResolutionOption {
        UserDefaults.standard.string(forKey: SettingsKey.resolution).flatMap(ResolutionOption.init) ?? .fullScreen
    }
    private var savedFPS: Int { UserDefaults.standard.object(forKey: SettingsKey.fps) as? Int ?? 60 }
    private var codec: CodecOption { UserDefaults.standard.string(forKey: SettingsKey.codec).flatMap(CodecOption.init) ?? .automatic }
    private var savedBitrate: Int { UserDefaults.standard.integer(forKey: SettingsKey.bitrate) }
    private var videoFormats: Int32 {
        StreamSettings.videoFormats(for: codec, hevcInHardware: ScreenInfo.hevcInHardware, av1InHardware: ScreenInfo.av1InHardware,
                                    hdr: ScreenInfo.supportsHDR && UserDefaults.standard.bool(forKey: SettingsKey.hdr))
    }

    private static let tileWidth: CGFloat = 170
    private static let spacing: CGFloat = 24

    private var running: HostApp? { apps.first { $0.id == runningID } }
    /// What's shown, in order: the running game first, the rest filtered, searched and sorted.
    private var ordered: [HostApp] { history.arrange(apps, running: runningID, query: query, filter: filter, sort: sort) }
    private var focusIndex: Int { min(focus, max(ordered.count - 1, 0)) }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroller in
                ScrollView {
                    Picker("Show", selection: $filter) {
                        ForEach(LibraryFilter.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .focusRing(gamepad.isActive && isOnFilters, cornerRadius: 8)
                    // A fixed column count (not .adaptive) so up/down move exactly one row.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: columns),
                              spacing: 28) {
                        ForEach(Array(ordered.enumerated()), id: \.element.id) { index, app in
                            let isFavorite = history.favorites.contains(GameHistory.key(app))
                            AppTile(client: client, app: app, isRunning: app.id == runningID, isFavorite: isFavorite,
                                    isFocused: gamepad.isActive && !isOnFilters && index == focusIndex)
                                .onTapGesture {
                                    focus = index
                                    tapped(app)
                                }
                                .onLongPressGesture { toggleFavorite(app) }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityHint(app.id == runningID ? "Resumes the game." : "Launches the game.")
                                .accessibilityAction(named: isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                                    toggleFavorite(app)
                                }
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
            } else if ordered.isEmpty {
                if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ContentUnavailableView("No favorites yet", systemImage: "star",
                                           description: Text("Long-press a game, or press Y on a controller, to add it."))
                }
            }
        }
        .overlay {
            if let busy {
                ProgressView(busy).padding(24).background(.regularMaterial, in: .rect(cornerRadius: 16))
            }
        }
        .disabled(busy != nil)
        .navigationTitle(name)
        .searchable(text: $query, isPresented: $isSearching, prompt: "Search games")
        .safeAreaInset(edge: .bottom) {
            ControllerHints(hints: [([.l1, .r1], "All / Favorites"), ([.view], "Sort & Search"), ([.y], "Favorite")]
                            + (running.map { [([.x], "Quit \($0.title)")] } ?? []) + [([.menu], "Settings")])
        }
        .refreshable { await load() }
        .task {
            history = GameHistory.load(hostID: client.hostID)
            await load()
        }
        .onChange(of: filter) { focus = 0 }
        .onChange(of: query) { focus = 0 }
        .onGamepad { command in
            guard busy == nil else { return }
            switch command {
            case .up where !isOnFilters && focusIndex < columns:
                isOnFilters = true
            case .down where isOnFilters:
                isOnFilters = false
            case .left where isOnFilters, .right where isOnFilters, .previousTab, .nextTab:
                let all = LibraryFilter.allCases, index = all.firstIndex(of: filter) ?? 0
                filter = all[min(max(index + (command == .left || command == .previousTab ? -1 : 1), 0), all.count - 1)]
            case .options:
                menu = sortAndSearchMenu()
            case _ where isOnFilters && (command == .select || command == .menu):
                break
            case .up, .down, .left, .right:
                focus = FocusMove.next(focusIndex, count: ordered.count, columns: columns, command)
            case .select:
                if ordered.indices.contains(focusIndex) { tapped(ordered[focusIndex]) }
            case .menu:
                if ordered.indices.contains(focusIndex) { toggleFavorite(ordered[focusIndex]) }
            case .alternate:
                if runningID != 0 { confirmQuit() }
            case .back:
                if isSearching { isSearching = false } else { dismiss() }
            case .settings:
                isShowingSettings = true
            case .streamMenu:
                break
            }
        }
        .actionMenu($menu)
        .sheet(isPresented: $isShowingSettings) { SettingsView() }
        .sensoryFeedback(.selection, trigger: history.favorites)
        .toolbar {
            if let running {
                Button("Quit \(running.title)", systemImage: "xmark.circle.fill", role: .destructive) { confirmQuit() }
                    .tint(.red)
                    .foregroundStyle(.red)
            }
            Menu("Sort", systemImage: "arrow.up.arrow.down") {
                Picker("Sort", selection: $sort) {
                    ForEach(LibrarySort.allCases, id: \.self) { Text($0.rawValue) }
                }
            }
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

    /// A PC runs one game at a time: the running one resumes straight away; another asks to quit it first.
    private func tapped(_ app: HostApp) {
        if runningID == 0 {
            launch(app)
        } else if app.id == runningID {
            perform("Resuming \(app.title)…", streaming: app) {
                try await client.resume(app, width: mode.width, height: mode.height, fps: fps, videoFormats: videoFormats)
            }
        } else {
            menu = MenuSpec(title: "Quit \(running?.title ?? "the running game") to launch \(app.title)?",
                            message: "Unsaved progress in the running game may be lost.", actions: [
                .init(title: "Quit and Launch", isDestructive: true) {
                    perform("Launching \(app.title)…", streaming: app) {
                        try await client.quit()
                        return try await client.launch(app, width: mode.width, height: mode.height, fps: fps, videoFormats: videoFormats)
                    }
                },
            ])
        }
    }

    /// Quitting can lose unsaved progress, so it asks once.
    private func confirmQuit() {
        let title = running?.title ?? "the running game"
        menu = MenuSpec(title: "Quit \(title)?", message: "Unsaved progress may be lost.", actions: [
            .init(title: "Quit", isDestructive: true) { perform("Quitting \(title)…") { try await client.quit(); return nil } },
        ])
    }

    /// The controller's way to the toolbar's Sort and the search field (View button).
    private func sortAndSearchMenu() -> MenuSpec {
        MenuSpec(title: "Sort & Search", actions: [.init(title: "Search…") { isSearching = true }]
            + LibrarySort.allCases.map { option in
                .init(title: "Sort by \(option.rawValue)" + (option == sort ? " ✓" : "")) { sort = option }
            })
    }

    private func toggleFavorite(_ app: HostApp) {
        let key = GameHistory.key(app)
        if history.favorites.remove(key) == nil { history.favorites.insert(key) }
        history.save(hostID: client.hostID)
    }

    private func launch(_ app: HostApp) {
        perform("Launching \(app.title)…", streaming: app) {
            try await client.launch(app, width: mode.width, height: mode.height, fps: fps, videoFormats: videoFormats)
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
                    history.lastPlayed[GameHistory.key(app)] = .now
                    history.save(hostID: client.hostID)
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
        let launch = try await client.resume(app, width: mode.width, height: mode.height, fps: fps, videoFormats: videoFormats)
        return (client, streamTarget(app, launch))
    }

    private func streamTarget(_ app: HostApp, _ launch: LaunchSession) -> StreamTarget {
        StreamTarget(
            title: app.title, launch: launch, width: mode.width, height: mode.height, fps: fps,
            bitrate: StreamSettings.effectiveBitrate(saved: savedBitrate, width: mode.width, height: mode.height, fps: fps),
            videoFormats: videoFormats,
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
    let isFavorite: Bool
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
                .overlay(alignment: .topTrailing) {
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption.bold())
                            .padding(6)
                            .background(.yellow, in: .circle)
                            .foregroundStyle(.black)
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
        .accessibilityValue([isRunning ? "Running" : nil, isFavorite ? "Favorite" : nil].compactMap { $0 }.joined(separator: ", "))
        .task(id: app.artVersion) {
            if let png = try? await client.boxArt(for: app) { art = UIImage(data: png) }
        }
    }
}
