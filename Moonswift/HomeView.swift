import SwiftData
import SwiftUI

/// Home, after Apple's Games app, on one screen with no scrolling: one row of every game, most recently played first,
/// and above it a hero for the selected game (your own art behind it, if you added some), with Play, or Resume and
/// Quit while it runs. Tap a cover to select it, and Play to play it. Controller: left/right through the row, up/down
/// between the row and the hero's buttons, A plays (or the button), Y edits the game, X quits it, L1/R1 switch tabs,
/// Menu opens Settings.
struct HomeView: View {
    var switchTab: (Int) -> Void
    var openSettings: () -> Void = {}
    /// Checks every PC now: from the status button at the far end of the title's line, or View on a controller.
    var refresh: () -> Void = {}
    var isRefreshing = false

    @Environment(PCDirectory.self) private var directory
    @Environment(GameCatalog.self) private var catalog
    @Environment(StreamLauncher.self) private var launcher
    @Environment(GamepadInput.self) private var gamepad
    @Environment(TabBarMinimize.self) private var tabBar: TabBarMinimize?
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Query(sort: \SavedHost.name) private var hosts: [SavedHost]
    @State private var isAdding = false
    /// An iPhone in landscape: the tab bar has tucked itself away (`floatsTabBar`).
    @State private var isTabBarAway = false
    /// Bumped to restart the tab bar's wait before tucking away.
    @State private var tabBarWake = 0
    /// How long the tab bar stays before tucking away: a short while on arriving at Home, longer once you've opened it.
    @State private var tabBarStay: Duration = .seconds(2.5)
    /// While tucked away: the stand-in has shrunk into the corner button (false: it's the bar's shape, at the bar's
    /// place, mid-morph).
    @State private var isTabBarShrunk = false
    /// The real bar is hidden, its stand-in alone on screen (the stand-in fades in over it first, and out over it last).
    @State private var isRealTabBarHidden = false
    @State private var standInOpacity: Double = 0
    /// Where the system draws its bar and its shrunk button, read as it tucks away.
    @State private var tabBarFrames = TabBarFrames.fallback
    @State private var editing: CatalogGame?
    /// The selected game, by ID: playing one moves it to the front of the row, and the selection goes with it.
    /// Controller focus is on the row (1), the hero's buttons (0), or the host status pill (-1).
    @State private var selectedID: String?
    @State private var focusRow = 1
    @State private var heroButton = 0 // 0 Play/Resume, 1 Quit
    /// An iPhone in landscape (not the Duo, whose rail is beside the page): the page is laid out as if there were no tab
    /// bar, which floats over the covers when it shows, and tucks itself away to a small button a moment after Home
    /// comes up (iOS can't shrink its bar on command, only while scrolling, which Home doesn't).
    private var floatsTabBar: Bool { UIDevice.current.userInterfaceIdiom == .phone && verticalSizeClass == .compact && hasTopBar }

    /// The status pill's menu, opened with the controller.
    @State private var statusMenu: ChoiceMenuSpec?
    @State private var pillFrame = RowFrames()
    @State private var isPressingPlay = false
    @State private var topInset: CGFloat = 0
    @AppStorage(SettingsKey.buttonGuide) private var guideMode = ButtonGuideMode.automatic
    /// The title shows in full on arriving at Home, then fades back so it doesn't compete with the hero, still readable.
    /// The tab rail's width on either side: the hero art reaches under it, so it spans the whole screen.
    @State private var railInsets = EdgeInsets()
    @State private var heroFold = FoldAvoidance(fold: nil, in: .zero)
    /// The height left under a fold across the screen, down to where the covers end, and the cover row's height.
    @State private var belowFold: CGFloat = 0
    @State private var coverRowHeight: CGFloat = 0
    /// Home's height above the guide's room, which sizes the covers and the hero's title.
    @State private var homeHeight: CGFloat = 0
    @AppStorage(SettingsKey.coverShape) private var coverShape = CoverShape.tall

    /// Games only: the shortcuts (Desktop, Steam Big Picture…) are in Library's row of their own.
    private var games: [CatalogGame] { catalog.games(on: hosts.map(\.uniqueID)).filter { !$0.isApp } }

    /// The one row of covers: every game, most recently played first (the catalog's order).
    private var row: (title: String, games: [CatalogGame])? { games.isEmpty ? nil : ("Games", games) }

    private var hasRemoteSession: Bool {
        hosts.contains { directory.isAvailable($0.uniqueID) && catalog.remoteSession(on: $0.uniqueID) != nil }
    }

    private var selectedGame: CatalogGame? {
        let games = row?.games ?? []
        return games.first { $0.id == selectedID } ?? games.first
    }

