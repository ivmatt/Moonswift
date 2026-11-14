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
    @Query(sort: \SavedHost.name) private var hosts: [SavedHost]
    @State private var isAdding = false
    @State private var editing: CatalogGame?
    /// The selected game, by ID: playing one moves it to the front of the row, and the selection goes with it.
    /// Controller focus is on the row (1), or on the hero's buttons (0).
    @State private var selectedID: String?
    @State private var focusRow = 1
    @State private var heroButton = 0 // 0 Play/Resume, 1 Quit
    @State private var isPressingPlay = false
    @State private var topInset: CGFloat = 0
    @AppStorage(SettingsKey.buttonGuide) private var guideMode = ButtonGuideMode.automatic
    /// The title shows in full on arriving at Home, then fades back so it doesn't compete with the hero, still readable.
    @State private var isTitleFaded = false
    /// The tab rail's width on either side: the hero art reaches under it, so it spans the whole screen.
    @State private var railInsets = EdgeInsets()
    @State private var heroFold = FoldAvoidance(fold: nil, in: .zero)
    /// The height left under a fold across the screen, down to where the covers end, and the cover row's height.
    @State private var belowFold: CGFloat = 0
    @State private var coverRowHeight: CGFloat = 0
    /// Home's height above the guide's room, which sizes the covers and the hero's title.
    @State private var homeHeight: CGFloat = 0
    @State private var rowWidth: CGFloat = 0
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage(SettingsKey.coverShape) private var coverShape = CoverShape.tall

    private var games: [CatalogGame] { catalog.games(on: hosts.map(\.uniqueID)) }

    /// The one row of covers: every game, most recently played first (the catalog's order). Apps (Desktop, Steam)
    /// only when a PC lists no games, so playing one doesn't push the games out.
    private var row: (title: String, games: [CatalogGame])? {
        let all = games
        let onlyGames = all.filter { !$0.isApp }
        return onlyGames.isEmpty ? (all.isEmpty ? nil : ("Apps", all)) : ("Games", onlyGames)
    }

    private var hasRemoteSession: Bool {
        hosts.contains { directory.isAvailable($0.uniqueID) && catalog.remoteSession(on: $0.uniqueID) != nil }
    }

    private var selectedGame: CatalogGame? {
        let games = row?.games ?? []
        return games.first { $0.id == selectedID } ?? games.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if hosts.isEmpty {
                    welcome
                } else if games.isEmpty, hasRemoteSession {
                    // A host in a remote session lists only its controls, no games: those, not "Loading Games".
                    VStack(spacing: 0) {
                        TabTitle(text: "Home", topInset: topInset).padding(.horizontal, 36).opacity(isTitleFaded ? 0.35 : 1)
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
                } else if isSideBySide {
                    sideBySide
                } else {
                    dashboard
                }
            }
            .buttonGuide(guideHints) // inside the insets measured below, which say where the tab bar is
            .navigationTitle("") // drawn by TabTitle instead, lined up with the content 36 points in
            .toolbar {
                let hasTopBar = TabToolbar<EmptyView>.hasTopBar(insets: railInsets)
                if hosts.isEmpty {
                    TabToolbar(hasTopBar: hasTopBar, openSettings: openSettings) { EmptyView() }
                } else {
                    TabToolbar(hasTopBar: hasTopBar, openSettings: openSettings) {
                        PCStatusButton(refresh: refresh, isRefreshing: isRefreshing)
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { railInsets = $0 }

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
            .task { // each time Home comes on screen
                isTitleFaded = false
                try? await Task.sleep(for: .seconds(3))
                withAnimation(.easeInOut(duration: 1.2)) { isTitleFaded = true }
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
        return [([.a], "Play"), ([.y], "Edit")] + (selectedGame?.isRunning(directory) == true ? [([.x], "Quit")] : [])
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
                TabTitle(text: "Home", topInset: topInset).padding(.horizontal, 36).opacity(isTitleFaded ? 0.35 : 1)
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
        .padding(.bottom, showsGuide ? Self.guideGap : (isTabBarBelow ? 8 : -12))
    }

    /// An iPhone in landscape: short, with the tab bar along the bottom. Stacked, the covers would shrink to a sliver
    /// with half the screen empty, so the hero goes on the left and the covers, as tall as there's room for, on the
    /// right. No "Home" title: the tab bar right below already says it (Apple: few controls on screen; keep the tab
    /// bar visible, so it's the title that goes).
    private var isSideBySide: Bool { verticalSizeClass == .compact && isTabBarBelow }

    private var sideBySide: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                if let game = selectedGame {
                    HeroCard(game: game, subtitle: heroSubtitle(game), isShort: true,
                             isRunning: game.isRunning(directory), focusedButton: gamepad.isActive && focusRow == 0 ? heroButton : nil,
                             play: { start(game) }, quit: { quit(game) }, isPressingPlay: isPressingPlay)
                        .fixedSize(horizontal: false, vertical: true) // its own height, centred in the column
                }
                Spacer(minLength: 0)
            }
            .containerRelativeFrame(.horizontal) { width, _ in width * 0.38 }
            VStack(spacing: 0) {
                remoteSessionBanners
                if let row { coverRow(row.games) }
            }
            .frame(maxHeight: .infinity)
        }
        .background {
            ZStack(alignment: .leading) {
                heroArt
                // Over the art, a fade to black behind the hero's text (and the camera housing beside it), so it reads
                // on any picture. Its edge starts at the top-left corner and slopes out to the right as it comes down.
                if let game = selectedGame, catalog.heroArt[game.id] != nil {
                    GeometryReader { proxy in
                        let (width, height) = (proxy.size.width, proxy.size.height)
                        let reach = width * 0.55 // where the edge meets the bottom
                        let length = (height * height + reach * reach).squareRoot()
                        let depth = width * 0.5 // how far in from the edge it's at its darkest
                        // Clear along the line from the top-left corner to (reach, bottom), darkening below and left of it.
                        LinearGradient(stops: [.init(color: Color(.systemBackground).opacity(0.92), location: 0),
                                               .init(color: Color(.systemBackground).opacity(0.55), location: 0.55),
                                               .init(color: .clear, location: 1)],
                                       startPoint: UnitPoint(x: -height * depth / length / width, y: reach * depth / length / height),
                                       endPoint: .topLeading)
                    }
                        .padding(.leading, -railInsets.leading)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { homeHeight = $0 }
    }

    /// Side by side, the selected cover always sits in the same spot, one cover in from the row's start, and the row
    /// slides under it: its leading edge's distance from the row's.
    private var slotLeading: CGFloat { 36 + coverWidth + 14 }

    /// Where scrolling puts the selected cover: centred, or side by side its slot. (An anchor lines up the same point
    /// of the cover and of the row, so the cover's leading edge lands at `slotLeading` at this fraction.)
    private var selectionAnchor: UnitPoint {
        guard isSideBySide, rowWidth > coverWidth else { return .center }
        return UnitPoint(x: slotLeading / (rowWidth - coverWidth), y: 0.5)
    }

    /// How many covers `game` sits before the selection (0 for the selection and those after it).
    private func placesBeforeSelection(_ game: CatalogGame, in games: [CatalogGame]) -> Int {
        guard let index = games.firstIndex(where: { $0.id == game.id }),
              let selected = games.firstIndex(where: { $0.id == selectedGame?.id }) else { return 0 }
        return max(0, selected - index)
    }

    /// Side by side, a swipe along the row moves the selection, a cover per cover-width dragged (a flick goes further),
    /// and the row follows so the selection stays in its slot; the row itself doesn't scroll freely.
    private func swipeSelection(_ value: DragGesture.Value, in games: [CatalogGame]) {
        guard let selected = games.firstIndex(where: { $0.id == selectedGame?.id }) else { return }
        let steps = Int((-value.predictedEndTranslation.width / (coverWidth + 14)).rounded())
        let step = steps != 0 ? steps : (abs(value.translation.width) > 30 ? (value.translation.width < 0 ? 1 : -1) : 0)
        let target = min(max(selected + step, 0), games.count - 1)
        withAnimation(.snappy) { selectedID = games[target].id }
        focusRow = 1
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
        // Side by side, the covers have the height to themselves: about two thirds of it, leaving focus-ring room.
        if isSideBySide, homeHeight > 0 { return (homeHeight * 0.66 * coverShape.ratio).rounded() }
        let preferred: CGFloat = showsGuide ? 116 : 128
        return homeHeight > 0 ? min(preferred, (homeHeight * 0.38 * coverShape.ratio).rounded()) : preferred
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
        let state = game.isRunning(directory) ? "Running now" : playedText(game.lastPlayed)
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
                                      offlinePC: offlinePC(game), isFocused: focusRow == 1 && game.id == selectedGame?.id,
                                      isGlass: isSideBySide && game.id != selectedGame?.id,
                                      fade: isSideBySide ? CoverTile.Fade(placesBeforeSelection: placesBeforeSelection(game, in: games)) : .none)
                                .frame(width: coverWidth)
                                .onTapGesture { // selects only: Play starts it, so a stray second tap can't
                                    withAnimation(.snappy) { selectedID = game.id }
                                    focusRow = 1
                                }
                                .contextMenu { gameMenu(game) }
                                .id(game.id)
                        }
                    }
                    // Side by side, room for the first and last covers to reach the selection's slot too.
                    .padding(.leading, isSideBySide ? slotLeading : 36)
                    .padding(.trailing, isSideBySide ? max(36, rowWidth - slotLeading - coverWidth) : 36) // the last can scroll clear of the rail
                    .padding(.vertical, 12) // room for the focus ring
                }
                .scrollIndicators(.hidden)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
                .scrollDisabled(isSideBySide)
                .gesture(DragGesture(minimumDistance: 20).onEnded { swipeSelection($0, in: games) }, isEnabled: isSideBySide)
                .scrollClipDisabled() // the focused cover's shadow fades out instead of ending in a hard edge
                .fixedSize(horizontal: false, vertical: true) // as tall as the covers, not a share of the spare height
                // Follows the selection, and the selected game when playing it moves it to the front.
                .onChange(of: "\(selectedGame?.id ?? "")|\(games.firstIndex { $0.id == selectedGame?.id } ?? 0)") {
                    withAnimation { scroller.scrollTo(selectedGame?.id, anchor: selectionAnchor) }
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
        guard launcher.busy == nil, let game = selectedGame else {
            if command == .previousTab { switchTab(-1) } else if command == .nextTab { switchTab(1) } else if command == .settings { openSettings() }
            return
        }
        let count = row?.games.count ?? 0, isRunning = game.isRunning(directory)
        switch command {
        case .up: focusRow = 0; heroButton = 0
        case .down: focusRow = 1
        case .left, .right:
            let offset = command == .left ? -1 : 1
            if focusRow == 0 {
                heroButton = isRunning ? min(max(heroButton + offset, 0), 1) : 0
            } else {
                let games = row?.games ?? [], index = games.firstIndex { $0.id == game.id } ?? 0
                withAnimation(.snappy) { selectedID = games[min(max(index + offset, 0), max(count - 1, 0))].id }
            }
        case .select:
            if focusRow == 0, heroButton == 1, isRunning { quit(game) } else { pressPlay(game) }
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
            Label(subtitle, systemImage: isRunning ? "play.circle.fill" : "gamecontroller.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isRunning ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
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
    /// Clear glass with the art greyed and faint, so what's behind shows through (the side-by-side Home's covers
    /// other than the selected one); `fade` clears it away beside the hero's title and Play button.
    var isGlass = false
    var fade = Fade.none

    /// Side by side, the covers left of the selection go so they don't cover the hero: the one beside it is clear on
    /// its left half and comes in over its right; those further left are gone.
    enum Fade {
        case none, half, gone
        init(placesBeforeSelection places: Int) { self = places == 0 ? .none : places == 1 ? .half : .gone }
    }
    @Environment(GameCatalog.self) private var catalog
    @AppStorage(SettingsKey.coverShape) private var coverShape = CoverShape.tall

    var body: some View {
        Color.clear
            .aspectRatio(coverShape.ratio, contentMode: .fit)
            .overlay {
                CoverArt(app: game.sources[0].app, client: client, custom: catalog.cover(for: game.id, coverShape), title: game.title)
                    .blur(radius: offlinePC == nil ? 0 : 8, opaque: true) // no see-through fringe at the edges
                    .saturation(isGlass ? 0 : 1)
                    .opacity(isGlass ? 0.22 : 1)
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
            .background { if isGlass { Color.clear.glassEffect(.clear, in: .rect(cornerRadius: 14)) } }
            .mask {
                LinearGradient(stops: [.init(color: .black.opacity(fade == .none ? 1 : 0), location: 0),
                                       .init(color: .black.opacity(fade == .none ? 1 : 0), location: 0.5),
                                       .init(color: .black, location: 1)], startPoint: .leading, endPoint: .trailing)
                    .padding(-16) // the focus ring and shadow stay inside the mask
            }
            .animation(.snappy, value: isGlass) // turns solid as it becomes the selection
            .opacity(fade == .gone ? 0 : 1)
            .allowsHitTesting(fade != .gone) // nothing to tap where nothing shows
            .animation(.snappy, value: fade)
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
    @ViewBuilder var accessory: Accessory

    var body: some View {
        let isTabBarOnTop = UIDevice.current.userInterfaceIdiom == .pad // the system's choice, not a measurement
        if isTabBarOnTop, Accessory.self == EmptyView.self {
            Color.clear.frame(height: 8)
        } else {
            HStack {
                if !isTabBarOnTop {
                    Text(text)
                        .font(font)
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                }
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
    init(text: String, topInset: CGFloat, font: Font = .title.bold()) {
        self.init(text: text, topInset: topInset, font: font) { EmptyView() }
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
