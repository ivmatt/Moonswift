import SwiftData
import SwiftUI

/// The Library tab, after Apple's Games app: a wall of every game's cover from every PC (tap to play), filtered and
/// sorted from the small button by "Your Games". Controller: arrows move, A plays, Y favourites,
/// View opens the filter and sort menu, L1/R1 switch tabs, Menu opens Settings.
struct GamesView: View {
    var switchTab: (Int) -> Void
    var openSettings: () -> Void = {}

    /// Covers per row: five fill the Duo's open screen; six on iPad, where five come out oversized.
    static let columns = UIDevice.current.userInterfaceIdiom == .pad ? 6 : 5

    private enum Order: String, CaseIterable { case recent = "Recently Played", name = "Name" }

    @Environment(PCDirectory.self) private var directory
    @Environment(GameCatalog.self) private var catalog
    @Environment(StreamLauncher.self) private var launcher
    @Environment(GamepadInput.self) private var gamepad
    @Query(sort: \SavedHost.name) private var hosts: [SavedHost]
    @AppStorage("libraryOrder") private var order = Order.recent
    @State private var favoritesOnly = false
    @State private var showsApps = true
    @State private var focus = 0
    @State private var topInset: CGFloat = 0
    @State private var menu: MenuSpec?

    private var all: [CatalogGame] { catalog.games(on: hosts.map(\.uniqueID)) }
    private var shown: [CatalogGame] {
        let games = all.filter { (!favoritesOnly || $0.isFavorite) && (showsApps || !$0.isApp) }
        return order == .recent ? games : games.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var running: CatalogGame? { all.first { $0.isRunning(directory) } }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: Self.columns), spacing: 18) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, game in
                                cover(game, isFocused: gamepad.isActive && index == focus).id(index)
                            }
                        }
                    }
                    .padding(.horizontal, 36)
                    .padding(.bottom, 24)
                }
                .safeAreaInset(edge: .top, spacing: 0) { // fixed, like every tab's title
                    TabTitle(text: "Library", topInset: topInset).padding(.horizontal, 36).padding(.bottom, 12).background(Color.black)
                }
                .onChange(of: focus) { withAnimation { scroller.scrollTo(focus, anchor: .center) } }
            }
            .navigationTitle("Library")
            .toolbar(.hidden, for: .navigationBar) // the title is TabTitle, placed like Home's
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
            .onGamepad(handle)
            .actionMenu($menu)
        }
    }

    // MARK: Games

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(favoritesOnly ? "Favorites" : "Your Games").font(.title2.bold())
                Text("\(shown.count) Total").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Picker("Sort", selection: $order) { ForEach(Order.allCases, id: \.self) { Text($0.rawValue) } }
                Toggle("Favorites Only", isOn: $favoritesOnly)
                Toggle("Show Apps", isOn: $showsApps)
            } label: {
                Image(systemName: "line.3.horizontal.decrease").font(.subheadline.weight(.semibold)).frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Filter and Sort")
        }
    }

    private func cover(_ game: CatalogGame, isFocused: Bool) -> some View {
        let available = game.sources.contains { directory.statuses[$0.pcID] != .offline } // not dimmed while still checking
        return CoverTile(game: game, client: client(for: game), isRunning: game.isRunning(directory),
                         isAvailable: available, isFocused: isFocused)
            .onTapGesture { start(game) }
            .contextMenu {
                Button(game.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: game.isFavorite ? "star.slash" : "star") {
                    catalog.toggleFavorite(game)
                }
            }
    }

    /// The controller's way to the filter button (View): what to show and in which order.
    private func filterMenu() -> MenuSpec {
        func check(_ on: Bool) -> String { on ? " ✓" : "" }
        return MenuSpec(title: "Filter and Sort", actions: [
            .init(title: "All Games" + check(!favoritesOnly)) { favoritesOnly = false },
            .init(title: "Favorites Only" + check(favoritesOnly)) { favoritesOnly = true },
        ] + Order.allCases.map { option in .init(title: "Sort by \(option.rawValue)" + check(order == option)) { order = option } }
          + [.init(title: showsApps ? "Hide Apps" : "Show Apps") { showsApps.toggle() }])
    }

    // MARK: Actions

    private func client(for game: CatalogGame) -> HostClient? {
        game.sources.lazy.compactMap { source in self.hosts.first { $0.uniqueID == source.pcID } }.first.map { directory.ref($0).client }
    }

    private func start(_ game: CatalogGame) {
        play(game, hosts: hosts, directory: directory, catalog: catalog, launcher: launcher)
    }

    private func handle(_ command: GamepadCommand) {
        guard launcher.busy == nil else { return }
        let games = shown
        switch command {
        case .up, .down, .left, .right: focus = FocusMove.next(focus, count: games.count, columns: Self.columns, command)
        case .select: if games.indices.contains(focus) { start(games[focus]) }
        case .menu: if games.indices.contains(focus) { catalog.toggleFavorite(games[focus]) }
        case .options: menu = filterMenu()
        case .previousTab: switchTab(-1)
        case .nextTab: switchTab(1)
        case .settings: openSettings()
        default: break
        }
    }
}

/// The Search tab: every game from every PC, filtered as you type. Its title and field sit where every tab's title does.
struct GameSearchView: View {
    var switchTab: (Int) -> Void = { _ in }
    var openSettings: () -> Void = {}

    @Environment(PCDirectory.self) private var directory
    @Environment(GameCatalog.self) private var catalog
    @Environment(StreamLauncher.self) private var launcher
    @Query(sort: \SavedHost.name) private var hosts: [SavedHost]
    @State private var query = ""
    @State private var topInset: CGFloat = 0

    private var results: [CatalogGame] {
        let games = catalog.games(on: hosts.map(\.uniqueID))
        return query.isEmpty ? games : games.filter { $0.title.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(results) { game in
                Button {
                    play(game, hosts: hosts, directory: directory, catalog: catalog, launcher: launcher)
                } label: {
                    HStack(spacing: 14) {
                        CoverArt(app: game.sources[0].app, client: hosts.first { $0.uniqueID == game.sources[0].pcID }.map { directory.ref($0).client })
                            .frame(width: 45, height: 60)
                            .clipShape(.rect(cornerRadius: 8))
                        VStack(alignment: .leading) {
                            Text(game.title).font(.headline)
                            Text(game.isRunning(directory) ? "Running now" : playedText(game.lastPlayed))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(.primary)
            }
            .overlay { if !query.isEmpty, results.isEmpty { ContentUnavailableView.search(text: query) } }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    TabTitle(text: "Search", topInset: topInset)
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Games on your PCs", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !query.isEmpty {
                            Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                                .labelStyle(.iconOnly).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.white.opacity(0.1), in: .capsule)
                }
                .padding(.horizontal, 36).padding(.bottom, 4).background(Color.black)
            }
            .toolbar(.hidden, for: .navigationBar)
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
            .onGamepad { command in
                switch command {
                case .previousTab: switchTab(-1)
                case .nextTab: switchTab(1)
                case .settings: openSettings()
                default: break
                }
            }
        }
    }
}