    /// The host status, in place of the title: tap for each host's status and Refresh.
    private var statusPill: AnyView? {
        hosts.isEmpty ? nil : AnyView(PCStatusButton(refresh: refresh, isRefreshing: isRefreshing,
                                                     isFocused: gamepad.isActive && focusRow == -1, isHidden: statusMenu != nil,
                                                     isCompact: floatsTabBar)
            // Floating tab bar: in line with its shrunk button below, rather than the top bar's inner margin in.
            .offset(x: floatsTabBar ? -10 : 0)
            // In the page's own coordinates for its menu, wherever the pill is: the top bar sits outside the page.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { pillFrame.frames["status"] = $0 })
    }

    /// The toolbar runs along the top (iPhone, iPad): the pill goes at its leading end, mirroring the gear.
    private var hasTopBar: Bool { TabToolbar<EmptyView>.hasTopBar(insets: railInsets) }

    /// On the title line on the Duo; in the top bar elsewhere.
    private var titlePill: AnyView? { hasTopBar || isRailOnLeft ? nil : statusPill }
    /// The Duo folded and turned curved side up: its side column is on the left, so the pill goes to the title line's
    /// far end, top right, rather than crowding the gear.
    private var isRailOnLeft: Bool { TabToolbar<EmptyView>.isRailOnLeft(insets: railInsets) }

    /// The pill's menu for the controller, like the one a tap opens: each host's status under its name, then Refresh.
    private func openStatusMenu() {
        let info = hosts.map { host in
            let line = PCStatusButton.line(host, directory: directory, catalog: catalog, now: .now)
            return ChoiceMenuSpec.Info(header: host.displayName, text: line.text, dot: PCStatusButton.color(line))
        }
        statusMenu = ChoiceMenuSpec(source: "status", options: ["Refresh"], selected: -1,
                                    anchor: (pillFrame.frames["status"] ?? .zero).offsetBy(dx: -(pillFrame.frames["page"]?.minX ?? 0),
                                                                                           dy: -(pillFrame.frames["page"]?.minY ?? 0)),
                                    pick: { _ in refresh() }, width: 320,
                                    info: info, icons: ["arrow.clockwise"], opensRight: true)
    }

    var body: some View {
        NavigationStack {
            Group {
                if hosts.isEmpty {
                    welcome
                } else if games.isEmpty, hasRemoteSession {
                    // A host in a remote session lists only its controls, no games: those, not "Loading Games".
                    VStack(spacing: 0) {
                        TabTitle(text: "", topInset: topInset, beside: titlePill) { if isRailOnLeft, let statusPill { statusPill } }
                    .padding(.horizontal, 36)
                            .padding(.top, -max(0, topInset - Self.windowTopInset))
                        Spacer()
                        remoteSessionBanners
                        Spacer()
                    }
                } else if games.isEmpty {
                    ContentUnavailableView {
                        Label("Loading Games", systemImage: "gamecontroller")
                    } description: {
                        Text("Your host's games appear here once it answers.")
                    } actions: {
                        ProgressView()
                    }
                } else {
                    dashboard
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { pillFrame.frames["page"] = $0 }
            .choiceMenu($statusMenu)
            .buttonGuide(guideHints) // inside the insets measured below, which say where the tab bar is
            .navigationTitle("") // drawn by TabTitle instead, lined up with the content 36 points in
            .toolbar {
                TabToolbar(hasTopBar: hasTopBar, openSettings: openSettings) { EmptyView() }
                if hasTopBar, let statusPill {
                    ToolbarItem(placement: .topBarLeading) { statusPill }.sharedBackgroundVisibility(.hidden) // its own glass
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { railInsets = $0 }
            // Touching the page (not the bar) sends the tab bar away at once.
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in tuckTabBarAway() })
            .toolbar(floatsTabBar && isRealTabBarHidden ? .hidden : .automatic, for: .tabBar)
            .overlay { tabBarStandIn }
            // Shows on arriving at Home (and after the button's tap), then tucks away after a moment.
            .task(id: "\(floatsTabBar)|\(tabBarWake)") {
                guard floatsTabBar, !isTabBarAway else { return }
                try? await Task.sleep(for: tabBarStay)
                if !Task.isCancelled { tuckTabBarAway() }
            }
            .onChange(of: isTabBarAway, initial: true) { tabBar?.isAway = isTabBarAway }
            .onDisappear {
                withTransaction(Transaction(animation: nil)) {
                    isTabBarAway = false; isTabBarShrunk = false; isRealTabBarHidden = false; standInOpacity = 0
                }
                tabBar?.isAway = false
                tabBarStay = .seconds(2.5) // the short wait next time Home comes up
            }

            // Out to the screen's edges, under the rail too, like the hero art.
            .background {
                Color(.systemBackground).padding(.leading, -railInsets.leading).padding(.trailing, -railInsets.trailing).ignoresSafeArea()
            }
            // Back from a stream (disconnected, or shrunk to Picture in Picture): its game selected, with the
            // controller on Resume, to carry on or quit.
            .onChange(of: launcher.stream == nil || launcher.isMinimized) { _, isBack in
                guard isBack, let session = launcher.session,
                      let game = games.first(where: { $0.sources.contains { $0.pcID == session.pcID && $0.app.id == session.appID } })
                else { return }
                withAnimation(.snappy) { selectedID = game.id }
                focusRow = 0
                heroButton = 0
            }
            .sheet(isPresented: $isAdding) { AddHostView() }
            .sheet(item: $editing) { GameEditView(game: $0) }
            .onGamepad(handle)
        }
        // A sheet's keyboard (Edit Game's name) mustn't push Home's covers and hero up behind it.
        .ignoresSafeArea(.keyboard)
    }

    /// The button guide's buttons: the selected game's, then the page's.
    private var guideHints: [(buttons: [ControllerHints.Button], label: String)] {
        guard !games.isEmpty else { return [] }
        let a = focusRow == -1 ? "Open" : focusRow == 0 && heroButton == 1 ? "Quit"
            : selectedGame?.isRunning(directory) == true ? "Resume" : "Play"
        return [([.a], a), ([.y], "Edit")] + (selectedGame?.isRunning(directory) == true ? [([.x], "Quit")] : [])
            + [([.view], "Refresh"), ([.l1, .r1], "Tabs"), ([.menu], "Settings")]
    }

    private var welcome: some View {
        ContentUnavailableView {
            Label("Welcome to Moonswift", systemImage: "play.tv")
        } description: {
            Text("Stream games from your host. Start by adding it; it needs to be on and on the same network.")
        } actions: {
            Button("Add a Host") { isAdding = true }.buttonStyle(.glassProminent).controlSize(.large)
        }
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // In place of the system's title (its status button is in the toolbar), but 36 points in; and up into
                // the top space the toolbar adds, so it's level with every other tab's title.
                TabTitle(text: "", topInset: topInset, beside: titlePill) { if isRailOnLeft, let statusPill { statusPill } }
                    .padding(.horizontal, 36)
                    .padding(.top, -max(0, topInset - Self.windowTopInset))
                if let game = selectedGame {
                    HeroCard(game: game, subtitle: heroSubtitle(game), isShort: isShort,
                             isRunning: game.isRunning(directory), focusedButton: gamepad.isActive && focusRow == 0 ? heroButton : nil,
                             play: { start(game) }, quit: { quit(game) }, isPressingPlay: isPressingPlay)
                        .frame(maxWidth: heroFold.maxWidth ?? .infinity, alignment: .leading)
                }
            }
            .padding(.bottom, heroFold.lift)
            .frame(maxHeight: .infinity)
            // On a half-open Duo, the hero's title and buttons stay off the fold: above it, or to its left.
            .onGeometryChange(for: FoldAvoidance.self) { FoldAvoidance(fold: $0.fold, in: $0.size) } action: { heroFold = $0 }
            // Ends above the covers, so a wide picture shows whole; on a half-open Duo, above the fold.
            .background { heroArt.padding(.bottom, heroFold.lift) }
            remoteSessionBanners
            if let row {
                coverRow(row.games)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { coverRowHeight = $0 }
                    // On a half-open Duo with its fold across, in the middle of the half below the fold.
                    .padding(.bottom, max(0, (belowFold - coverRowHeight) / 2))
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.fold.map { $0.width >= $0.height ? proxy.size.height - $0.maxY : 0 } ?? 0
        } action: { belowFold = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { homeHeight = $0 }
        // With a controller, room for the button guide (its pill, then a gap); without, the covers end where the guide
        // would, at the safe area's edge (the row's 12 points of focus-ring room hang below it, into the home
        // indicator's margin, though not under a tab bar along the bottom).
        // On the Air the row sits right above the guide (just its focus-ring room between), leaving the hero more height.
        .padding(.bottom, floatsTabBar ? -12 : showsGuide ? Self.guideGap : (isTabBarBelow ? 8 : -12))
        // Floating tab bar: down to the home indicator's margin whether the bar shows or not, so nothing moves.
        .padding(.bottom, floatsTabBar ? Self.windowBottomInset - railInsets.bottom : 0)
    }

    /// The tucked-away tab bar, like the system's own when it shrinks while scrolling: a glass button with the tab's
    /// symbol, in the bottom corner. A tap brings the bar back.
    /// Stands in for the system's tab bar while it's tucked away, the way the system shrinks it while scrolling: a glass
    /// copy of the bar, in its exact place, that morphs into the round button in the corner (and back on a tap). The
    /// system's own bar can't be shrunk from code, and only glass the app draws can morph.
    private var tabBarStandIn: some View {
        GeometryReader { proxy in
            if floatsTabBar, isTabBarAway {
                let origin = proxy.frame(in: .global).origin
                TabBarMorph(progress: isTabBarShrunk ? 1 : 0, frames: tabBarFrames, origin: origin, tap: showTabBar)
                    .opacity(standInOpacity)
            }
        }
        .ignoresSafeArea()
    }

    /// A quick spring with only a touch of overshoot, like the system's.
    static let tabBarMorphCurve = Animation.spring(duration: 0.2, bounce: 0.1)

    /// The real bar goes at once and its glass copy, in the same place, shrinks into the corner button.
    private func tuckTabBarAway() {
        guard floatsTabBar, !isTabBarAway else { return } // only from the bar showing
        tabBarFrames = TabBarFrames.read() ?? .fallback
        withTransaction(Transaction(animation: nil)) { isTabBarAway = true; isTabBarShrunk = false; standInOpacity = 0 }
        // The copy fades in over the real bar, which then goes underneath it, and only then does it shrink.
        withAnimation(.easeOut(duration: 0.12)) { standInOpacity = 1 } completion: {
            withTransaction(Transaction(animation: nil)) { isRealTabBarHidden = true }
            withAnimation(Self.tabBarMorphCurve) { isTabBarShrunk = true }
        }
    }

    /// The corner button grows back into the bar, then the real bar takes its place.
    private func showTabBar() {
        // Grows back into the bar, the real bar comes back underneath, and the copy fades out over it.
        withAnimation(Self.tabBarMorphCurve) { isTabBarShrunk = false } completion: {
            withTransaction(Transaction(animation: nil)) { isRealTabBarHidden = false }
            withAnimation(.easeIn(duration: 0.12)) { standInOpacity = 0 } completion: {
                withTransaction(Transaction(animation: nil)) { isTabBarAway = false }
                tabBarStay = .seconds(4) // opened on purpose: it stays a little longer
                tabBarWake += 1
            }
        }
    }

    /// The selected game's own hero picture, behind the title and hero and fading out just above the covers; plain
    /// background without.
    @ViewBuilder private var heroArt: some View {
        if let game = selectedGame, let art = catalog.heroArt[game.id] {
            Color.clear
                // Only the picture crossfades between games: the fades over it stay put, so they never thin out midway.
                .overlay { Image(uiImage: art).resizable().scaledToFill().id(game.id).transition(.opacity) }
                .overlay {
                    LinearGradient(stops: [.init(color: .clear, location: 0.55), .init(color: Color(.systemBackground), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .overlay { LinearGradient(colors: [Color(.systemBackground).opacity(0.6), .clear], startPoint: .leading, endPoint: .center) }
                .clipped()
                // The tab gives its content only the screen beside the rail, so reach under it; ignoring the safe area can't.
                .padding(.leading, -railInsets.leading)
                .padding(.trailing, -railInsets.trailing)
                .ignoresSafeArea(edges: .top)
                .transition(.opacity) // in and out only from a game without a picture
                .accessibilityHidden(true)
        }
    }

    /// The tab bar runs along the bottom (the Duo's inner display in portrait), so nothing may hang below the safe area.
    /// shortcut: iOS doesn't say where its tab bar is; a bottom inset this tall is one. Revisit if the system says.
    private var isTabBarBelow: Bool { railInsets.bottom > 40 }
    private var showsGuide: Bool { guideMode.isShown(controllerConnected: gamepad.isControllerConnected) && !games.isEmpty }

    /// Above the guide: with the cover row's 12 points of focus-ring room, the same 28 points as between Play and the
    /// covers (the hero's 16 below Play, plus those 12).
    static let guideGap: CGFloat = 16
    /// Covers are bigger without a controller (easier to tap), smaller with one to make room for its guide; and on a
    /// short screen (the Duo's outer display) no taller than 38% of Home, so the hero keeps its room.
    private var coverWidth: CGFloat {
        let preferred: CGFloat = showsGuide ? 116 : 128
        // Square covers are shorter for their width: on a short screen they take less of its height, so more of the
        // hero shows.
        let share: CGFloat = coverShape == .square ? 0.3 : 0.38
        return homeHeight > 0 ? min(preferred, (homeHeight * share * coverShape.ratio).rounded()) : preferred
    }
    /// Home is short (the Duo's outer display): the hero's title is set smaller.
    private var isShort: Bool { homeHeight > 0 && homeHeight < 520 }

    /// The window's top safe area: a tab without a toolbar has just this.
    static var windowTopInset: CGFloat {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }.first ?? 0
    }
    /// The window's bottom safe area: the home indicator's room.
    static var windowBottomInset: CGFloat {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom }.first ?? 0
    }
    /// The window's leading safe area: the notch's side of an iPhone in landscape.
    static var windowLeadingInset: CGFloat {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.left }.first ?? 0
    }

    /// Where tab titles start: a fixed space below the top of the safe area (the status bar, where there is one), as in
    /// Apple's Games app.
    static func titleTop(_ inset: CGFloat) -> CGFloat { inset + 23 }

    private func heroSubtitle(_ game: CatalogGame) -> String {
        let pc = hosts.count > 1 ? game.sources.compactMap { s in hosts.first { $0.uniqueID == s.pcID }?.displayName }.first : nil
        let state = game.isRunning(directory) ? "Running now" : nil // when it was last played: left out, it crowded the hero
        return [pc, state].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Another device's session

    /// While another device streams from a PC, it offers to join (take over) or end that session.
    @ViewBuilder private var remoteSessionBanners: some View {
        ForEach(hosts.filter { directory.isAvailable($0.uniqueID) }) { host in
            if let session = catalog.remoteSession(on: host.uniqueID) {
                HStack(spacing: 16) {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.title2).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.isOwn ? "\(session.kind) is on" : "Being streamed on another device").font(.headline)
                        Text(session.isOwn ? "\(host.displayName) lists its games again once you disconnect." : host.displayName)
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let join = session.join {
                        Button(session.isOwn ? "Resume" : "Join") { launcher.join(join, on: directory.ref(host)) }.buttonStyle(.glassProminent)
                    }
                    if let disconnect = session.disconnect {
                        Button("Disconnect") { launcher.disconnectRemote(disconnect, on: directory.ref(host)) }.buttonStyle(.glass)
                    }
                    if let end = session.end {
                        Button("End Session", role: .destructive) { launcher.confirmEndSession(end, on: directory.ref(host)) }
                            .buttonStyle(.glass)
                            .tint(.red)
                    }
                }
                .padding(12)
                .background(.primary.opacity(0.08), in: .rect(cornerRadius: 18))
                .padding(.leading, 36)
                .padding(.trailing, 36)
            }
        }
    }

    // MARK: Rows

    private func coverRow(_ games: [CatalogGame]) -> some View {
        ScrollViewReader { scroller in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 14) {
                        ForEach(games) { game in
                            CoverTile(game: game, client: client(for: game), isRunning: game.isRunning(directory),
                                      offlinePC: offlinePC(game), isFocused: focusRow == 1 && game.id == selectedGame?.id)
                                .frame(width: coverWidth)
                                .onTapGesture { // selects only: Play starts it, so a stray second tap can't
                                    withAnimation(.snappy) { selectedID = game.id }
                                    focusRow = 1
                                }
                                .contextMenu { gameMenu(game) }
                                .id(game.id)
                        }
                    }
                    .padding(.horizontal, 36)
                    .padding(.vertical, 12) // room for the focus ring
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled() // the focused cover's shadow fades out instead of ending in a hard edge
                .fixedSize(horizontal: false, vertical: true) // as tall as the covers, not a share of the spare height
                // Follows the selection, and the selected game when playing it moves it to the front.
                .onChange(of: "\(selectedGame?.id ?? "")|\(games.firstIndex { $0.id == selectedGame?.id } ?? 0)") {
                    withAnimation { scroller.scrollTo(selectedGame?.id, anchor: .center) }
                }
        }
    }

    // MARK: Actions

    private func client(for game: CatalogGame) -> HostClient? {
        game.sources.lazy.compactMap { source in self.hosts.first { $0.uniqueID == source.pcID } }.first.map { directory.ref($0).client }
    }

    /// Only once every PC with it is known to be down (not while the first check is still out): the first one's name.
    private func offlinePC(_ game: CatalogGame) -> String? {
        guard game.sources.allSatisfy({ directory.statuses[$0.pcID] == .offline }) else { return nil }
        return game.sources.lazy.compactMap { s in hosts.first { $0.uniqueID == s.pcID }?.displayName }.first ?? "Its host"
    }

    private func start(_ game: CatalogGame) {
        play(game, hosts: hosts, directory: directory, catalog: catalog, launcher: launcher)
    }

    /// Quits it on the PC that's running it, after asking.
    private func quit(_ game: CatalogGame) {
        guard let source = game.sources.first(where: { directory.playing[$0.pcID] == $0.app.id }),
              let host = hosts.first(where: { $0.uniqueID == source.pcID }) else { return }
        launcher.confirmQuit(game.title, on: directory.ref(host))
    }

    @ViewBuilder private func gameMenu(_ game: CatalogGame) -> some View {
        Button("Edit Game", systemImage: "pencil") { editing = game }
        Button(game.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: game.isFavorite ? "star.slash" : "star") {
            catalog.toggleFavorite(game)
        }
        if game.isRunning(directory) {
            Button("Quit", systemImage: "xmark", role: .destructive) { quit(game) }
        }
    }

    /// A on a cover or Play: the Play button presses, then the game starts.
    private func pressPlay(_ game: CatalogGame) {
        isPressingPlay = true
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            isPressingPlay = false
            start(game)
        }
    }

    private func handle(_ command: GamepadCommand) {
        tuckTabBarAway() // any press on the page sends the floating tab bar away
        guard launcher.busy == nil, let game = selectedGame else {
            if command == .previousTab { switchTab(-1) } else if command == .nextTab { switchTab(1) } else if command == .settings { openSettings() }
            return
        }
        let count = row?.games.count ?? 0, isRunning = game.isRunning(directory)
        switch command {
        case .up:
            if focusRow == 1 { heroButton = 0 }
            focusRow = focusRow == 1 || hosts.isEmpty ? 0 : -1
        case .down:
            if focusRow == -1 { heroButton = 0 }
            focusRow = min(focusRow + 1, 1)
        case .left, .right:
            let offset = command == .left ? -1 : 1
            if focusRow == -1 {
                break
            } else if focusRow == 0 {
                heroButton = isRunning ? min(max(heroButton + offset, 0), 1) : 0
            } else {
                let games = row?.games ?? [], index = games.firstIndex { $0.id == game.id } ?? 0
                withAnimation(.snappy) { selectedID = games[min(max(index + offset, 0), max(count - 1, 0))].id }
            }
        case .select:
            if focusRow == -1 { openStatusMenu() }
            else if focusRow == 0, heroButton == 1, isRunning { quit(game) } else { pressPlay(game) }
        case .alternate: if isRunning { quit(game) }
        case .menu: editing = game
        case .options: refresh()
        case .previousTab: switchTab(-1)
        case .nextTab: switchTab(1)
        case .settings: openSettings()
        default: break
        }
    }
}

/// The selected game: what it is, and Play, or Resume and Quit while it runs. Its art, if any, is behind it
/// (`heroArt`).
private struct HeroCard: View {
    let game: CatalogGame
    let subtitle: String
    /// On a short screen: a smaller title.
    var isShort = false
    let isRunning: Bool
    /// The controller's focus on a button: 0 Play/Resume, 1 Quit.
    let focusedButton: Int?
    let play: () -> Void
    let quit: () -> Void
    /// A controller's A on a cover: the Play button shows a press as the game starts, so A reads as pressing it.
    var isPressingPlay = false
    /// Big enough to hold its own beside the Play button; with Dynamic Type.
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 46
    @ScaledMetric(relativeTo: .title) private var shortTitleSize: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !subtitle.isEmpty {
                Label(subtitle, systemImage: isRunning ? "play.circle.fill" : "gamecontroller.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isRunning ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            }
            Text(game.title)
                .font(.system(size: isShort ? shortTitleSize : titleSize, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .contentTransition(.opacity)
            HStack(spacing: 12) {
                Button(action: play) {
                    Text(isRunning ? "Resume" : "Play").font(.headline).frame(width: 140)
                }
                .buttonStyle(.glass)
                .focusRing(focusedButton == 0, cornerRadius: .infinity) // the glass button is a capsule
                .scaleEffect(isPressingPlay ? 0.92 : 1)
                .brightness(isPressingPlay ? 0.25 : 0)
                .animation(.snappy(duration: 0.12), value: isPressingPlay)
                if isRunning {
                    Button(action: quit) {
                        Text("Quit").font(.headline).frame(width: 90)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                    .focusRing(focusedButton == 1, cornerRadius: .infinity)
                }
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.horizontal, 36)
        .padding(.bottom, 16)
        .animation(.snappy, value: game.id)
    }
}

/// A game's cover: portrait art with a running ring and favourite star; dark and blurred, with "<PC> is offline" on it,
/// while its PC can't be reached. As wide
/// as it's given, in the chosen cover shape.
struct CoverTile: View {
    let game: CatalogGame
    let client: HostClient?
    let isRunning: Bool
    /// The name of its PC while that's offline (nil: it can be played).
    let offlinePC: String?
    let isFocused: Bool
    @Environment(GameCatalog.self) private var catalog
    @AppStorage(SettingsKey.coverShape) private var coverShape = CoverShape.tall

    var body: some View {
        Color.clear
            .aspectRatio(coverShape.ratio, contentMode: .fit)
            .overlay {
                CoverArt(app: game.sources[0].app, client: client, custom: catalog.cover(for: game.id, coverShape), title: game.title)
                    .blur(radius: offlinePC == nil ? 0 : 8, opaque: true) // no see-through fringe at the edges
                    .overlay {
                        if let offlinePC {
                            ZStack {
                                Color.black.opacity(0.5)
                                VStack(spacing: 2) {
                                    Text(offlinePC).font(.subheadline.weight(.semibold))
                                    Text("is offline").font(.caption)
                                }
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.7)
                                .padding(8)
                            }
                        }
                    }
                    .animation(.easeInOut(duration: 0.5), value: offlinePC != nil) // blur and label fade together
            }
            .clipShape(.rect(cornerRadius: 14))
            .overlay {
                if isRunning { RoundedRectangle(cornerRadius: 14).stroke(.green, lineWidth: 3) }
            }
            .overlay(alignment: .topTrailing) {
                if game.isFavorite {
                    Image(systemName: "star.fill").font(.caption.bold()).padding(5)
                        .background(.yellow, in: .circle).foregroundStyle(.black).padding(6)
                }
            }
            .focusRing(isFocused, cornerRadius: 14)
            .contentShape(.rect)
            .accessibilityElement()
            .accessibilityLabel(game.title)
            .accessibilityValue([isRunning ? "Running" : nil, game.isFavorite ? "Favorite" : nil, offlinePC.map { "\($0) is offline" }]
                .compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(.isButton)
    }
}

/// A tab's page title, placed exactly like Home's: the same distance below the top of the safe area, and lined up with
/// the page's content 36 points in. `topInset` is the page's top safe area (the status bar, where there is one). An
/// accessory (a function button such as PC Status) sits at the far end of the title's line, at the content's edge,
/// like the account button in Apple's Games app. On iPad, whose tab bar across the top already names the tab, the
/// line shows only the accessory.
struct TabTitle<Accessory: View>: View {
    let text: String
    let topInset: CGFloat
    /// The size the system gives a tab's title on the Duo, where its toolbar sits on the side.
    var font: Font = .title.bold()
    /// Right after the title, on its line; with no text, in its place (Home's host status).
    var beside: AnyView?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        let isTabBarOnTop = UIDevice.current.userInterfaceIdiom == .pad // the system's choice, not a measurement
        if isTabBarOnTop, Accessory.self == EmptyView.self, beside == nil {
            Color.clear.frame(height: 8)
        } else {
            HStack {
                if !isTabBarOnTop, !text.isEmpty {
                    Text(text)
                        .font(font)
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                }
                if let beside { beside }
                Spacer(minLength: 16)
                accessory
            }
            .frame(minHeight: FunctionButtonLabel.size) // every tab's title on the same line, button or not
            .padding(.top, isTabBarOnTop ? 8 : HomeView.titleTop(topInset) - topInset)
        }
    }
}

extension TabTitle {
    /// As a list's first header: it scrolls away with the list, under the system's soft blur at the top edge, like the
    /// titles in Apple's own apps. 36 points in, like every tab's title.
    func asListHeader() -> some View { ListTitle(title: self) }
}

extension View {
    /// As a scrolling title leaves the top, it blurs and fades on its way up (the Duo has no top bar for the system's
    /// scroll-edge blur to show in).
    func blursAway() -> some View { modifier(BlurAway()) }
}

/// Blurs and fades by how far it has scrolled up from where it rests, with a little slack.
private struct BlurAway: ViewModifier {
    @State private var rest: CGFloat = -.infinity
    @State private var gone: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { frame in
                // Where it rests, taken once: following the highest top seen let a pull past the top move it, so the
                // title stayed blurred afterwards.
                guard frame.height > 0 else { return }
                if rest == -.infinity { rest = frame.minY }
                let next = min(max((rest - 12 - frame.minY) / frame.height, 0), 1)
                if abs(next - gone) > 0.01 || next == 0 || next == 1 { gone = next }
            }
            .blur(radius: gone * 10)
            .opacity(1 - gone)
    }
}

/// A tab title as a list's header: the list sets headers in from the edge and greys them, so this measures where it
/// landed on screen and moves it to where Home's and Library's titles are (36 points in from the window's safe area,
/// at its top), in the title's own colour.
private struct ListTitle<Accessory: View>: View {
    let title: TabTitle<Accessory>
    /// Where the list put it, taken once: following it as it scrolled moved the padding with it, and the title
    /// flickered and jittered.
    @State private var origin: CGPoint?

    var body: some View {
        title
            .foregroundStyle(Color(.label))
            .textCase(nil)
            .padding(.leading, origin.map { 36 + HomeView.windowLeadingInset - $0.x } ?? 0)
            .padding(.top, origin.map { HomeView.windowTopInset - $0.y } ?? 0)
            // Measured outside the padding, so the offset doesn't depend on itself.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                if origin == nil, frame.height > 0 { origin = CGPoint(x: frame.minX.rounded(), y: frame.minY.rounded()) }
            }
            .blursAway()
    }
}

extension TabTitle where Accessory == EmptyView {
    init(text: String, topInset: CGFloat, font: Font = .title.bold(), beside: AnyView? = nil) {
        self.init(text: text, topInset: topInset, font: font, beside: beside) { EmptyView() }
    }
}

/// A round liquid-glass function button (Refresh, Filter and Sort): one size everywhere, its icon dead centre, and
/// the controller's focus ring when focused.
struct FunctionButtonLabel: View {
    let systemImage: String
    var isFocused = false
    var isSpinning = false

