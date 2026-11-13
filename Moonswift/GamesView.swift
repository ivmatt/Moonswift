import SwiftData
import SwiftUI

/// The Library tab, after Apple's Games app: a wall of every game's cover from every PC (tap to play), filtered and
/// sorted from the round button by "All Games". Controller: arrows move, A plays, Y edits the game, up from the first
/// row (or View) reaches the filter and sort menu, L1/R1 switch tabs, Menu opens Settings.
struct GamesView: View {
    var switchTab: (Int) -> Void
    var openSettings: () -> Void = {}

    /// Covers per row: as many of at least `minCoverWidth` as fit, rounded down to an even number so a half-folded
    /// Duo's fold falls between two columns rather than across one (Apple's guidance for iPhone Duo). Six on the Duo's
    /// open screen, four on its outer one.
    /// The wall's size, as measured; the columns follow from it, the fold offset and the cover shape whenever any
    /// of them changes.
    @State private var wallSize = CGSize.zero
    private var columns: Int {
        wallSize.width > 0
            ? Self.columns(forWidth: wallSize.width - 2 * abs(foldShift), height: wallSize.height, ratio: coverShape.ratio) : 6
    }
    /// How far a half-open Duo's fold sits right of the wall's middle (left, if negative): the wall moves over so the
    /// fold falls in the gap between its middle columns, which the rail beside the content would otherwise put it off.
    @State private var foldShift: CGFloat = 0
    private static let minCoverWidth: CGFloat = 110

    /// On a short screen (an iPhone in landscape) covers are also kept to about a third of its `height`, so a whole
    /// row shows above the tab bar: narrower covers, more columns.
    nonisolated static func columns(forWidth width: CGFloat, height: CGFloat = .infinity, ratio: CGFloat = 2 / 3) -> Int {
        let minWidth = min(minCoverWidth, height * 0.35 * ratio)
        let fit = Int((width - 72 + 18) / (minWidth + 18)) // less the 36-point margins, plus one gap
        return max(2, fit - fit % 2)
    }

    private enum Order: String, CaseIterable { case recent = "Recently Played", name = "Name" }

    @Environment(PCDirectory.self) private var directory
    @Environment(GameCatalog.self) private var catalog
    @Environment(StreamLauncher.self) private var launcher
    @Environment(GamepadInput.self) private var gamepad
    @Query(sort: \SavedHost.name) private var hosts: [SavedHost]
    @AppStorage("libraryOrder") private var order = Order.recent
    @AppStorage(SettingsKey.coverShape) private var coverShape = CoverShape.tall
    @State private var favoritesOnly = false
    @State private var showsApps = true
    /// What the search field filters the wall by (Library is where search lives; there's no Search tab).
    @State private var query = ""
    @State private var focus = 0
    /// The controller is on Filter and Sort (up from the first row) rather than a cover.
    @State private var isFilterFocused = false
    @State private var topInset: CGFloat = 0
    @State private var menu: MenuSpec?
    @State private var editing: CatalogGame?

    private var all: [CatalogGame] { catalog.games(on: hosts.map(\.uniqueID)) }
    private var shown: [CatalogGame] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let games = all.filter { (!favoritesOnly || $0.isFavorite) && (showsApps || !$0.isApp)
                                 && (query.isEmpty || $0.title.localizedStandardContains(query)) }
        return order == .recent ? games : games.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var running: CatalogGame? { all.first { $0.isRunning(directory) } }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: columns), spacing: 18) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, game in
                                cover(game, isFocused: gamepad.isActive && !isFilterFocused && index == focus)
                            }
                        }
                        .padding(.leading, max(0, 2 * foldShift)) // the title and header stay put
                        .padding(.trailing, max(0, -2 * foldShift))
                    }
                    .padding(.horizontal, 36)
                    .padding(.top, 10) // under the fixed title, room for the filter button's focus ring (the title's backdrop would cut it)
                    .padding(.bottom, 24)
                }
                .safeAreaInset(edge: .top, spacing: 0) { // fixed, like every tab's title
                    TabTitle(text: "Library", topInset: topInset).padding(.horizontal, 36).padding(.bottom, 2).background(Color(.systemBackground))
                }
                .onChange(of: focus) {
                    // By game, not position: identifying covers by position kept each spot's old art after a sort or filter.
                    if shown.indices.contains(focus) { withAnimation { scroller.scrollTo(shown[focus].id, anchor: .center) } }
                }
                .overlay { if !query.isEmpty, shown.isEmpty { ContentUnavailableView.search(text: query) } }
                // One measurement for both: the columns used to be worked out in their own, from the fold offset as last
                // stored, so closing a half-open Duo kept the half-open count (two huge columns) until something resized.
                .onGeometryChange(for: CGSize.self) { $0.size } action: { wallSize = $0 }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.fold.flatMap { $0.height > $0.width ? $0.midX - proxy.size.width / 2 : nil } ?? 0
                } action: { foldShift = $0 }
            }
            .navigationTitle("Library")
            .toolbar(.hidden, for: .navigationBar) // the title is TabTitle, placed like Home's
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
            .onGamepad(handle)
            .actionMenu($menu)
            .sheet(item: $editing) { GameEditView(game: $0) }
        }
    }

    // MARK: Games

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(favoritesOnly ? "Favorites" : "All Games").font(.title2.bold())
                Text("\(shown.count) Total").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            searchField
            Menu {
                Picker("Sort", selection: $order) { ForEach(Order.allCases, id: \.self) { Text($0.rawValue) } }
                Toggle("Favorites Only", isOn: $favoritesOnly)
                Toggle("Show Apps", isOn: $showsApps)
            } label: {
                FunctionButtonLabel(systemImage: "line.3.horizontal.decrease", isFocused: gamepad.isActive && isFilterFocused)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Filter and Sort")
        }
    }

    /// Beside the filter button rather than on its own line, so the wall keeps its height on short screens. Touch only:
    /// a controller browses the wall instead.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).frame(height: FunctionButtonLabel.size)
        .background(Color(.tertiarySystemFill), in: .capsule) // like a system search field, as tall as the button
        .frame(maxWidth: 260)
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] } // centred on the button, like it
        .onChange(of: query) { focus = 0 }
    }

    private func cover(_ game: CatalogGame, isFocused: Bool) -> some View {
        // Only once every PC with it is known to be down, not while the first check is still out.
        let offline = game.sources.allSatisfy { directory.statuses[$0.pcID] == .offline }
        let pcName = game.sources.lazy.compactMap { s in hosts.first { $0.uniqueID == s.pcID }?.displayName }.first ?? "Its host"
        return CoverTile(game: game, client: client(for: game), isRunning: game.isRunning(directory),
                         offlinePC: offline ? pcName : nil, isFocused: isFocused)
            .onTapGesture { start(game) }
            .contextMenu {
                Button("Edit Game", systemImage: "pencil") { editing = game }
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
        case .up where !isFilterFocused && focus < columns: isFilterFocused = true // up from the first row
        case .down where isFilterFocused: isFilterFocused = false
        case .up, .down, .left, .right: if !isFilterFocused { focus = FocusMove.next(focus, count: games.count, columns: columns, command) }
        case .select where isFilterFocused: menu = filterMenu()
        case .select: if games.indices.contains(focus) { start(games[focus]) }
        case .menu: if games.indices.contains(focus) { editing = games[focus] }
        case .options: menu = filterMenu()
        case .previousTab: switchTab(-1)
        case .nextTab: switchTab(1)
        case .settings: openSettings()
        default: break
        }
    }
}
