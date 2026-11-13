import SwiftData
import SwiftUI

/// Home, after Apple's Games app, on one screen with no scrolling: one row of every game, most recently played first,
/// and above it a hero for the selected game (your own art behind it, if you added some), with Play, or Resume and
/// Quit while it runs. Tap a cover to select it, tap again to play. Controller: left/right through the row, up/down
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
    @State private var topInset: CGFloat = 0
    @State private var guideHeight: CGFloat = 0
    /// The tab rail's width on either side: the hero art reaches under it, so it spans the whole screen.
    @State private var railInsets = EdgeInsets()
    @State private var heroFold = FoldAvoidance(fold: nil, in: .zero)
    /// The height left under a fold across the screen, down to where the covers end, and the cover row's height.
    @State private var belowFold: CGFloat = 0
    @State private var coverRowHeight: CGFloat = 0
    /// Home's height above the guide's room, which sizes the covers and the hero's title.
    @State private var homeHeight: CGFloat = 0
    @AppStorage(SettingsKey.coverShape) private var coverShape = CoverShape.tall

    private var games: [CatalogGame] { catalog.games(on: hosts.map(\.uniqueID)) }

    /// The one row of covers: every game, most recently played first (the catalog's order). Apps (Desktop, Steam)
    /// only when a PC lists no games, so playing one doesn't push the games out.
    private var row: (title: String, games: [CatalogGame])? {
        let all = games
        let onlyGames = all.filter { !$0.isApp }
        return onlyGames.isEmpty ? (all.isEmpty ? nil : ("Apps", all)) : ("Games", onlyGames)
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
            .navigationTitle("") // drawn by TabTitle instead, lined up with the content 36 points in
            .toolbar {
                if !hosts.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        PCStatusButton(refresh: refresh, isRefreshing: isRefreshing)
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }

            .background(Color(.systemBackground))
            .sheet(isPresented: $isAdding) { AddHostView() }
            .sheet(item: $editing) { GameEditView(game: $0) }
            .onGamepad(handle)
        }
    }

    /// With a controller: the button guide, bottom left, in line with the page's content and resting on the bottom of
    /// the safe area. It slides away when the controller goes, and the covers grow into its space.
    @ViewBuilder private var buttonGuide: some View {
        if gamepad.isControllerConnected, !games.isEmpty {
            ControllerHints(hints: [([.a], "Play"), ([.y], "Edit")]
                            + (selectedGame?.isRunning(directory) == true ? [([.x], "Quit")] : [])
                            + [([.view], "Refresh"), ([.menu], "Settings")])
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { guideHeight = $0 }
                .padding(.leading, 36) // lined up with the title, hero and covers
                // ControllerHints keeps 8 points below itself: its pill ends at the safe area's edge, or keeps those 8
                // points clear of a tab bar along the bottom.
                .offset(y: isTabBarBelow ? 0 : 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
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
                TabTitle(text: "Home", topInset: topInset).padding(.horizontal, 36)
                    .padding(.top, -max(0, topInset - Self.windowTopInset))
                if let game = selectedGame {
                    HeroCard(game: game, subtitle: heroSubtitle(game), isShort: isShort,
                             isRunning: game.isRunning(directory), focusedButton: gamepad.isActive && focusRow == 0 ? heroButton : nil,
                             play: { start(game) }, quit: { quit(game) })
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
        .padding(.bottom, gamepad.isControllerConnected ? guideHeight - (isTabBarBelow ? 0 : 8) + Self.guideGap
                                                        : (isTabBarBelow ? 8 : -12))
        .overlay(alignment: .bottomLeading) { buttonGuide }
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { railInsets = $0 }
    }

    /// The selected game's own hero picture, behind the title and hero and fading out just above the covers; plain
    /// background without.
    @ViewBuilder private var heroArt: some View {
        if let game = selectedGame, let art = catalog.heroArt[game.id] {
            Color.clear
                .overlay { Image(uiImage: art).resizable().scaledToFill() }
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
                .id(game.id)
                .transition(.opacity)
                .accessibilityHidden(true)
        }
    }

    /// The tab bar runs along the bottom (the Duo's inner display in portrait), so nothing may hang below the safe area.
    /// shortcut: iOS doesn't say where its tab bar is; a bottom inset this tall is one. Revisit if the system says.
    private var isTabBarBelow: Bool { railInsets.bottom > 40 }

    /// Above the guide: with the cover row's 12 points of focus-ring room, the same 28 points as between Play and the
    /// covers (the hero's 16 below Play, plus those 12).
    static let guideGap: CGFloat = 16
    /// Covers are bigger without a controller (easier to tap), smaller with one to make room for its guide; and on a
    /// short screen (the Duo's outer display) no taller than about a third of Home, so the hero keeps its room.
    private var coverWidth: CGFloat {
        let preferred: CGFloat = gamepad.isControllerConnected ? 104 : 128
        return homeHeight > 0 ? min(preferred, (homeHeight * 0.34 * coverShape.ratio).rounded()) : preferred
    }
    /// Home is short (the Duo's outer display): the hero's title is set smaller.
    private var isShort: Bool { homeHeight > 0 && homeHeight < 520 }

    /// The window's top safe area: a tab without a toolbar has just this.
    static var windowTopInset: CGFloat {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }.first ?? 0
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
                        Text("Being streamed on another device").font(.headline)
                        Text(host.displayName).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let join = session.join {
                        Button("Join") { launcher.join(join, on: directory.ref(host)) }.buttonStyle(.glassProminent)
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
                                .onTapGesture { // select, then play
                                    if game.id == selectedGame?.id { start(game) } else { withAnimation(.snappy) { selectedID = game.id } }
                                    focusRow = 1
                                }
                                .contextMenu { gameMenu(game) }
                                .id(game.id)
                        }
                    }
                    .padding(.leading, 36)
                    .padding(.trailing, 36) // the last cover can scroll clear of the rail
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
            if focusRow == 0, heroButton == 1, isRunning { quit(game) } else { start(game) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(subtitle, systemImage: isRunning ? "play.circle.fill" : "gamecontroller.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isRunning ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            Text(game.title)
                .font(.system(size: isShort ? 28 : 34, weight: .bold))
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
