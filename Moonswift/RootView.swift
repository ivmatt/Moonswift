import Network
import SwiftData
import SwiftUI

/// The app's tabs, like Apple's Games app: Home (featured games and rows), Library (every game from every host) and
/// Hosts; Settings opens over them from each tab's gear. Keeps every PC's status and game list current for all of them, and opens links and Shortcuts.
struct RootView: View {
    enum TabID: Hashable, CaseIterable {
        case home, library, pcs

        var title: String { switch self { case .home: "Home"; case .library: "Library"; case .pcs: "Hosts" } }
        var symbol: String { switch self { case .home: "house"; case .library: "square.stack"; case .pcs: "link" } }
        /// As the tab bar draws it.
        var filledSymbol: String { switch self { case .home: "house.fill"; case .library: "square.stack.fill"; case .pcs: "link" } }
    }

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PCDirectory.self) private var directory
    @Environment(GameCatalog.self) private var catalog
    @Environment(StreamLauncher.self) private var launcher
    @Query(sort: \SavedHost.name) private var hosts: [SavedHost]
    @State private var tab: TabID
    /// The first host is being added: the welcome stays until its success page's Get Started.
    @State private var isSettingUp = false
    @AppStorage(SettingsKey.onlineArtwork) private var findsArtwork = true
    @AppStorage(SettingsKey.artworkKeyVersion) private var artworkKeyVersion = 0

    /// `startingTab` is for previews; the app starts on Home (or a debug launch argument's tab).
    init(startingTab: TabID? = nil) {
        _tab = State(initialValue: startingTab ?? Self.firstTab)
        #if DEBUG
        _showsSettings = State(initialValue: Self.launchArgument("-MoonswiftTab") == "settings") // for screenshots
        #endif
    }

    #if DEBUG
    private static func launchArgument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    #endif

    /// Home, or in debug builds the tab named by `-MoonswiftTab library|pcs|settings|search` (for screenshots).
    private static var firstTab: TabID {
        #if DEBUG
        if let name = launchArgument("-MoonswiftTab"), let tab = TabID.allCases.first(where: { "\($0)" == name }) { return tab }
        #endif
        return .home
    }
    @State private var menu: MenuSpec?
    @State private var wasInBackground = false
    @State private var tabBar = TabBarMinimize()
    @State private var guide = ButtonGuideCenter()
    @Environment(GamepadInput.self) private var gamepad
    /// Settings, over whichever tab (the toolbar's gear, or the controller's Menu button).
    @State private var showsSettings = false

    var body: some View {
        Group {
            // Nothing to show or stream until a host is added: just the welcome, no tabs, toolbar or Settings.
            if hosts.isEmpty || isSettingUp {
                WelcomeView(isSettingUp: $isSettingUp) {
                    tab = .home // whatever tab was open before the last host went
                    withAnimation(.easeInOut(duration: 1.4)) { isSettingUp = false } // slowly, from black
                }
                .transition(.identity) // already black by then
            } else {
                tabs.transition(.opacity) // fades in from black after the first host's Get Started
            }
        }
        // On iPhone, the tab bar shrinks to a button while you scroll down (Library, Hosts) and gives the
        // short landscape screen its height back; scrolling up or tapping brings it back. Apple's way, over moving it.
        .tabBarMinimizeBehavior(.onScrollDown)
        .onAppear { ButtonGuideWindow.install(center: guide, gamepad: gamepad, tabBar: tabBar, launcher: launcher) }
        .onChange(of: tab) { tabBar.isMinimized = false } // a tab change brings the tab bar back
        // Back from a stream (disconnected, or shrunk to Picture in Picture): Home, where its game is (HomeView).
        .onChange(of: launcher.stream == nil || launcher.isMinimized) { _, isBack in if isBack { tab = .home } }
        // Behind everything, out to the screen's edges (on the Duo, the rail's column too): the grey of the grouped
        // list on Hosts, the plain background elsewhere.
        .background {
            (tab == .pcs ? Color(.systemGroupedBackground) : Color(.systemBackground)).ignoresSafeArea()
        }
        .sheet(isPresented: $showsSettings) { SettingsView() }
        .streamLauncher(launcher)
        .actionMenu($menu)
        // Restarts at once when a PC is added, removed, (re)paired or gets a new address.
        .task(id: hosts.map { "\($0.uniqueID)|\($0.serverCert.count)|\($0.address)|\($0.remoteAddress ?? "")" }) {
            await directory.poll(hosts, context: context)
        }
        // Each PC's game list, fetched while it's up (at most every 30 s, so a game installed meanwhile turns up) and
        // kept for when it isn't.
        .onChange(of: directory.lastChecked) {
            for host in hosts where directory.isAvailable(host.uniqueID) {
                let pc = directory.ref(host)
                Task { await catalog.refresh(pc) }
            }
        }
        .onChange(of: uncertainHosts) { routePending() }
        // Checks every 2 s (every tab shows the PCs' status), every 10 s under Settings, none in the background or while
        // a stream is open; and at once on changing tab, coming back to the app, or when this device's network changes.
        .onChange(of: tab, initial: true) { updatePolling(checkNow: true) }
        .onChange(of: showsSettings) { updatePolling(checkNow: !showsSettings) }
        .onChange(of: scenePhase) { scenePhaseChanged() }
        .onChange(of: launcher.stream == nil) { updatePolling(checkNow: launcher.stream == nil) }
        .task { await watchNetwork() }
        .onChange(of: launcher.revision) { // launched, quit or a stream ended: what's running changed
            Task { await directory.checkAll(hosts, context: context, isManual: true) }
            for host in hosts where directory.isAvailable(host.uniqueID) {
                let pc = directory.ref(host)
                Task { await catalog.refresh(pc, force: true) }
            }
        }
        .onChange(of: launcher.session, initial: true) { directory.session = launcher.session }
        // Art from SteamGridDB for games that have none looked up yet: as games appear, or the key or switch changes.
        // Not during a stream, whose network it would share.
        .task(id: "\(findsArtwork)|\(artworkKeyVersion)|\(launcher.stream == nil)|\(catalog.games(on: hosts.map(\.uniqueID)).count)") {
            #if DEBUG
            if DemoMode.isOn { return }
            #endif
            guard findsArtwork, launcher.stream == nil, let key = SteamGridDB.savedKey else { return }
            await catalog.findArtwork(for: catalog.games(on: hosts.map(\.uniqueID)), key: key)
        }
        // The PC says it's gone (PCDirectory): no Resume for it here either.
        .onChange(of: directory.session) { if directory.session == nil, let session = launcher.session { launcher.forgetSession(on: session.pcID) } }
        .onOpenURL { url in
            guard let request = LaunchRequest(url: url) else { return }
            LaunchRouter.shared.isFromLink = true
            LaunchRouter.shared.pending = request
        }
        .onChange(of: LaunchRouter.shared.pending) { routePending() }
        // Outermost, so the sheets and the stream presented above get them too.
        .environment(tabBar)
        .environment(guide)
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab(TabID.home.title, systemImage: TabID.home.symbol, value: .home) {
                Group {
                    if isUnderStream { Color.black } else {
                        HomeView(switchTab: step, openSettings: openSettings, refresh: { Task { await refresh() } })
                    }
                }
                .tint(.accentColor)
            }
            Tab(TabID.library.title, systemImage: TabID.library.symbol, value: .library) {
                Group { if isUnderStream { Color.black } else { GamesView(switchTab: step, openSettings: openSettings) } }
                    .tint(.accentColor)
            }
            Tab(TabID.pcs.title, systemImage: TabID.pcs.symbol, value: .pcs) {
                Group { if isUnderStream { Color.black } else { PCsView(openSettings: openSettings, switchTab: step) } }
                    .tint(.accentColor)
            }
        }
        // The iPad's floating tab bar takes its colour from the tab view and ignores the UITabBar appearance (MyApp):
        // its selected tab white (black in light mode), while each tab puts the accent colour back for its contents.
        .tint(.primary)
    }

    /// A full-screen stream covers the tabs: they aren't drawn under it. Home redrew itself without end under the
    /// stream once the on-screen keyboard came up, freezing the game; nothing there is seen anyway, so nothing there
    /// runs. They come back as the stream ends or goes into Picture in Picture (Home on the game just played, the
    /// catalog's first).
    private var isUnderStream: Bool { launcher.stream != nil && !launcher.isMinimized }

    private func updatePolling(checkNow shouldCheck: Bool) {
        directory.interval = showsSettings ? .seconds(10) : .seconds(2)
        directory.isPaused = scenePhase != .active || launcher.stream != nil
        if shouldCheck { checkNow() }
    }

    /// A check now, rather than at the next one; like the regular checks it forgives a single miss.
    private func checkNow() {
        guard !directory.isPaused else { return }
        Task { await directory.checkAll(hosts, context: context) }
    }

    private var uncertainHosts: [String] { hosts.map(\.uniqueID).filter { directory.isWaiting(on: $0, launcher) } }

    private func scenePhaseChanged() {
        if scenePhase == .background { wasInBackground = true }
        let isBack = scenePhase == .active && wasInBackground // not just a glance at Notification Center
        if isBack { wasInBackground = false }
        updatePolling(checkNow: scenePhase == .active && !isBack)
        if isBack { recheck() }
    }

    /// Wi-Fi dropped, joined, or switched to cellular: a recheck. The monitor also reports small changes on the same
    /// network, which only get an ordinary check, so the buttons don't dim for nothing.
    private func watchNetwork() async {
        var network: String?
        for await path in NWPathMonitor() {
            let current = "\(path.status) \(path.availableInterfaces.first?.name ?? "none")"
            if let network, network != current { recheck() } else { checkNow() }
            network = current
        }
    }

    /// What's known may be out of date: Play, Resume and Quit wait for a fresh answer.
    private func recheck() {
        guard !directory.isPaused else { return }
        Task { await directory.recheck(hosts, context: context) }
    }

    /// Checks every PC's status and game list now, rather than waiting for the next check.
    private func refresh() async {
        guard !directory.isRefreshing else { return }
        directory.isRefreshing = true
        let started = ContinuousClock.now
        await directory.checkAll(hosts, context: context, isManual: true)
        // Not waited for: a slow game list says "Getting games…" and shouldn't hold Play back.
        Task {
            for host in hosts where directory.isAvailable(host.uniqueID) {
                await catalog.refresh(directory.ref(host), force: true)
            }
        }
        // Spins at least a second, so a quick answer still reads as the refresh having happened.
        try? await Task.sleep(until: started + .seconds(1))
        directory.isRefreshing = false
    }

    private func openSettings() { showsSettings = true }

    /// L1/R1: the previous or next tab, stopping at the first and last (L1 on Home went round to the last).
    private func step(_ offset: Int) {
        let all = TabID.allCases, index = (all.firstIndex(of: tab) ?? 0) + offset
        if all.indices.contains(index) { tab = all[index] }
    }

    /// A link or Shortcut asked for a game: start it once its PC's status is known.
    private func routePending() {
        guard let request = LaunchRouter.shared.pending else { return }
        guard let host = hosts.first(where: { request.matches(pcID: $0.uniqueID, name: $0.displayName)
                                              || request.matches(pcID: $0.uniqueID, name: $0.name) }) else {
            LaunchRouter.shared.pending = nil
            return menu = .error("There's no host called \(request.pc) in Moonswift.", title: "Host not found")
        }
        guard let status = directory.statuses[host.uniqueID],
              !directory.isWaiting(on: host.uniqueID, launcher) else { return } // still checking
        let isFromLink = LaunchRouter.shared.isFromLink
        LaunchRouter.shared.pending = nil
        guard status == .online(paired: true) else {
            return menu = .error("It may be asleep or off, or not paired.", title: "\(host.displayName) isn't available")
        }
        let pc = directory.ref(host)
        Task {
            await catalog.refresh(pc, force: true)
            guard let app = request.game(in: catalog.apps[pc.id] ?? []) else {
                return menu = .error("\(pc.name) has no game called \(request.game).", title: "Game not found")
            }
            let start = {
                let running = directory.playing[pc.id] ?? 0
                launcher.play(app, on: pc, running: running, runningTitle: catalog.title(of: running, on: pc.id))
            }
            guard isFromLink else { return start() }
            launcher.menu = MenuSpec(title: "Play \(app.title)?", message: "A link asked to start it on \(pc.name).",
                                     actions: [.init(title: "Play") { start() }])
        }
    }
}

