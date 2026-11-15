import SwiftData
import SwiftUI

/// The Library tab, after Apple's Games app: a wall of every game's cover from every PC (tap to play), searched and
/// filtered from the toolbar. Controller: arrows move, A plays, Y edits the game, View opens the filter and sort menu,
/// L1/R1 switch tabs, Menu opens Settings.
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
        // A first layout pass measures the wall with no height: that once meant covers of no width, hundreds of
        // columns, and a grid too wide to lay out (Library froze). Only a real height narrows the covers.
        let minWidth = height > 100 ? min(minCoverWidth, height * 0.35 * ratio) : minCoverWidth
        let fit = Int((width - 72 + 18) / (minWidth + 18)) // less the 36-point margins, plus one gap
        return max(2, fit - fit % 2)
    }

    private enum Order: String, CaseIterable {
        case recent = "Recently Played", name = "Name"
        var symbol: String { self == .recent ? "clock" : "textformat" }
    }

    @Environment(PCDirectory.self) private var directory
    @Environment(GameCatalog.self) private var catalog
    @Environment(StreamLauncher.self) private var launcher
    @Environment(GamepadInput.self) private var gamepad
    @Query(sort: \SavedHost.name) private var hosts: [SavedHost]
    @AppStorage("libraryOrder") private var order = Order.recent
    @AppStorage(SettingsKey.coverShape) private var coverShape = CoverShape.tall
    @AppStorage("libraryFavoritesOnly") private var favoritesOnly = false
    @AppStorage("libraryShowsApps") private var showsApps = true
    /// What the search field filters the wall by (Library is where search lives; there's no Search tab).
    @State private var query = ""
    /// Search is on: the bar shows its close button and stays put at the top as the wall scrolls. Separate from the
    /// keyboard, which scrolling puts away.
    @State private var isSearching = false
    @FocusState private var isSearchFocused: Bool
    @State private var dictation = Dictation()
    /// Read only by the header, so a scroll redraws the title and search bar, not the wall.
    @State private var scroll = LibraryScroll()
    /// An iPhone, with the tab bar along the bottom and the top bar above the title.
    @State private var isTabBarBelow = false
    /// Where the page starts: below the status bar, under the top bar that only holds the filter button; on iPad,
    /// below the tab bar across the top too.
    private var contentTop: CGFloat { UIDevice.current.userInterfaceIdiom == .pad ? topInset : HomeView.windowTopInset }
    /// The controller's focus: a cover's index, or `searchFocus` for the search bar.
    @State private var focus = 0
    private static let searchFocus = -1, closeFocus = -2 // the search bar, and its close button while searching
    @State private var topInset: CGFloat = 0
    @State private var insets = EdgeInsets()
    @State private var menu: MenuSpec?
    @State private var editing: CatalogGame?
    /// The cover a tap has readied: it shows a Play button, and a second tap there starts the game. A stray touch only
    /// readies one, so it can't start anything by itself; scrolling, or tapping elsewhere, puts it away.
    @State private var readied: String?

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
                wall
                // Under the top bar, which only holds the search button: the title stays level with every tab's, and
                // the covers keep the height to size themselves by.
                .ignoresSafeArea(edges: .top)
                // Only the title blurs as it goes (the system's edge blur reached the covers too).
                .scrollEdgeEffectHidden(true, for: .top)
                .scrollDismissesKeyboard(.immediately) // the keyboard goes, the search stays on until its close button
                .tracksTabBarMinimize()
                .overlay(alignment: .top) { header }
                .buttonGuide(guideHints)
                .onChange(of: focus) { old, new in
                    // The first row, or the search bar: the top, so the bar shows whole. Further down, only as far as it
                    // takes (a whole row's jump to the middle squished the bar away); centred going up, clear of the top.
                    if new < columns { // the search bar and its close button too
                        withAnimation { scroller.scrollTo("top", anchor: .top) }
                    } else if shown.indices.contains(new) {
                        // By game, not position: identifying covers by position kept each spot's old art after a sort or filter.
                        withAnimation { scroller.scrollTo(shown[new].id, anchor: new < old ? .center : nil) }
                    }
                }
                .overlay { if !query.isEmpty, shown.isEmpty { ContentUnavailableView.search(text: query) } }
                // One measurement for both: the columns used to be worked out in their own, from the fold offset as last
                // stored, so closing a half-open Duo kept the half-open count (two huge columns) until something resized.
                .onGeometryChange(for: CGSize.self) { CGSize(width: $0.size.width, height: $0.size.height + $0.safeAreaInsets.bottom) } action: { wallSize = $0 } // down to the screen's edge: the bar's search makes the bottom inset taller
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.fold.flatMap { $0.height > $0.width ? $0.midX - proxy.size.width / 2 : nil } ?? 0
                } action: { foldShift = $0 }
                .onTabBarBelowChange { if !hidesTabBar { isTabBarBelow = $0 } }
                .hidesTabBarOnPhone(hidesTabBar)
            }
            .navigationTitle("") // the title is TabTitle, 36 points in; the bar only holds the filter button
            .toolbar {
                // Not while searching on iPhone: the bar goes up beside it.
                if !(isSearching && isTabBarBelow) {
                    TabToolbar(hasTopBar: TabToolbar<EmptyView>.hasTopBar(insets: insets), openSettings: openSettings) { filterButton }
                }
            }
            .onChange(of: query) { if focus != Self.searchFocus { focus = 0 } }
            .onChange(of: isSearchFocused) { if isSearchFocused { withAnimation(.snappy) { isSearching = true } } }
            .onChange(of: dictation.text) { query = dictation.text }
            .onDisappear { dictation.stop() }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets = $0 }
            // Any touch (a tap, a scroll) is touch mode: the controller's highlight goes until the next press.
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in gamepad.touched() })
            .onGamepad(handle)
            .actionMenu($menu)
            .sheet(item: $editing) { GameEditView(game: $0) }
        }
    }

    // MARK: Games

    private var wall: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // The header's room: the title and search bar, or while searching just the bar at the top.
                Color.clear.frame(height: LibraryHeader.room(titleHeight: scroll.titleHeight, isSearching: isSearching))
                    .id("top")
                    // How far the wall has moved up from where it rests (its top padding below).
                    .onGeometryChange(for: CGFloat.self) { contentTop - $0.frame(in: .scrollView).minY } action: { scroll.offset = $0 }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: columns), spacing: 18) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, game in
                        cover(game, isFocused: gamepad.isActive && !isSearchFocused && index == focus)
                    }
                }
                .padding(.leading, max(0, 2 * foldShift)) // the title and header stay put
                .padding(.trailing, max(0, -2 * foldShift))
            }
            // A tap between the covers puts the readied one away.
            .background { Color.clear.contentShape(.rect).onTapGesture { withAnimation(.snappy) { readied = nil } } }
            .padding(.horizontal, 36)
            .padding(.top, contentTop) // the status bar's room, as the bar's is ignored below
            .padding(.bottom, 24)
        }
        .onScrollPhaseChange { _, phase in if phase != .idle, readied != nil { withAnimation(.snappy) { readied = nil } } }
    }

    /// iPhone: the tab bar goes while searching, and while the controller is below the first row (back at the top row,
    /// it comes back).
    private var hidesTabBar: Bool { isSearching || (gamepad.isActive && focus >= columns) }

    /// The controls a cover doesn't show: View for the filter menu, the bumpers for the other tabs. Not while typing,
    /// nor (iPhone) while the search bar is up where the guide goes.
    private var guideHints: [(buttons: [ControllerHints.Button], label: String)] {
        isSearchFocused || (isSearching && isTabBarBelow) ? []
            : [([.a], "Play"), ([.y], "Edit"), ([.view], "Filter and Sort"), ([.l1, .r1], "Tabs"), ([.menu], "Settings")]
    }

    private var header: some View {
        LibraryHeader(scroll: scroll, topInset: topInset, contentTop: contentTop, query: $query,
                      isSearching: isSearching, isSearchFocused: $isSearchFocused, dictation: dictation,
                      focused: gamepad.isActive && !isSearchFocused && focus < 0 ? (focus == Self.closeFocus ? .close : .bar) : nil,
                      close: closeSearch, dictate: toggleDictation)
    }

    /// The toolbar's filter and sort menu; filled while a filter narrows the wall (sort order isn't a filter).
    private var filterButton: some View {
        Menu {
            // A row of its own that opens the choices (a menu's first section shows no heading).
            Menu {
                Picker("Sort By", selection: $order) {
                    ForEach(Order.allCases, id: \.self) { Label($0.rawValue, systemImage: $0.symbol) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort By", systemImage: "arrow.up.arrow.down")
            }
            Section("Show") {
                Toggle("Favorites Only", systemImage: "star", isOn: $favoritesOnly)
                Toggle("Apps", systemImage: "macwindow", isOn: $showsApps)
            }
            .menuActionDismissBehavior(.disabled) // several can be flipped in one go
            if favoritesOnly || !showsApps {
                Section {
                    Button("Show Everything", systemImage: "arrow.counterclockwise") { favoritesOnly = false; showsApps = true }
                }
            }
        } label: {
            Label("Filter and Sort", systemImage: favoritesOnly || !showsApps
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        }
    }

    // MARK: Search

    private func closeSearch() {
        if focus == Self.closeFocus { focus = Self.searchFocus }
        dictation.stop()
        isSearchFocused = false
        query = ""
        withAnimation(.snappy) { isSearching = false }
    }

    /// The mic: dictation into the search, without the keyboard.
    private func toggleDictation() {
        if dictation.isListening { return dictation.stop() }
        isSearchFocused = false
        withAnimation(.snappy) { isSearching = true }
        Task { if let problem = await dictation.start() { menu = .error(problem) } }
    }

    private func cover(_ game: CatalogGame, isFocused: Bool) -> some View {
        // Only once every PC with it is known to be down, not while the first check is still out.
        let offline = game.sources.allSatisfy { directory.statuses[$0.pcID] == .offline }
        let pcName = game.sources.lazy.compactMap { s in hosts.first { $0.uniqueID == s.pcID }?.displayName }.first ?? "Its host"
        return CoverTile(game: game, client: client(for: game), isRunning: game.isRunning(directory),
                         offlinePC: offline ? pcName : nil, isFocused: isFocused)
            // Two layers, so each has its own transition: the dimming fades, the button grows as it fades.
            .overlay {
                if readied == game.id { RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.35)).transition(.opacity) }
            }
            .overlay { if readied == game.id { playButton(game).transition(.opacity.combined(with: .scale(scale: 0.9))) } }
            .scaleEffect(readied == game.id ? 1.04 : 1)
            .zIndex(readied == game.id ? 1 : 0)
            .onTapGesture {
                if readied == game.id { start(game) } else { withAnimation(.snappy) { readied = game.id } }
            }
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

    /// Over a readied cover: a Play (or Resume) button that starts it.
    private func playButton(_ game: CatalogGame) -> some View {
        Button { start(game) } label: {
            Label(game.isRunning(directory) ? "Resume" : "Play", systemImage: "play.fill")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 4)
                .frame(height: 30)
        }
        .buttonStyle(.glass) // white on glass, like Home's Play
    }

    private func start(_ game: CatalogGame) {
        readied = nil
        play(game, hosts: hosts, directory: directory, catalog: catalog, launcher: launcher)
    }

    private func handle(_ command: GamepadCommand) {
        if readied != nil { withAnimation(.snappy) { readied = nil } } // the controller has its own highlight
        guard launcher.busy == nil else { return }
        let games = shown
        // Moving off the search bar puts the keyboard away, so the highlight shows where it went.
        if [.up, .down, .left, .right].contains(command), isSearchFocused { isSearchFocused = false }
        switch command {
        case .back where isSearching: closeSearch()
        case .down where focus < 0: focus = 0
        case .right where focus == Self.searchFocus && isSearching: focus = Self.closeFocus
        case .left where focus == Self.closeFocus: focus = Self.searchFocus
        case .left where focus < 0, .right where focus < 0, .up where focus < 0: break
        case .up where focus < columns: focus = Self.searchFocus // the first row's up: the search bar
        case .up, .down, .left, .right: focus = FocusMove.next(focus, count: games.count, columns: columns, command)
        case .select where focus == Self.searchFocus: isSearchFocused = true // the keyboard; highlights hide while typing
        case .select where focus == Self.closeFocus: closeSearch()
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

/// Where Library's page has scrolled, and its title's height: kept apart from the page so scrolling redraws only the
/// header that follows them.
@Observable final class LibraryScroll {
    /// How far the wall has scrolled from the top (below zero when pulled down past it).
    var offset: CGFloat = 0
    var titleHeight: CGFloat = 0
}

/// Library's title and search bar over the top of the wall, like Apple's Files app: scrolling down, the bar squishes
/// away first, then the title goes up with the wall. While searching, the title goes and the bar stays at the top.
private struct LibraryHeader: View {
    let scroll: LibraryScroll
    let topInset: CGFloat
    let contentTop: CGFloat
    @Binding var query: String
    let isSearching: Bool
    var isSearchFocused: FocusState<Bool>.Binding
    let dictation: Dictation
    /// Where the controller's focus is in the header, if it's there.
    let focused: Focus?
    enum Focus { case bar, close }
    let close: () -> Void
    let dictate: () -> Void

    static let barHeight: CGFloat = 44
    /// Between the title and the bar.
    static let gap: CGFloat = 8
    /// The bar while searching: where the title's line was (TabTitle: 23 points down, 48 tall), clear of the edge.
    static let pinned: CGFloat = 25

    /// The height the page leaves above the wall for the header.
    static func room(titleHeight: CGFloat, isSearching: Bool) -> CGFloat {
        isSearching ? pinned + barHeight : titleHeight + gap + barHeight
    }

    var body: some View {
        let scrolled = scroll.offset, titleHeight = scroll.titleHeight
        let squish = isSearching ? 0 : min(max(scrolled, 0), Self.barHeight)
        // Follows the wall, a pull past the top included, once the bar has gone; while searching, it goes up and away.
        let titleShift = isSearching ? -titleHeight : -(scrolled - squish)
        let barTop = isSearching ? Self.pinned : titleHeight + Self.gap + titleShift
        let gone = isSearching ? 1 : titleHeight > 0 ? min(max(-titleShift - 12, 0) / titleHeight, 1) : 0
        ZStack(alignment: .topLeading) {
            TabTitle(text: "Library", topInset: topInset)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { scroll.titleHeight = $0 }
                .blur(radius: gone * 10) // blurs and fades on its way up, as the other tabs' titles do
                .opacity(1 - gone)
                .offset(y: titleShift)
                .allowsHitTesting(false)
            searchBar(height: Self.barHeight - squish)
                .offset(y: barTop)
        }
        .padding(.horizontal, 36)
        .padding(.top, contentTop)
        .ignoresSafeArea(edges: .top) // from the window's top, like the wall under it
    }

    /// Tapping it brings up the keyboard and turns search on, which makes room for the close button beside it.
    private func searchBar(height: CGFloat) -> some View {
        let shown = height / Self.barHeight
        return HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Games", text: $query)
                    .focused(isSearchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if dictation.isListening || query.isEmpty {
                    Button(dictation.isListening ? "Stop Dictation" : "Dictate", systemImage: dictation.isListening ? "mic.fill" : "mic",
                           action: dictate)
                        .foregroundStyle(dictation.isListening ? Color.red : .secondary)
                        .symbolEffect(.pulse, isActive: dictation.isListening)
                } else {
                    Button("Clear", systemImage: "xmark.circle.fill") { query = "" }.foregroundStyle(.secondary)
                }
            }
            .labelStyle(.iconOnly)
            .padding(.horizontal, 16)
            .opacity(max(0, shown * 2 - 1)) // its contents fade over the first half of the squish
            .frame(height: height)
            .clipShape(.capsule)
            .contentShape(.capsule)
            .onTapGesture { isSearchFocused.wrappedValue = true }
            .glassEffect(.regular.interactive(), in: .capsule)
            .focusRing(focused == .bar, cornerRadius: .infinity)
            .opacity(height < 6 ? 0 : 1) // not a sliver of glass
            if isSearching {
                Button("Close Search", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: Self.barHeight, height: Self.barHeight)
                    .contentShape(.circle)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .focusRing(focused == .close, cornerRadius: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .tint(.primary)
    }
}
