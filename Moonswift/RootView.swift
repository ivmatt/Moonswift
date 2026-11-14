import Network
import SwiftData
import SwiftUI

/// The app's tabs, like Apple's Games app: Home (featured games and rows), Library (every game from every PC), PCs
/// (devices) and Search. Keeps every PC's status and game list current for all of them, and opens links and Shortcuts.
struct RootView: View {
    enum TabID: Hashable, CaseIterable { case home, library, pcs, settings }

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PCDirectory.self) private var directory
    @Environment(GameCatalog.self) private var catalog
    @Environment(StreamLauncher.self) private var launcher
    @Query(sort: \SavedHost.name) private var hosts: [SavedHost]
    @State private var tab: TabID

    /// `startingTab` is for previews; the app starts on Home (or a debug launch argument's tab).
    init(startingTab: TabID? = nil) {
        _tab = State(initialValue: startingTab ?? Self.firstTab)
    }

    /// Home, or in debug builds the tab named by `-MoonswiftTab library|pcs|settings|search` (for screenshots).
    private static var firstTab: TabID {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-MoonswiftTab"), index + 1 < arguments.count,
           let tab = TabID.allCases.first(where: { "\($0)" == arguments[index + 1] }) { return tab }
        #endif
        return .home
    }
    @State private var menu: MenuSpec?
    @State private var isRefreshing = false
    @State private var tabBar = TabBarMinimize()

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: .home) {
                HomeView(switchTab: step, openSettings: { tab = .settings }, refresh: { Task { await refresh() } },
                         isRefreshing: isRefreshing)
            }
            Tab("Library", systemImage: "app.grid.2x2", value: .library) { GamesView(switchTab: step) { tab = .settings } }
            Tab("Hosts", systemImage: "link", value: .pcs) { PCsView(openSettings: { tab = .settings }, switchTab: step) }
            Tab("Settings", systemImage: "switch.2", value: .settings) { SettingsView(switchTab: step) }
        }
        // On iPhone, the tab bar shrinks to a button while you scroll down (Library, Search, Hosts, Settings) and gives the
        // short landscape screen its height back; scrolling up or tapping brings it back. Apple's way, over moving it.
        .tabBarMinimizeBehavior(.onScrollDown)
        .environment(tabBar)
        .onChange(of: tab) { tabBar.isMinimized = false } // a tab change brings the tab bar back
        // Behind everything, out to the screen's edges (on the Duo, the rail's column too): the grey of the grouped
        // lists on PCs, Settings and Search, the plain background elsewhere.
        .background {
            ([.pcs, .settings].contains(tab) ? Color(.systemGroupedBackground) : Color(.systemBackground)).ignoresSafeArea()
        }
        // iPad: the selected tab white rather than blue (see styleFloatingTabBar); again after a tab change or rotation,
        // which can rebuild the bar.
        .task(id: tab) {
            await Task.yield()
            styleFloatingTabBar()
            try? await Task.sleep(for: .milliseconds(350)) // again once the selection has moved
            styleFloatingTabBar()
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in Task { styleFloatingTabBar() } }
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
        .onChange(of: directory.statuses) { routePending() }
        // Checks every 2 s while Home shows the status, every 10 s on other tabs, none in the background or while a
        // stream is open; and at once on coming back to Home or the app, or when this device's network changes.
        .onChange(of: tab, initial: true) { updatePolling(checkNow: tab == .home) }
        .onChange(of: scenePhase) { updatePolling(checkNow: scenePhase == .active) }
        .onChange(of: launcher.stream == nil) { updatePolling(checkNow: launcher.stream == nil) }
        .task {
            for await _ in NWPathMonitor() { checkNow() } // Wi-Fi dropped, joined, or switched to cellular
        }
        .onChange(of: launcher.revision) { // launched, quit or a stream ended: what's running changed
            Task { await directory.checkAll(hosts, context: context, isManual: true) }
            for host in hosts where directory.isAvailable(host.uniqueID) {
                let pc = directory.ref(host)
                Task { await catalog.refresh(pc, force: true) }
            }
        }
        .onChange(of: launcher.session, initial: true) { directory.session = launcher.session }
        .onOpenURL { url in if let request = LaunchRequest(url: url) { LaunchRouter.shared.pending = request } }
        .onChange(of: LaunchRouter.shared.pending) { routePending() }
    }

    private func updatePolling(checkNow shouldCheck: Bool) {
        directory.interval = tab == .home ? .seconds(2) : .seconds(10)
        directory.isPaused = scenePhase != .active || launcher.stream != nil
        if shouldCheck { checkNow() }
    }

    /// A check now, rather than at the next one; like the regular checks it forgives a single miss.
    private func checkNow() {
        guard !directory.isPaused else { return }
        Task { await directory.checkAll(hosts, context: context) }
    }

    /// Checks every PC's status and game list now, rather than waiting for the next check.
    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let started = ContinuousClock.now
        await directory.checkAll(hosts, context: context, isManual: true)
        for host in hosts where directory.isAvailable(host.uniqueID) {
            await catalog.refresh(directory.ref(host), force: true)
        }
        // Spins at least a second, so a quick answer still reads as the refresh having happened.
        try? await Task.sleep(until: started + .seconds(1))
        isRefreshing = false
    }

    /// The iPad's tab bar floats across the top as its own view, which takes its colour from the tab view (blue) and
    /// ignores the UITabBar appearance that colours the Duo's rail (MyApp). Tinting the whole tab view instead reaches
    /// the sliders, switches and menus inside the tabs, so just this bar is tinted: the selected tab white (black in
    /// light mode) and the others dimmed, like Apple's Games app.
    /// shortcut: found by private class names; if iOS renames them, the iPad's tabs go back to the system look
    /// (nothing breaks). Revisit if SwiftUI gets a way to colour only the tab bar.
    private func styleFloatingTabBar() {
        func labels(in view: UIView) -> [UILabel] { (view as? UILabel).map { [$0] } ?? view.subviews.flatMap(labels) }
        func style(_ view: UIView) {
            let name = String(describing: type(of: view))
            if name == "_UIFloatingTabBar" { view.tintColor = .label }
            if name == "_UIFloatingTabBarItemView" {
                // The selected tab's title is drawn in the tint colour.
                let isSelected = labels(in: view).contains { String(describing: type(of: $0.textColor as Any)).contains("TintColor") }
                view.alpha = isSelected ? 1 : 0.6
                return
            }
            view.subviews.forEach(style)
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) { scene.windows.forEach(style) }
    }

    /// L1/R1: the previous or next tab.
    private func step(_ offset: Int) {
        let all = TabID.allCases, index = all.firstIndex(of: tab) ?? 0
        tab = all[(index + offset + all.count) % all.count]
    }

    /// A link or Shortcut asked for a game: start it once its PC's status is known.
    private func routePending() {
        guard let request = LaunchRouter.shared.pending else { return }
        guard let host = hosts.first(where: { request.matches(pcID: $0.uniqueID, name: $0.displayName)
                                              || request.matches(pcID: $0.uniqueID, name: $0.name) }) else {
            LaunchRouter.shared.pending = nil
            return menu = .error("There's no host called \(request.pc) in Moonswift.")
        }
        guard let status = directory.statuses[host.uniqueID] else { return } // still checking
        LaunchRouter.shared.pending = nil
        guard status == .online(paired: true) else {
            return menu = .error("\(host.displayName) isn't available. It may be asleep or off, or not paired.")
        }
        let pc = directory.ref(host)
        Task {
            await catalog.refresh(pc, force: true)
            guard let app = request.game(in: catalog.apps[pc.id] ?? []) else {
                return menu = .error("\(pc.name) has no game called \(request.game).")
            }
            let running = directory.playing[pc.id] ?? 0
            launcher.play(app, on: pc, running: running, runningTitle: catalog.title(of: running, on: pc.id))
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

    @MainActor func isRunning(_ directory: PCDirectory) -> Bool {
        sources.contains { directory.playing[$0.pcID] == $0.app.id }
    }
}

/// Plays a catalog game from any screen, or explains why it can't.
@MainActor func play(_ game: CatalogGame, hosts: [SavedHost], directory: PCDirectory, catalog: GameCatalog,
                     launcher: StreamLauncher) {
    guard let source = game.source(directory: directory, catalog: catalog),
          let host = hosts.first(where: { $0.uniqueID == source.pcID }) else {
        let names = game.sources.compactMap { source in hosts.first { $0.uniqueID == source.pcID }?.displayName }
        launcher.menu = .error("\(names.first ?? "Its PC") isn't available right now. It may be asleep or off.")
        return
    }
    let running = directory.playing[source.pcID] ?? 0
    launcher.play(source.app, on: directory.ref(host), running: running,
                  runningTitle: catalog.title(of: running, on: source.pcID))
}
