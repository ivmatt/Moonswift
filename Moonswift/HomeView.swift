import SwiftData
import SwiftUI

/// Home, after Apple's Games app, on one screen with no scrolling: a carousel of featured games (the running one
/// first, then recent and favourite ones) and one row of covers (Continue Playing, else all games); every game is in
/// Library. Games from every PC, in one place. Controller: up/down between the carousel and the row, left/right
/// within them, A plays, Y favourites, L1/R1 switch tabs, Menu opens Settings.
struct HomeView: View {
    var switchTab: (Int) -> Void
    var openSettings: () -> Void = {}

    @Environment(PCDirectory.self) private var directory
    @Environment(GameCatalog.self) private var catalog
    @Environment(StreamLauncher.self) private var launcher
    @Environment(GamepadInput.self) private var gamepad
    @Query(sort: \SavedHost.name) private var hosts: [SavedHost]
    @State private var featuredID: String?
    /// A finger is on the carousel, or it's still scrolling: no auto-advance.
    @State private var isTouchingHero = false
    @State private var isScrollingHero = false
    @State private var isAdding = false
    /// Controller focus: row 0 is the carousel, row 1 the covers.
    @State private var focusRow = 0
    @State private var focusColumn = 0
    @State private var topInset: CGFloat = 0
    /// The tab rail's width on either side: the carousel reaches under it, so pages span the whole screen.
    @State private var railInsets = EdgeInsets()

    private var games: [CatalogGame] { catalog.games(on: hosts.map(\.uniqueID)) }

    /// Running games, then recently played, then favourites, then the rest: five at most. Apps (Desktop, Steam) only
    /// when a PC lists no games, as when its games live inside Steam Big Picture.
    private var featured: [CatalogGame] {
        let onlyGames = games.filter { !$0.isApp }
        let candidates = onlyGames.isEmpty ? games : onlyGames
        let ordered = candidates.filter { $0.isRunning(directory) } + candidates.filter { $0.lastPlayed != nil }
            + candidates.filter(\.isFavorite) + candidates
        var seen = Set<String>()
        return Array(ordered.filter { seen.insert($0.id).inserted }.prefix(5))
    }

    /// The one row of covers: every game, most recently played first (the catalog's order). Apps (Desktop, Steam)
    /// only when a PC lists no games, so playing one doesn't push the games out.
    private var row: (title: String, games: [CatalogGame])? {
        let all = games
        let onlyGames = all.filter { !$0.isApp }
        return onlyGames.isEmpty ? (all.isEmpty ? nil : ("Apps", all)) : ("Games", onlyGames)
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
                        Text("Your PC's games appear here once it answers.")
                    } actions: {
                        ProgressView()
                    }
                } else {
                    dashboard
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
            .background(Color.black)
            .environment(\.colorScheme, .dark)
            .sheet(isPresented: $isAdding) { AddHostView() }
            .onGamepad(handle)
        }
    }

    private var welcome: some View {
        ContentUnavailableView {
            Label("Welcome to Moonswift", systemImage: "play.tv")
        } description: {
            Text("Stream games from your PC. Start by pairing it; it needs to be on and on the same network.")
        } actions: {
            Button("Pair a PC") { isAdding = true }.buttonStyle(.glassProminent).controlSize(.large)
        }
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 0) {
            TabTitle(text: "Home", topInset: topInset).padding(.horizontal, 36)
            carousel.frame(maxHeight: .infinity)
                .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { railInsets = $0 }
            remoteSessionBanners
            if let row { coverRow(row.title, row.games) }
        }
        .padding(.bottom, 16)
    }

    // MARK: Carousel

    private var carousel: some View {
        let featured = featured
        return ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(featured) { game in
                    HeroCard(game: game, subtitle: heroSubtitle(game), leadingInset: railInsets.leading,
                             isRunning: game.isRunning(directory), isFocused: gamepad.isActive && focusRow == 0) { start(game) }
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(game.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $featuredID)
        .onScrollPhaseChange { _, phase in
            isScrollingHero = phase != .idle
            if phase == .idle { isTouchingHero = false } // a drag that became a scroll never reports its end
        }
        // Holding still without scrolling; simultaneous, so it doesn't stop the swipe or the Play button.
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in isTouchingHero = true }
            .onEnded { _ in isTouchingHero = false })
        // The tab gives its content only the screen beside the rail, so reach under it; ignoring the safe area can't.
        .padding(.leading, -railInsets.leading)
        .padding(.trailing, -railInsets.trailing)
        .overlay(alignment: .bottom) {
            HStack(spacing: 8) {
                ForEach(featured) { game in
                    Capsule().fill(.white.opacity(game.id == (featuredID ?? featured.first?.id) ? 1 : 0.4))
                        .frame(width: game.id == (featuredID ?? featured.first?.id) ? 22 : 8, height: 8)
                }
            }
            .animation(.snappy, value: featuredID)
            .padding(.bottom, 8)
        }
        // Moves on 8 seconds after the page last changed or a finger last let go, like a storefront; never while held.
        .task(id: "\(featured.map(\.id))|\(featuredID ?? "")|\(isTouchingHero || isScrollingHero)") {
            guard featured.count > 1, !isTouchingHero, !isScrollingHero else { return }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            let index = featured.firstIndex { $0.id == featuredID } ?? 0
            withAnimation { featuredID = featured[(index + 1) % featured.count].id }
        }
    }

    /// Clear of the status bar where there is one; on the Duo (status in the side rail) the same breathing room as
    /// Apple's Games app.
    static func titleTop(_ inset: CGFloat) -> CGFloat { max(inset, 20) + 24 }

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
                .background(.white.opacity(0.08), in: .rect(cornerRadius: 18))
                .padding(.leading, 36)
                .padding(.trailing, 36)
            }
        }
    }

    // MARK: Rows

    private func coverRow(_ title: String, _ games: [CatalogGame]) -> some View {
        let rowIndex = 1
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.bold()).foregroundStyle(.white).padding(.leading, 36)
            ScrollViewReader { scroller in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 14) {
                        ForEach(Array(games.enumerated()), id: \.element.id) { index, game in
                            CoverTile(game: game, client: client(for: game), isRunning: game.isRunning(directory),
                                      isAvailable: isAvailable(game),
                                      isFocused: gamepad.isActive && focusRow == rowIndex && focusColumn == index)
                                .frame(width: 104)
                                .onTapGesture { start(game) }
                                .onLongPressGesture { catalog.toggleFavorite(game) }
                                .id(index)
                        }
                    }
                    .padding(.leading, 36)
                    .padding(.trailing, 36) // the last cover can scroll clear of the rail
                    .padding(.vertical, 12) // room for the focus ring
                }
                .scrollIndicators(.hidden)
                .fixedSize(horizontal: false, vertical: true) // as tall as the covers, not a share of the spare height
                .onChange(of: focusColumn) { if focusRow == rowIndex { withAnimation { scroller.scrollTo(focusColumn, anchor: .center) } } }
            }
        }
    }

    // MARK: Actions

    private func client(for game: CatalogGame) -> HostClient? {
        game.sources.lazy.compactMap { source in self.hosts.first { $0.uniqueID == source.pcID } }.first.map { directory.ref($0).client }
    }

    /// Dimmed only once its PC is known to be down, not while the first check is still out.
    private func isAvailable(_ game: CatalogGame) -> Bool { game.sources.contains { directory.statuses[$0.pcID] != .offline } }

    private func start(_ game: CatalogGame) {
        play(game, hosts: hosts, directory: directory, catalog: catalog, launcher: launcher)
    }

    private func handle(_ command: GamepadCommand) {
        guard launcher.busy == nil else { return }
        let rowGames = row?.games ?? [], featured = featured
        let count = focusRow == 0 ? featured.count : rowGames.count
        switch command {
        case .up: focusRow = 0; focusColumn = 0
        case .down: focusRow = rowGames.isEmpty ? 0 : 1; focusColumn = 0
        case .left, .right:
            let offset = command == .left ? -1 : 1
            if focusRow == 0 {
                let index = featured.firstIndex { $0.id == featuredID } ?? 0
                withAnimation { featuredID = featured[min(max(index + offset, 0), featured.count - 1)].id }
            } else {
                focusColumn = min(max(focusColumn + offset, 0), max(count - 1, 0))
            }
        case .select, .menu:
            let game: CatalogGame? = focusRow == 0 ? featured.first { $0.id == featuredID } ?? featured.first
                : rowGames.indices.contains(focusColumn) ? rowGames[focusColumn] : nil
            guard let game else { return }
            if command == .select { start(game) } else { catalog.toggleFavorite(game) }
        case .previousTab: switchTab(-1)
        case .nextTab: switchTab(1)
        case .settings: openSettings()
        default: break
        }
    }
}

