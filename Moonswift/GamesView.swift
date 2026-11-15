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
    /// The controller's focus: a cover's index, `searchFocus` for the search bar, or a pill in the row above the covers
    /// (`rowFocus(_:)`).
    @State private var focus = 0
    private static let searchFocus = -1, closeFocus = -2 // the search bar, and its close button while searching
    /// The row's pills, left to right: Sort, Filter, the shortcuts that fit, then More if some don't.
    private static func rowFocus(_ index: Int) -> Int { -100 - index }
    private var rowIndex: Int? { focus <= -100 ? -100 - focus : nil }
    /// How many shortcuts fit beside Sort and Filter; the rest are in More.
    @State private var fittingShortcuts = 0
    /// The controller's menu for a pill (Sort, Filter, More), opening from it.
    @State private var choice: ChoiceMenuSpec?
    @State private var pillFrames = RowFrames()
    @State private var topInset: CGFloat = 0
    @State private var insets = EdgeInsets()
    @State private var menu: MenuSpec?
    @State private var editing: CatalogGame?
    /// The cover a tap has readied: it shows a Play button, and a second tap there starts the game. A stray touch only
    /// readies one, so it can't start anything by itself; scrolling, or tapping elsewhere, puts it away.
    @State private var readied: String?

    private var all: [CatalogGame] { catalog.games(on: hosts.map(\.uniqueID)) }
    /// Desktop, Steam Big Picture and the like: not games but ways into the PC, in the row above the covers.
    private var shortcuts: [CatalogGame] {
        all.filter(\.isApp).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var shown: [CatalogGame] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let games = all.filter { !$0.isApp && (!favoritesOnly || $0.isFavorite)
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
                .choiceMenu($choice)
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
                    TabToolbar(hasTopBar: TabToolbar<EmptyView>.hasTopBar(insets: insets), openSettings: openSettings) { EmptyView() }
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
                // Part of the wall, so it scrolls away with it; not while searching, which is about the games.
                if !isSearching { pillRow }
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
            : [([.a], rowIndex == nil ? (focusedGame?.isRunning(directory) == true ? "Resume" : "Play") : "Select"),
               ([.y], "Edit")] + (focusedGame?.isRunning(directory) == true ? [([.x], "Quit")] : [])
              + [([.view], "Filter"), ([.l1, .r1], "Tabs"), ([.menu], "Settings")]
    }

    private var header: some View {
        LibraryHeader(scroll: scroll, topInset: topInset, contentTop: contentTop, query: $query,
                      isSearching: isSearching, isSearchFocused: $isSearchFocused, dictation: dictation,
                      focused: gamepad.isActive && !isSearchFocused && (focus == Self.searchFocus || focus == Self.closeFocus)
                          ? (focus == Self.closeFocus ? .close : .bar) : nil,
                      close: closeSearch, dictate: toggleDictation)
    }

    /// The toolbar's filter and sort menu; filled while a filter narrows the wall (sort order isn't a filter).
    // MARK: Sort, filter and shortcuts

    /// Above the covers: Sort and Filter on the left, the shortcuts on the right (those that don't fit under More).
    private var pillRow: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: shortcuts.count, through: 0, by: -1)), id: \.self) { fit in
                HStack(spacing: 10) {
                    sortPill
                    filterPill
                    Spacer(minLength: 24)
                    ForEach(Array(shortcuts.prefix(fit).enumerated()), id: \.element.id) { index, shortcut in
                        shortcutPill(shortcut, focusIndex: 2 + index)
                    }
                    if fit < shortcuts.count { morePill(after: fit) }
                }
                .onGeometryChange(for: Int.self) { _ in fit } action: { fittingShortcuts = $0 } // the one that's shown
            }
        }
    }

    private var sortPill: some View {
        Menu {
            Picker("Sort By", selection: $order) {
                ForEach(Order.allCases, id: \.self) { Label($0.rawValue, systemImage: $0.symbol) }
            }
            .pickerStyle(.inline)
        } label: {
            PillLabel(title: order == .recent ? "Recent" : "Name", systemImage: "arrow.up.arrow.down",
                      isFocused: focused(0), isHidden: isChoiceOpen(from: 0))
        }
        .tint(.primary) // white, not the accent colour a menu gives its label
        .recordsFrame(Self.rowFocus(0), in: pillFrames)
    }

    private var filterPill: some View {
        Menu {
            Toggle("Favorites Only", systemImage: "star", isOn: $favoritesOnly)
        } label: {
            PillLabel(title: favoritesOnly ? "Favorites" : "Filter",
                      systemImage: favoritesOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease",
                      isFocused: focused(1), isHidden: isChoiceOpen(from: 1), isOn: favoritesOnly)
        }
        .tint(.primary) // white, not the accent colour a menu gives its label
        .recordsFrame(Self.rowFocus(1), in: pillFrames)
    }

    /// Starts with a tap; while running, a tap offers Resume and Quit instead.
    @ViewBuilder private func shortcutPill(_ shortcut: CatalogGame, focusIndex: Int) -> some View {
        let label = PillLabel(title: shortcut.title, systemImage: Self.symbol(for: shortcut), isFocused: focused(focusIndex),
                              isHidden: isChoiceOpen(from: focusIndex), isRunning: shortcut.isRunning(directory))
        Group {
            if shortcut.isRunning(directory) {
                Menu {
                    Button("Resume", systemImage: "play.fill") { start(shortcut) }
                    Button("Quit", systemImage: "xmark", role: .destructive) { quit(shortcut) }
                } label: { label }
                .tint(.primary)
            } else {
                Button { start(shortcut) } label: { label }.buttonStyle(.plain)
            }
        }
        .recordsFrame(Self.rowFocus(focusIndex), in: pillFrames)
        .contextMenu { Button("Edit", systemImage: "pencil") { editing = shortcut } }
    }

    private func morePill(after fit: Int) -> some View {
        let rest = Array(shortcuts.dropFirst(fit))
        return Menu {
            ForEach(rest) { shortcut in
                Button(shortcut.title, systemImage: Self.symbol(for: shortcut)) { start(shortcut) }
            }
        } label: {
            PillLabel(title: nil, systemImage: "ellipsis", isFocused: focused(2 + fit), isHidden: isChoiceOpen(from: 2 + fit))
        }
        .tint(.primary) // white, not the accent colour a menu gives its label
        .recordsFrame(Self.rowFocus(2 + fit), in: pillFrames)
    }

    private func focused(_ index: Int) -> Bool { gamepad.isActive && !isSearchFocused && rowIndex == index }
    private func isChoiceOpen(from index: Int) -> Bool { choice?.source == AnyHashable(Self.rowFocus(index)) }

    /// A shortcut's symbol, by its usual name; a generic one otherwise.
    static func symbol(for shortcut: CatalogGame) -> String {
        let title = shortcut.originalTitle.lowercased()
        if title.contains("desktop") { return "desktopcomputer" }
        if title.contains("big picture") { return "tv" }
        if title.contains("steam") { return "gamecontroller" }
        if title.contains("playnite") { return "square.grid.3x3" }
        if title.contains("monitor") { return "display" }
        if title.contains("input") { return "keyboard" }
        return "app"
    }

    /// The pills in the row: Sort, Filter, the shortcuts shown, More.
    private var rowCount: Int { 2 + fittingShortcuts + (fittingShortcuts < shortcuts.count ? 1 : 0) }

    /// A on a pill: Sort's and Filter's choices, or More's shortcuts, in the controller's menu; a shortcut starts.
    private func pressPill(_ index: Int) {
        let anchor = pillFrames.frames[Self.rowFocus(index)] ?? .zero
        switch index {
        case 0:
            choice = ChoiceMenuSpec(source: Self.rowFocus(0), options: Order.allCases.map(\.rawValue),
                                    selected: Order.allCases.firstIndex(of: order) ?? 0, anchor: anchor,
                                    pick: { order = Order.allCases[$0] }, opensRight: true)
        case 1:
            choice = ChoiceMenuSpec(source: Self.rowFocus(1), options: ["All Games", "Favorites Only"],
                                    selected: favoritesOnly ? 1 : 0, anchor: anchor,
                                    pick: { favoritesOnly = $0 == 1 }, opensRight: true)
        case let i where i < 2 + fittingShortcuts:
            let shortcut = shortcuts[i - 2]
            if shortcut.isRunning(directory) {
                choice = ChoiceMenuSpec(source: Self.rowFocus(index), options: ["Resume", "Quit"], selected: -1, anchor: anchor,
                                        pick: { $0 == 0 ? start(shortcut) : quit(shortcut) }, icons: ["play.fill", "xmark"],
                                        opensRight: true)
            } else {
                start(shortcut)
            }
        default:
            let rest = Array(shortcuts.dropFirst(fittingShortcuts))
            choice = ChoiceMenuSpec(source: Self.rowFocus(index), options: rest.map(\.title), selected: -1, anchor: anchor,
                                    pick: { start(rest[$0]) }, icons: rest.map(Self.symbol(for:)), opensRight: true)
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

    // MARK: Actions

    private func client(for game: CatalogGame) -> HostClient? {
        game.sources.lazy.compactMap { source in self.hosts.first { $0.uniqueID == source.pcID } }.first.map { directory.ref($0).client }
    }

    /// Over a readied cover: a Play (or Resume) button that starts it.
    /// Play; or, while it's running, Resume and Quit (as Home's hero offers).
    private func playButton(_ game: CatalogGame) -> some View {
        VStack(spacing: 8) {
            Button { start(game) } label: {
                Label(game.isRunning(directory) ? "Resume" : "Play", systemImage: "play.fill").overlayButtonText()
            }
            .buttonStyle(.glass) // white on glass, like Home's Play
            if game.isRunning(directory) {
                Button { readied = nil; quit(game) } label: { Label("Quit", systemImage: "xmark").overlayButtonText() }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
            }
        }
    }

    /// Asks before ending it on its PC (as Home does).
    private func quit(_ game: CatalogGame) {
        guard let source = game.sources.first(where: { directory.playing[$0.pcID] == $0.app.id }),
              let host = hosts.first(where: { $0.uniqueID == source.pcID }) else { return }
        launcher.confirmQuit(game.title, on: directory.ref(host))
    }

    private var focusedGame: CatalogGame? { shown.indices.contains(focus) ? shown[focus] : nil }

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
        // The row: left and right along it, down to the covers, up to the search bar.
        case .left where rowIndex != nil: focus = Self.rowFocus(max(rowIndex! - 1, 0))
        case .right where rowIndex != nil: focus = Self.rowFocus(min(rowIndex! + 1, rowCount - 1))
        case .up where rowIndex != nil: focus = Self.searchFocus
        case .down where rowIndex != nil: focus = 0
        case .select where rowIndex != nil: pressPill(rowIndex!)
        case .down where focus == Self.searchFocus && !isSearching: focus = Self.rowFocus(0)
        case .down where focus < 0: focus = 0
        case .right where focus == Self.searchFocus && isSearching: focus = Self.closeFocus
        case .left where focus == Self.closeFocus: focus = Self.searchFocus
        case .left where focus < 0, .right where focus < 0, .up where focus < 0: break
        case .up where focus < columns: focus = isSearching ? Self.searchFocus : Self.rowFocus(0) // the row, or the bar
        case .up, .down, .left, .right: focus = FocusMove.next(focus, count: games.count, columns: columns, command)
        case .select where focus == Self.searchFocus: isSearchFocused = true // the keyboard; highlights hide while typing
        case .select where focus == Self.closeFocus: closeSearch()
        case .select: if games.indices.contains(focus) { start(games[focus]) }
        case .menu: if games.indices.contains(focus) { editing = games[focus] }
        case .alternate: if let game = focusedGame, game.isRunning(directory) { quit(game) }
        case .options: if !isSearching { focus = Self.rowFocus(1); pressPill(1) }
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
            .opacity(min(max((shown - 0.65) / 0.35, 0), 1)) // its contents gone within the first third of the squish
            .frame(height: height)
            .clipShape(.capsule)
            .contentShape(.capsule)
            .onTapGesture { isSearchFocused.wrappedValue = true }
            .background(Color(.tertiarySystemFill), in: .capsule) // flat, like a system search field
            .focusRing(focused == .bar, cornerRadius: .infinity) // the bar itself squishes all the way to nothing
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

/// A pill in Library's row: glass, an icon and an optional title; lit while on (a filter) and outlined in green while
/// running (a shortcut).
private struct PillLabel: View {
    let title: String?
    let systemImage: String
    var isFocused = false
    /// Its controller menu is open over it.
    var isHidden = false
    var isOn = false
    var isRunning = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            if let title { Text(title).lineLimit(1) }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, title == nil ? 0 : 14)
        .frame(minWidth: 36, minHeight: 36)
        .contentShape(.capsule)
        .glassEffect(isOn ? .regular.tint(.white.opacity(0.18)).interactive() : .regular.interactive(), in: .capsule)
        .overlay { if isRunning { Capsule().stroke(.green, lineWidth: 2) } }
        .focusRing(isFocused, cornerRadius: .infinity)
        .opacity(isHidden ? 0 : 1)
        .fixedSize()
    }
}

private extension View {
    /// The text of a button over a readied cover: small enough for a cover's width, on one line.
    func overlayButtonText() -> some View {
        font(.footnote.weight(.semibold)).lineLimit(1).fixedSize().frame(minWidth: 72).frame(height: 28)
    }
}