    static let size: CGFloat = 48

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: Self.size * 0.42, weight: .semibold))
            .symbolEffect(.rotate, isActive: isSpinning)
            .contentTransition(.symbolEffect(.replace)) // refresh arrow ↔ offline ↔ warning
            .animation(.default, value: systemImage)
            .frame(width: Self.size, height: Self.size) // the icon sits in the middle, not where padding puts it
            .contentShape(.circle)
            .glassEffect(.regular.interactive(), in: .circle)
            .focusRing(isFocused, cornerRadius: .infinity)
    }
}

/// The tab bar's glass stand-in, `progress` of the way from the bar (0) to the corner button (1): one glass shape whose
/// frame moves between the two, the tabs gone in its first third and the house only showing in its last, blurred while
/// in motion, so one symbol shows at a time and only clearly once it's nearly there.
private struct TabBarMorph: View, Animatable {
    var progress: CGFloat
    let frames: TabBarFrames
    let origin: CGPoint
    let tap: () -> Void

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let t = progress, bar = frames.bar, button = frames.button
        let frame = CGRect(x: bar.minX + (button.minX - bar.minX) * t, y: bar.minY + (button.minY - bar.minY) * t,
                           width: max(button.width, bar.width + (button.width - bar.width) * t),
                           height: bar.height + (button.height - bar.height) * t)
        let blur = sin(min(max(t, 0), 1) * .pi) * 4
        ZStack {
            tabs
                .frame(width: bar.width, height: bar.height)
                .frame(width: frame.width, height: frame.height, alignment: .leading)
                .clipped()
                .opacity(1 - min(max(t * 3, 0), 1))
            Image(systemName: "house.fill").font(.system(size: 19, weight: .semibold))
                .opacity(min(max((t - 0.65) / 0.35, 0), 1))
        }
        .blur(radius: blur)
        .frame(width: frame.width, height: frame.height)
        .contentShape(.capsule)
        .onTapGesture { if progress >= 1 { tap() } }
        .glassEffect(.clear.interactive(), in: .capsule) // as clear as the system's bar (measured against it)
        .position(x: frame.midX - origin.x, y: frame.midY - origin.y)
        .accessibilityElement()
        .accessibilityLabel("Show Tabs")
        .accessibilityAddTraits(.isButton)
    }

    /// The system's bar, as drawn on an iPhone in landscape (measured from it): three equal slots, filled symbols and
    /// white 12-point labels, and Home, the selected one, on a dark pill.
    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(RootView.TabID.allCases, id: \.self) { tab in
                HStack(spacing: 8) {
                    Image(systemName: tab.filledSymbol).font(.system(size: 16, weight: .medium))
                    Text(tab.title).font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { if tab == .home { Capsule().fill(.black.opacity(0.32)).padding(.vertical, 4).padding(.horizontal, 2.5) } }
            }
        }
        // The system's slots, measured: almost none at the left, a little at the right.
        .padding(.leading, 0.5)
        .padding(.trailing, 3)
    }
}