/// Starting a catalog game: on the PC that's running it, else the one it was last played on, else any that's up.
extension CatalogGame {
    @MainActor func source(directory: PCDirectory, catalog: GameCatalog) -> Source? {
        let available = sources.filter { directory.isAvailable($0.pcID) }
        return available.first { directory.playing[$0.pcID] == $0.app.id }
            ?? available.max { a, b in
                let dateA = catalog.histories[a.pcID]?.lastPlayed[GameHistory.key(a.app)] ?? .distantPast
                let dateB = catalog.histories[b.pcID]?.lastPlayed[GameHistory.key(b.app)] ?? .distantPast
                return dateA < dateB
            }
    }

    /// A PC with it is still being confirmed, so Play, Resume and Quit wait (it could start on the wrong one).
    @MainActor func isWaitingForStatus(_ directory: PCDirectory, _ launcher: StreamLauncher) -> Bool {
        sources.contains { directory.isWaiting(on: $0.pcID, launcher) }
    }

    /// Why it can't be played, once every PC with it is known to be down or not paired (not while the first check is
    /// still out): the first one's name, and what's wrong with them.
    @MainActor func unavailable(hosts: [SavedHost], directory: PCDirectory) -> (pc: String, reason: String)? {
        let statuses = sources.map { directory.statuses[$0.pcID] }
        guard statuses.allSatisfy({ $0 == .offline || $0 == .online(paired: false) }) else { return nil }
        let name = sources.lazy.compactMap { s in hosts.first { $0.uniqueID == s.pcID }?.displayName }.first ?? "Its host"
        return (name, statuses.allSatisfy { $0 == .offline } ? "is offline" : "isn't paired")
    }

