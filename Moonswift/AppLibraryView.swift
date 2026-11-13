import SwiftUI

/// A paired PC's games as a box-art grid, with search, All/Favorites filters and a sort order. A PC runs one game at a
/// time: tapping it (or A) resumes it, tapping another asks to quit it first. Quit sits in the toolbar (X on a
/// controller). A long press (or Y) adds or removes a favorite. B goes back; L1/R1 or up from the top row switch filters.
struct AppLibraryView: View {
    let name: String
    /// The PC's home and public addresses, to find which one answers before reconnecting.
    let localAddress: String
    let remoteAddress: String?
    /// The address that answered last.
    @State private var client: HostClient

    init(client: HostClient, name: String, localAddress: String, remoteAddress: String?) {
        _client = State(initialValue: client)
        self.name = name
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(GamepadInput.self) private var gamepad
    @Environment(StreamLauncher.self) private var launcher
    @Environment(GameCatalog.self) private var catalog
    @State private var apps: [HostApp] = []
    @State private var runningID = 0 // 0 = nothing running
    @State private var loadError: String?
    @State private var isLoaded = false
    @State private var menu: MenuSpec?
    @State private var focus = 0
    @State private var columns = 1
    @State private var isShowingSettings = false
    @State private var history = GameHistory()
    @State private var query = ""
    @State private var filter = LibraryFilter.all
    @State private var isOnFilters = false // controller focus is on the filter row
    @State private var isSearching = false
    @AppStorage("librarySort") private var sort = LibrarySort.pc
    @Environment(\.scenePhase) private var scenePhase
    private var busy: String? { launcher.busy }
    private var pc: PCRef { PCRef(id: client.hostID, name: name, client: client, localAddress: localAddress, remoteAddress: remoteAddress) }

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
                // As many as fit, rounded down to an even number so a half-folded Duo's fold falls between two columns.
                let fit = Int((width - 32 + Self.spacing) / (Self.tileWidth + Self.spacing))
                columns = fit > 1 ? fit - fit % 2 : 1
            }
        }
        .overlay {
            if !isLoaded {
                ProgressView()
            } else if let loadError, apps.isEmpty {
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
            startRequested()
        }
        .onChange(of: LaunchRouter.shared.pending) { startRequested() }
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
                if runningID != 0 { launcher.confirmQuit(running?.title, on: pc) }
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
        .toolbar { toolbar }
        // After a launch, resume, quit or stream, what's running has changed.
        .onChange(of: launcher.revision) { Task { await load() } }
        // The PC can change while you're elsewhere: a game quits, Playnite adds one. Reload when coming back...
        .onChange(of: scenePhase) { _, phase in if phase == .active, launcher.stream == nil { Task { await load() } } }
        // ...and keep the Running badge current while this list is open (a cheap status request).
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if launcher.stream == nil, busy == nil { refreshRunning() }
            }
        }
    }

    /// A link or Shortcut asked for one of this PC's games: start it the way a tap would (resume it if it's running,
    /// or ask before quitting another).
    private func startRequested() {
        guard isLoaded, let request = LaunchRouter.shared.pending, request.pc == client.hostID else { return }
        LaunchRouter.shared.pending = nil
        guard launcher.stream == nil, busy == nil else { return } // already streaming: leave it be
        guard let app = request.game(in: apps) else { return menu = .error("\(name) has no game called \(request.game).") }
        tapped(app)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let running {
            // Apart from the other buttons, beside Back: shaped like it, in red glass.
            ToolbarItem(placement: .topBarLeading) {
                Button("Quit \(running.title)", systemImage: "xmark", role: .destructive) { launcher.confirmQuit(running.title, on: pc) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .tint(.red)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu("Sort", systemImage: "arrow.up.arrow.down") {
                Picker("Sort", selection: $sort) {
                    ForEach(LibrarySort.allCases, id: \.self) { Text($0.rawValue) }
                }
            }
            Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
        }
    }

    /// A PC runs one game at a time: the running one resumes straight away; another asks to quit it first.
    private func tapped(_ app: HostApp) {
        launcher.play(app, on: pc, running: runningID, runningTitle: running?.title)
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
        catalog.reloadHistory(client.hostID)
    }

    /// A failed request is tried once more (the PC sometimes refuses one, such as a one-off "permission denied" for
    /// a list it showed a moment ago). If it still fails, the error only replaces the grid when there's nothing to
    /// show; a refresh of games already on screen keeps them.
    private func load() async {
        for attempt in 1...2 {
            do {
                async let info = client.serverInfo()
                apps = try await client.apps()
                runningID = try await info.currentGame
                loadError = nil
                break
            } catch {
                if attempt == 1 {
                    try? await Task.sleep(for: .milliseconds(500))
                } else if apps.isEmpty {
                    loadError = error.localizedDescription
                }
            }
        }
        isLoaded = true
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
    @AppStorage(SettingsKey.coverShape) private var coverShape = CoverShape.tall

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.secondary.opacity(0.15)
                .aspectRatio(coverShape.ratio, contentMode: .fit)
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
