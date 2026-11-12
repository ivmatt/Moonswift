import SwiftData
import SwiftUI

/// The app's tabs, like Apple's Games app: Home (featured games and rows), Library (every game from every PC), PCs
/// (devices) and Search. Keeps every PC's status and game list current for all of them, and opens links and Shortcuts.
struct RootView: View {
    enum TabID: Hashable, CaseIterable { case home, library, pcs, settings, search }

    @Environment(\.modelContext) private var context
    @Environment(PCDirectory.self) private var directory
    @Environment(GameCatalog.self) private var catalog
    @Environment(StreamLauncher.self) private var launcher
    @Query(sort: \SavedHost.name) private var hosts: [SavedHost]
    @State private var tab = TabID.home
    @State private var menu: MenuSpec?

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house.fill", value: .home) { HomeView(switchTab: step) { tab = .settings } }
            Tab("Library", systemImage: "square.stack.fill", value: .library) { GamesView(switchTab: step) { tab = .settings } }
            Tab("PCs", systemImage: "desktopcomputer", value: .pcs) { PCsView(openSettings: { tab = .settings }, switchTab: step) }
            Tab("Settings", systemImage: "gearshape.fill", value: .settings) { SettingsView(switchTab: step) }
            Tab(value: .search, role: .search) { GameSearchView(switchTab: step) { tab = .settings } }
        }
        .streamLauncher(launcher)
        .actionMenu($menu)
        .preferredColorScheme(.dark) // a game launcher: dark everywhere, so tabs don't flash between Home's dark and light
        // Restarts at once when a PC is added, removed, (re)paired or gets a new address.
        .task(id: hosts.map { "\($0.uniqueID)|\($0.serverCert.count)|\($0.address)|\($0.remoteAddress ?? "")" }) {
            await directory.poll(hosts, context: context)
        }
        // Each PC's game list, fetched while it's up (at most every 30 s) and kept for when it isn't.
        .onChange(of: directory.statuses) {
            for host in hosts where directory.isAvailable(host.uniqueID) {
                let pc = directory.ref(host)
                Task { await catalog.refresh(pc) }
            }
            routePending()
        }
        .onChange(of: launcher.revision) {
            for host in hosts where directory.isAvailable(host.uniqueID) {
                let pc = directory.ref(host)
                Task { await catalog.refresh(pc, force: true) }
            }
        }
        .onOpenURL { url in if let request = LaunchRequest(url: url) { LaunchRouter.shared.pending = request } }
        .onChange(of: LaunchRouter.shared.pending) { routePending() }
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
            return menu = .error("There's no PC called \(request.pc) in Moonswift.")
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