/// Where the system draws its tab bar and the round button it shrinks to, in the window, read from its views.
/// shortcut: found by the views' type names, which iOS doesn't promise; if they change, the measured fallback (the
/// iPhone Air's) is used. Revisit if iOS offers a way to shrink its bar from code.
struct TabBarFrames {
    var bar: CGRect
    var button: CGRect

    @MainActor static func read() -> TabBarFrames? {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
        else { return nil }
        var bar: CGRect?, button: CGRect?
        func walk(_ view: UIView) {
            switch String(describing: type(of: view)) {
            case "_UITabBarItemPlatterView": bar = view.convert(view.bounds, to: window)
                bar = view.convert(view.bounds, to: window)
            case "_UITabBarPlatterView": button = view.convert(view.bounds, to: window)
            default: break
            }
            view.subviews.forEach(walk)
        }
        walk(window)
        guard let bar, let button, bar.width > 0, button.width > 0 else { return nil }
        return TabBarFrames(bar: bar, button: button)
    }

    @MainActor static var fallback: TabBarFrames {
        let size = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.bounds.size }.first
            ?? CGSize(width: 912, height: 420)
        return TabBarFrames(bar: CGRect(x: (size.width - 266) / 2, y: size.height - 64, width: 266, height: 44),
                            button: CGRect(x: 38, y: size.height - 64, width: 44, height: 44))
    }
}