    /// Another device is streaming it: the host's controls to join that session or end it.
    @MainActor func elsewhere(_ directory: PCDirectory, _ catalog: GameCatalog) -> (pcID: String, join: HostApp?, end: HostApp?)? {
        for source in sources where directory.playing[source.pcID] == source.app.id {
            if let session = catalog.remoteSession(on: source.pcID), !session.isOwn, session.join != nil || session.end != nil {
                return (source.pcID, session.join, session.end)
            }
        }
        return nil
    }

    /// Its running buttons: Join and End Session while another device plays it, Resume and Quit otherwise.
    @MainActor func runningLabels(_ directory: PCDirectory, _ catalog: GameCatalog) -> (resume: String, quit: String) {
        elsewhere(directory, catalog) == nil ? ("Resume", "Quit") : ("Join", "End Session")
    }

    @MainActor func isRunning(_ directory: PCDirectory) -> Bool {
        sources.contains { directory.playing[$0.pcID] == $0.app.id }
    }
}

/// Plays a catalog game from any screen, or explains why it can't.
func play(_ game: CatalogGame, hosts: [SavedHost], directory: PCDirectory, catalog: GameCatalog,
                     launcher: StreamLauncher) {
    guard !game.isWaitingForStatus(directory, launcher) else { return }
    // Another device is playing it: joining it, after asking.
    if let other = game.elsewhere(directory, catalog), let join = other.join,
       let host = hosts.first(where: { $0.uniqueID == other.pcID }) {
        return launcher.confirmJoin(join, title: game.title, on: directory.ref(host))
    }
    guard let source = game.source(directory: directory, catalog: catalog),
          let host = hosts.first(where: { $0.uniqueID == source.pcID }) else {
        let names = game.sources.compactMap { source in hosts.first { $0.uniqueID == source.pcID }?.displayName }
        launcher.menu = .error("It may be asleep or off.", title: "\(names.first ?? "Its host") isn't available")
        return
    }
    let running = directory.playing[source.pcID] ?? 0
    launcher.play(source.app, on: directory.ref(host), running: running,
                  runningTitle: catalog.title(of: running, on: source.pcID))
}

/// Quits a running catalog game on its PC, or ends another device's session playing it; after asking.
func quit(_ game: CatalogGame, hosts: [SavedHost], directory: PCDirectory, catalog: GameCatalog,
                     launcher: StreamLauncher) {
    guard !game.isWaitingForStatus(directory, launcher) else { return }
    if let other = game.elsewhere(directory, catalog), let end = other.end,
       let host = hosts.first(where: { $0.uniqueID == other.pcID }) {
        return launcher.confirmEndSession(end, on: directory.ref(host))
    }
    guard let source = game.sources.first(where: { directory.playing[$0.pcID] == $0.app.id }),
          let host = hosts.first(where: { $0.uniqueID == source.pcID }) else { return }
    launcher.confirmQuit(game.title, on: directory.ref(host))
}
