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
    /// open screen (half-folded too: the covers shrink to make room for the fold's shift), four on its outer one.
    /// The wall's size, as measured; the columns follow from it, the fold offset and the cover shape whenever any
    /// of them changes.
    @State private var wallSize = CGSize.zero
    private var columns: Int {
        guard layout == .grid else { return 1 } // the list: one game per row, so up and down move by one
        return wallSize.width > 0
            ? Self.columns(forWidth: wallSize.width, height: wallSize.height, ratio: coverShape.ratio) : 6
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

    /// Hidden shows only what you hid (games and shortcuts), so you can unhide it.
    private enum Filter: String, CaseIterable {
        case all = "All Games", favorites = "Favorites", hidden = "Hidden"
        var symbol: String { [.all: "square.grid.2x2", .favorites: "star", .hidden: "eye.slash"][self]! }
    }

    private enum Layout: String, CaseIterable {
        case grid = "Grid", list = "List"
        var symbol: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
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
    @AppStorage("libraryFilter") private var filter = Filter.all
    @AppStorage("libraryLayout") private var layout = Layout.grid
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
    /// 0: Sort and Filter, beside the search bar (1 is unused); from 2: the shortcuts, in their own row above the covers.
    private static func rowFocus(_ index: Int) -> Int { -100 - index }
    private var rowIndex: Int? { focus <= -100 ? -100 - focus : nil }
    private var hasShortcutRow: Bool { !isSearching && !shortcuts.isEmpty }
    /// The controller's menu for a pill or shortcut (Sort, Filter, a running shortcut's Resume and Quit), opening from it.
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
        all.filter { $0.isApp && !$0.isHidden }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var shown: [CatalogGame] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let games = all.filter { (filter == .hidden ? $0.isHidden : !$0.isApp && !$0.isHidden
                                      && (filter == .all || $0.isFavorite))
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
                .buttonLegend(legendHints)
                .onChange(of: focus) { old, new in
                    // The first row, or the search bar: the top, so the bar shows whole. Further down, only as far as it
                    // takes (a whole row's jump to the middle squished the bar away); centred going up, clear of the top.
                    if new < columns { // the search bar and its close button too
                        withAnimation { scroller.scrollTo("top", anchor: .top) }
                    } else if shown.indices.contains(new) {
                        // The cover's whole row, margins and all, not the cover: scrollTo sometimes lines its target's left
                        // edge up with the screen's, which for a cover in from the edge moved the whole page sideways (and
                        // nothing moved it back). A target as wide as the page can only move up and down. A list row low
                        // down going down: "only as far as it takes" left it under the legend.
                        let anchor: UnitPoint? = layout == .list ? UnitPoint(x: 0.5, y: new < old ? 0.5 : 0.85)
                            : new < old ? .center : nil
                        withAnimation { scroller.scrollTo(layout == .list ? AnyHashable(shown[new].id) : AnyHashable(Self.rowID(new / columns)), anchor: anchor) }
                    }
                }
                // No covers to land on: the controller starts on the apps.
                .onChange(of: shown.isEmpty && hasShortcutRow, initial: true) { _, onlyApps in
                    if onlyApps, focus == 0 { focus = Self.rowFocus(2) }
                }
                .overlay {
                    if !query.isEmpty, shown.isEmpty { ContentUnavailableView.search(text: query) }
                    else if filter == .hidden, shown.isEmpty {
                        ContentUnavailableView("No Hidden Games", systemImage: "eye.slash",
                                               description: Text("Games you hide leave Home and Library and show up here."))
                    } else if filter == .all, query.isEmpty, shown.isEmpty, !all.isEmpty {
                        ContentUnavailableView("No Games Yet", systemImage: "gamecontroller",
                                               description: Text("Add games on your host, or edit an app to show it as a game."))
                            .padding(.top, 150) // below the search bar and the apps row
                    }
                }
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
            .onChange(of: shortcuts.map(\.id)) { old, new in
                guard let rowIndex, rowIndex >= 2 else { return }
                focus = Self.followedPosition(rowIndex - 2, from: old, to: new).map { Self.rowFocus($0 + 2) } ?? 0
            }
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
            // Only Search's own keyboard makes room here; a sheet's mustn't move the page behind it.
            .ignoresSafeArea(isSearchFocused ? [] : .keyboard)
        }
    }

    // MARK: Games

    private var wall: some View {
        // Read here, on the main actor: the measuring closure below can run on another thread, where reading the
        // window's inset (main-actor only) crashed the app as a stream started.
        let contentTop = contentTop
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // The header's room: the title and search bar, or while searching just the bar at the top.
                Color.clear.frame(height: LibraryHeader<EmptyView>.room(titleHeight: scroll.titleHeight, isSearching: isSearching))
                    .id("top")
                    // How far the wall has moved up from where it rests (its top padding below).
                    .onGeometryChange(for: CGFloat.self) { contentTop - $0.frame(in: .scrollView).minY } action: { scroll.offset = $0 }
                // Part of the wall, so it scrolls away with it; not while searching, which is about the games.
                if hasShortcutRow { shortcutRow.padding(.horizontal, 36) }
                if layout == .list {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, game in
                            listRow(game, isFocused: gamepad.isActive && !isSearchFocused && index == focus)
                                .padding(coverMargins)
                        }
                    }
                } else {
                    LazyVStack(spacing: 18) {
                        ForEach(0..<(shown.count + columns - 1) / columns, id: \.self) { row in
                            HStack(alignment: .top, spacing: 18) {
                                // By game, not position: identifying covers by position kept each spot's old art after a sort or filter.
                                ForEach(Array(shown.enumerated())[row * columns..<min(shown.count, (row + 1) * columns)], id: \.element.id) { index, game in
                                    cover(game, isFocused: gamepad.isActive && !isSearchFocused && index == focus)
                                        .frame(minWidth: 0, maxWidth: .infinity) // equal columns
                                }
                                ForEach(0..<columns - min(columns, shown.count - row * columns), id: \.self) { _ in
                                    Color.clear.frame(height: 0).frame(minWidth: 0, maxWidth: .infinity) // a short last row's empty spots
                                }
                            }
                            .padding(coverMargins)
                            .id(Self.rowID(row))
                        }
                    }
                }
            }
            // A tap between the covers puts the readied one away.
            .background { Color.clear.contentShape(.rect).onTapGesture { withAnimation(.snappy) { readied = nil } } }
            .padding(.top, contentTop) // the status bar's room, as the bar's is ignored below
            .padding(.bottom, 24)
        }
        .onScrollPhaseChange { _, phase in if phase != .idle, readied != nil { withAnimation(.snappy) { readied = nil } } }
    }

    /// The covers' margins, inside each row so a row is a scroll target as wide as the page (see the focus scrolling).
    /// Off the fold on a half-open Duo; the title and header stay put.
    private var coverMargins: EdgeInsets {
        EdgeInsets(top: 0, leading: 36 + max(0, 2 * foldShift), bottom: 0, trailing: 36 + max(0, -2 * foldShift))
    }

    private static func rowID(_ row: Int) -> String { "row \(row)" }

    /// iPhone: the tab bar goes while searching, and while the controller is below the first row (back at the top row,
    /// it comes back).
    private var hidesTabBar: Bool { isSearching || (gamepad.isActive && focus >= columns) }

    /// The controls a cover doesn't show: View for the filter menu, the bumpers for the other tabs. Not while typing,
    /// nor (iPhone) while the search bar is up where the legend goes.
    private var legendHints: [(buttons: [ControllerHints.Button], label: String)] {
        if isSearchFocused || (isSearching && isTabBarBelow) { return [] }
        var hints: [(buttons: [ControllerHints.Button], label: String)] =
            [([.a], rowIndex == nil ? (focusedGame?.isRunning(directory) == true ? focusedGame!.runningLabels(directory, catalog).resume : "Play") : "Select")]
        if focusedGame != nil || focusedApp != nil { hints.append(([.y], "Edit")) }
        if let focusedGame, focusedGame.isRunning(directory) { hints.append(([.x], focusedGame.runningLabels(directory, catalog).quit)) }
        return hints + [([.view], "Filter"), ([.l1, .r1], "Tabs"), ([.menu], "Settings")]
    }

    private var header: some View {
        LibraryHeader(scroll: scroll, topInset: topInset, contentTop: contentTop, query: $query,
                      isSearching: isSearching, isSearchFocused: $isSearchFocused, dictation: dictation,
                      focused: gamepad.isActive && !isSearchFocused && (focus == Self.searchFocus || focus == Self.closeFocus)
                          ? (focus == Self.closeFocus ? .close : .bar) : nil,
                      close: closeSearch, dictate: toggleDictation) {
            sortAndFilter
        }
    }

    /// The toolbar's filter and sort menu; filled while a filter narrows the wall (sort order isn't a filter).
    // MARK: Sort, filter and shortcuts

    /// Above the covers: the shortcuts, scrolling sideways when there are more than fit.
    private var shortcutRow: some View {
        ScrollViewReader { row in
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(Array(shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                        shortcutTile(shortcut, focusIndex: 2 + index).id(shortcut.id)
                    }
                }
                .padding(12) // room for the focus ring, grown 5% and outset
            }
            .scrollIndicators(.hidden)
            // Ends with the covers' grid, fading out at its right edge where more scroll in.
            .mask {
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 56)
                }
            }
            .padding(-12) // the ring's room aside: in line with the covers, the row's gaps unchanged
            .padding(.vertical, -6) // closer to the bar above and the covers below than the wall's usual gap
            .onChange(of: rowIndex) { _, index in
                guard let index, index >= 2, shortcuts.indices.contains(index - 2) else { return }
                withAnimation { row.scrollTo(shortcuts[index - 2].id, anchor: .center) }
            }
        }
    }

    /// Sort and Filter in one button: the sort order, a line, then what to show. Lit while a filter narrows the wall.
    private var sortAndFilter: some View {
        Menu {
            Picker("Sort By", selection: $order) {
                ForEach(Order.allCases, id: \.self) { Label($0.rawValue, systemImage: $0.symbol) }
            }
            .pickerStyle(.inline)
            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("View As", selection: $layout) {
                ForEach(Layout.allCases, id: \.self) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            PillLabel(title: nil, systemImage: filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill",
                      isFocused: focused(0), isHidden: isChoiceOpen(from: 0), isOn: filter != .all)
        }
        .tint(.primary) // white, not the accent colour a menu gives its label
        .recordsFrame(Self.rowFocus(0), in: pillFrames)
    }

    /// Starts with a tap; while running, a tap offers Resume and Quit instead. A long press opens its menu only: a
    /// menu with a primary action keeps the two apart (a button or tap gesture with a context menu also fired on
    /// letting go).
    private func shortcutTile(_ shortcut: CatalogGame, focusIndex: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        return Menu {
            Button("Edit", systemImage: "pencil") { editing = shortcut }
            Button("Hide", systemImage: "eye.slash") { catalog.setHidden(true, for: shortcut) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: Self.symbol(for: shortcut))
                Text(shortcut.title).lineLimit(1)
            }
                .opacity(shortcut.isWaitingForStatus(directory, launcher) ? 0.5 : 1)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .frame(height: 38)
                .background(.white.opacity(0.12), in: shape) // translucent, like the App Store's category buttons
                .contentShape(shape)
            .overlay { if shortcut.isRunning(directory) { shape.stroke(shortcut.elsewhere(directory, catalog) != nil ? .orange : .green, lineWidth: 2) } }
        } primaryAction: {
            pressPill(focusIndex)
        }
        .tint(.primary) // white, not the accent colour a menu gives its label
        .focusRing(focused(focusIndex), cornerRadius: 9)
        .opacity(isChoiceOpen(from: focusIndex) ? 0 : 1)
        .recordsFrame(Self.rowFocus(focusIndex), in: pillFrames)
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

    /// A on a pill: Sort's and Filter's choices, or More's shortcuts, in the controller's menu; a shortcut starts.
    private func pressPill(_ index: Int) {
        let anchor = pillFrames.frames[Self.rowFocus(index)] ?? .zero
        switch index {
        case 0:
            // Sort, a line, Filter, a line, View As: one tick in each.
            let sorts = Order.allCases.count, layouts = sorts + Filter.allCases.count
            choice = ChoiceMenuSpec(source: Self.rowFocus(0),
                                    options: Order.allCases.map(\.rawValue) + Filter.allCases.map(\.rawValue) + Layout.allCases.map(\.rawValue),
                                    selected: Order.allCases.firstIndex(of: order) ?? 0, anchor: anchor,
                                    pick: { index in
                                        if index < sorts { order = Order.allCases[index] }
                                        else if index < layouts { filter = Filter.allCases[index - sorts] }
                                        else { layout = Layout.allCases[index - layouts] }
                                    },
                                    groupStarts: [sorts, layouts],
                                    alsoTicked: [sorts + (Filter.allCases.firstIndex(of: filter) ?? 0),
                                                 layouts + (Layout.allCases.firstIndex(of: layout) ?? 0)],
                                    opensRight: true)
        default:
            guard shortcuts.indices.contains(index - 2) else { return }
            let shortcut = shortcuts[index - 2]
            guard !shortcut.isWaitingForStatus(directory, launcher) else { return }
            if shortcut.isRunning(directory) {
                choice = ChoiceMenuSpec(source: Self.rowFocus(index), options: [shortcut.runningLabels(directory, catalog).resume, shortcut.runningLabels(directory, catalog).quit], selected: -1, anchor: anchor,
                                        pick: { $0 == 0 ? start(shortcut) : quit(shortcut) }, icons: ["play.fill", "xmark"],
                                        opensRight: true)
            } else {
                start(shortcut)
            }
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
        return CoverTile(game: game, client: client(for: game), isRunning: game.isRunning(directory),
                         unavailable: game.unavailable(hosts: hosts, directory: directory), isFocused: isFocused,
                         isElsewhere: game.elsewhere(directory, catalog) != nil)
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
            .contextMenu { gameMenu(game) }
    }

    /// A cover's or row's long-press menu.
    @ViewBuilder private func gameMenu(_ game: CatalogGame) -> some View {
        Button("Edit Game", systemImage: "pencil") { editing = game }
        Button(game.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: game.isFavorite ? "star.slash" : "star") {
            catalog.toggleFavorite(game)
        }
        Button(game.isHidden ? "Unhide" : "Hide", systemImage: game.isHidden ? "eye" : "eye.slash") {
            catalog.setHidden(!game.isHidden, for: game)
        }
    }

    /// The list's row: a small cover, the name, its host and when it was last played, and its own Play (or Resume and
    /// Quit) on the right; a tap on the row itself does nothing, so scrolling never starts a game.
    private func listRow(_ game: CatalogGame, isFocused: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        let isRunning = game.isRunning(directory)
        return HStack(spacing: 14) {
            CoverArt(app: game.sources[0].app, client: client(for: game), custom: catalog.shownCover(for: game.id, coverShape),
                     title: game.title)
                .frame(width: 64 * coverShape.ratio, height: 64)
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(game.title).font(.headline).lineLimit(1)
                    if game.isFavorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                }
                Text(details(game)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Group {
                if isRunning {
                    Button(game.runningLabels(directory, catalog).resume, systemImage: "play.fill") { start(game) }
                        .buttonStyle(.glass)
                    Button(game.runningLabels(directory, catalog).quit, systemImage: "xmark") { quit(game) }
                        .buttonStyle(.glassProminent)
                        .tint(.red)
                } else {
                    Button("Play", systemImage: "play.fill") { start(game) }.buttonStyle(.glass)
                }
            }
            .disabled(game.isWaitingForStatus(directory, launcher))
        }
        .font(.subheadline.weight(.semibold))
        .padding(10)
        .background(.white.opacity(0.08), in: shape)
        .overlay { if isRunning { shape.stroke(game.elsewhere(directory, catalog) != nil ? .orange : .green, lineWidth: 2) } }
        .contentShape(shape)
        .focusRing(isFocused, cornerRadius: 14, scale: 1.015) // wide, like the search bar
        .contextMenu { gameMenu(game) }
        .accessibilityElement(children: .contain)
    }

    /// Under a row's name: its host and when it was last played, or why it can't be played now.
    private func details(_ game: CatalogGame) -> String {
        if let down = game.unavailable(hosts: hosts, directory: directory) { return "\(down.pc) \(down.reason)" }
        let host = hosts.first { $0.uniqueID == game.sources[0].pcID }?.displayName
        let played = game.lastPlayed.map { $0.formatted(.relative(presentation: .named)) } ?? "Not played yet"
        return [host, played].compactMap { $0 }.joined(separator: " · ")
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
                Label(game.isRunning(directory) ? game.runningLabels(directory, catalog).resume : "Play", systemImage: "play.fill").overlayButtonText()
            }
            .buttonStyle(.glass) // white on glass, like Home's Play
            if game.isRunning(directory) {
                Button { readied = nil; quit(game) } label: { Label(game.runningLabels(directory, catalog).quit, systemImage: "xmark").overlayButtonText() }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
            }
        }
        .disabled(game.isWaitingForStatus(directory, launcher))
    }

    /// Asks before ending it on its PC (as Home does).
    private func quit(_ game: CatalogGame) {
        Moonswift.quit(game, hosts: hosts, directory: directory, catalog: catalog, launcher: launcher)
    }

    private var focusedGame: CatalogGame? { shown.indices.contains(focus) ? shown[focus] : nil }
    /// The tile focused in the row above the covers.
    private var focusedApp: CatalogGame? {
        guard hasShortcutRow, let rowIndex, shortcuts.indices.contains(rowIndex - 2) else { return nil }
        return shortcuts[rowIndex - 2]
    }

    /// Where focus goes when the row changes: with the same tile (a rename can re-sort it), else to the tile now in its
    /// place or the last one. Nil when the row is empty.
    nonisolated static func followedPosition<Item: Equatable>(_ position: Int, from old: [Item], to new: [Item]) -> Int? {
        guard !new.isEmpty else { return nil }
        let same = old.indices.contains(position) ? new.firstIndex(of: old[position]) : nil
        return same ?? min(position, new.count - 1)
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
        // The top: the search bar, Sort, Filter, left to right; down to the shortcuts, or the covers without them.
        case .right where focus == Self.searchFocus && !isSearching: focus = Self.rowFocus(0)
        case .left where rowIndex == 0: focus = isSearching ? Self.closeFocus : Self.searchFocus
        case .right where focus == Self.closeFocus: focus = Self.rowFocus(0)
        case .right where rowIndex == 0, .up where rowIndex == 0: break
        case .down where (focus == Self.searchFocus || rowIndex == 0) && hasShortcutRow:
            focus = Self.rowFocus(2)
        // The shortcuts: along the row, up to the search bar, down to the covers.
        case .left where rowIndex != nil: focus = Self.rowFocus(max(rowIndex! - 1, 2))
        case .right where rowIndex != nil: focus = Self.rowFocus(min(rowIndex! + 1, shortcuts.count + 1))
        case .up where rowIndex != nil: focus = Self.searchFocus
        case .down where rowIndex != nil: if !games.isEmpty { focus = 0 }
        case .select where rowIndex != nil: pressPill(rowIndex!)
        case .down where focus < 0: focus = 0
        case .right where focus == Self.searchFocus && isSearching: focus = Self.closeFocus
        case .left where focus == Self.closeFocus: focus = Self.searchFocus
        case .left where focus < 0, .right where focus < 0, .up where focus < 0: break
        case .up where focus < columns: focus = hasShortcutRow ? Self.rowFocus(2) : Self.searchFocus
        case .up, .down, .left, .right: focus = FocusMove.next(focus, count: games.count, columns: columns, command)
        case .select where focus == Self.searchFocus: isSearchFocused = true // the keyboard; highlights hide while typing
        case .select where focus == Self.closeFocus: closeSearch()
        case .select: if games.indices.contains(focus) { start(games[focus]) }
        case .menu: if let game = focusedGame ?? focusedApp { editing = game }
        case .alternate: if let game = focusedGame, game.isRunning(directory) { quit(game) }
        case .options: focus = Self.rowFocus(0); pressPill(0)
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
private struct LibraryHeader<Pills: View>: View {
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
    /// Sort and Filter, beside the bar (searching too: the bar shortens for its close button).
    @ViewBuilder let pills: Pills

    static var barHeight: CGFloat { 44 }
    /// Between the title and the bar.
    static var gap: CGFloat { 8 }
    /// The bar while searching: where the title's line was (TabTitle: 23 points down, 48 tall), clear of the edge.
    static var pinned: CGFloat { 25 }

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
        // The field, its close button (only while searching) and Sort and Filter, each with its own gap before it,
        // so the hidden close button leaves none. Top-aligned: the bar squishes up towards its top edge, which stays put.
        return HStack(alignment: .top, spacing: 0) {
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
            .focusRing(focused == .bar, cornerRadius: .infinity, scale: 1.015) // wide: 5% was ~23 points; the bar itself squishes all the way to nothing
            // In the bar's room, so Sort and Filter stay put. Always laid out (no width while not searching): one
            // added mid-move appeared at the bar's end place, above it while the bar was still sliding up.
            Button("Close Search", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: Self.barHeight, height: Self.barHeight)
                .contentShape(.circle)
                .glassEffect(.regular.interactive(), in: .circle)
                .focusRing(focused == .close, cornerRadius: .infinity)
                .opacity(isSearching ? 1 : 0)
                .frame(width: isSearching ? Self.barHeight : 0)
                .padding(.leading, isSearching ? 12 : 0)
                .allowsHitTesting(isSearching)
                .accessibilityHidden(!isSearching)
            pills
                .padding(.leading, 12)
                .opacity(min(max((shown - 0.65) / 0.35, 0), 1)) // they go with the bar's contents
                .allowsHitTesting(shown > 0.65)
        }
        .frame(maxWidth: HomeView.readableWidth, alignment: .leading) // not edge to edge on a big iPad
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
    /// Running on another device: orange rather than green.
    var isElsewhere = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            if let title { Text(title).lineLimit(1) }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, title == nil ? 0 : 14)
        .frame(minWidth: 44, minHeight: 44) // the search bar's height
        .contentShape(.capsule)
        .glassEffect(isOn ? .regular.tint(.white.opacity(0.18)).interactive() : .regular.interactive(), in: .capsule)
        .overlay { if isRunning { Capsule().stroke(isElsewhere ? .orange : .green, lineWidth: 2) } }
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