/// A featured game: what it is, and Play (or Resume). On black for now; see the shortcut below.
private struct HeroCard: View {
    let game: CatalogGame
    let subtitle: String
    let leadingInset: CGFloat
    let isRunning: Bool
    let isFocused: Bool
    let play: () -> Void

    var body: some View {
        // shortcut: plain black until there's proper wide hero art from an outside source.
        VStack(alignment: .leading, spacing: 8) {
            Label(subtitle, systemImage: isRunning ? "play.circle.fill" : "gamecontroller.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isRunning ? .green : .white.opacity(0.8))
            Text(game.title)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            Button(action: play) {
                Text(isRunning ? "Resume" : "Play").font(.headline).frame(width: 140)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .focusRing(isFocused, cornerRadius: .infinity) // the glass button is a capsule
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.horizontal, 36)
        .padding(.leading, leadingInset) // clear of a rail on the left
        .padding(.bottom, 28) // room for the page dots
        .background(Color.black)
    }
}

/// A game's cover: portrait art with a running ring and favourite star; dimmed while its PC is unavailable. As wide
/// as it's given, 3:4.
struct CoverTile: View {
    let game: CatalogGame
    let client: HostClient?
    let isRunning: Bool
    let isAvailable: Bool
    let isFocused: Bool

    var body: some View {
        Color.clear
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay { CoverArt(app: game.sources[0].app, client: client) }
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
            .opacity(isAvailable ? 1 : 0.4)
            .focusRing(isFocused, cornerRadius: 14)
            .contentShape(.rect)
            .accessibilityElement()
            .accessibilityLabel(game.title)
            .accessibilityValue([isRunning ? "Running" : nil, game.isFavorite ? "Favorite" : nil, isAvailable ? nil : "PC offline"]
                .compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(.isButton)
    }
}

/// A tab's page title, placed exactly like Home's: the same distance from the top of the screen, and lined up with
/// the page's content 36 points in. `topInset` is the page's top safe area (the status bar, where there is one).
struct TabTitle: View {
    let text: String
    let topInset: CGFloat

    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            Color.clear.frame(height: 8) // the tab bar across the top already names the tab
        } else {
            Text(text)
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, HomeView.titleTop(topInset) - topInset)
                .accessibilityAddTraits(.isHeader)
        }
    }
}
