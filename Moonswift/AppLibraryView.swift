import SwiftUI

/// A paired PC's games as a box-art grid. Tapping a game (or A) launches it, or offers Resume/Quit if it's
/// running; Y/X opens the game's menu; B goes back.
struct AppLibraryView: View {
    let client: HostClient
    let name: String

    @Environment(\.dismiss) private var dismiss
    @Environment(GamepadInput.self) private var gamepad
    @State private var apps: [HostApp] = []
    @State private var runningID = 0 // 0 = nothing running
    @State private var loadError: String?
    @State private var isLoaded = false
    @State private var busy: String? // e.g. "Launching Hades…" while a request is in flight
    @State private var menu: MenuSpec?
    @State private var focus = 0
    @State private var columns = 1
    @State private var stream: StreamTarget? // set after a successful Launch or Resume

    private static let tileWidth: CGFloat = 170
    private static let spacing: CGFloat = 24

    private var running: HostApp? { apps.first { $0.id == runningID } }
    /// The running game first, the rest in the host's order.
    private var ordered: [HostApp] { apps.filter { $0.id == runningID } + apps.filter { $0.id != runningID } }
    private var focusIndex: Int { min(focus, max(ordered.count - 1, 0)) }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroller in
                ScrollView {
                    // A fixed column count (not .adaptive) so up/down move exactly one row.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: columns),
                              spacing: 28) {
                        ForEach(Array(ordered.enumerated()), id: \.element.id) { index, app in
                            Button {
                                focus = index
                                tapped(app)
                            } label: {
                                AppTile(client: client, app: app, isRunning: app.id == runningID,
                                        isFocused: gamepad.isActive && index == focusIndex)
                            }
                            .buttonStyle(.plain)
                            .id(app.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: focusIndex) {
                    if ordered.indices.contains(focusIndex) { withAnimation { scroller.scrollTo(ordered[focusIndex].id) } }
                }
            }
            .onChange(of: geometry.size.width, initial: true) { _, width in
                columns = max(1, Int((width - 32 + Self.spacing) / (Self.tileWidth + Self.spacing)))
            }
        }
        .overlay {
            if !isLoaded {
                ProgressView()
            } else if let loadError {
                ContentUnavailableView("Can't load games", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else if apps.isEmpty {
                ContentUnavailableView("No games", systemImage: "gamecontroller",
                                       description: Text("Add games to \(name) in Vibepollo's web UI."))
            }
        }
        .overlay {
            if let busy {
                ProgressView(busy).padding(24).background(.regularMaterial, in: .rect(cornerRadius: 16))
            }
        }
        .disabled(busy != nil)
        .navigationTitle(name)
        .refreshable { await load() }
        .task { await load() }
        .onGamepad { command in
            guard busy == nil else { return }
            switch command {
            case .up, .down, .left, .right:
                focus = FocusMove.next(focusIndex, count: ordered.count, columns: columns, command)
            case .select:
                if ordered.indices.contains(focusIndex) { tapped(ordered[focusIndex]) }
            case .menu:
                if ordered.indices.contains(focusIndex) { menu = gameMenu(ordered[focusIndex]) }
            case .back:
                dismiss()
            }
        }
        .actionMenu($menu)
        .navigationDestination(item: $stream) { target in StreamView(client: client, target: target) }
    }

    private func tapped(_ app: HostApp) {
        if runningID == 0 { launch(app) } else { menu = gameMenu(app) }
    }

    /// What can be done with `app` given what's running.
    private func gameMenu(_ app: HostApp) -> MenuSpec {
        if app.id == runningID {
            return MenuSpec(title: "\(app.title) is running", actions: [
                .init(title: "Resume") {
                    perform("Resuming \(app.title)…", streaming: app) {
                        try await client.resume(app, width: mode.width, height: mode.height, fps: fps)
                    }
                },
                .init(title: "Quit", isDestructive: true) {
                    perform("Quitting \(app.title)…") { try await client.quit(); return nil }
                },
            ])
        }
        if runningID != 0 {
            return MenuSpec(title: "Quit \(running?.title ?? "the running game") to launch \(app.title)?", actions: [
                .init(title: "Quit and Launch", isDestructive: true) {
                    perform("Launching \(app.title)…", streaming: app) {
                        try await client.quit()
                        return try await client.launch(app, width: mode.width, height: mode.height, fps: fps)
                    }
                },
            ])
        }
        return MenuSpec(title: app.title, actions: [.init(title: "Launch") { launch(app) }])
    }

    private func launch(_ app: HostApp) {
        perform("Launching \(app.title)…", streaming: app) {
            try await client.launch(app, width: mode.width, height: mode.height, fps: fps)
        }
    }

    /// Runs a host action behind a progress overlay, then re-checks which game is running. A launch or
    /// resume returns its session, and the stream screen opens for `streaming`.
    private func perform(_ label: String, streaming app: HostApp? = nil, _ action: @escaping () async throws -> LaunchSession?) {
        busy = label
        Task {
            do {
                if let launch = try await action(), let app {
                    stream = StreamTarget(title: app.title, launch: launch, width: mode.width, height: mode.height, fps: fps)
                }
            } catch {
                menu = .error(error.localizedDescription)
            }
            if let info = try? await client.serverInfo() { runningID = info.currentGame }
            busy = nil
        }
    }

    private func load() async {
        do {
            async let info = client.serverInfo()
            apps = try await client.apps()
            runningID = try await info.currentGame
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoaded = true
    }

    // shortcut: fixed 1080p60, Moonlight's default; a settings screen comes later. The iPad's native 2752x2064
    // produced no video from the host at all (audio worked), so odd sizes need checking before they're offered.
    private var fps: Int { 60 }
    private var mode: (width: Int, height: Int) { (1920, 1080) }
}

private struct AppTile: View {
    let client: HostClient
    let app: HostApp
    let isRunning: Bool
    let isFocused: Bool
    @State private var art: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.secondary.opacity(0.15)
                .aspectRatio(3 / 4, contentMode: .fit) // GameStream box art is portrait
                .overlay {
                    if let art {
                        Image(uiImage: art).resizable().scaledToFill()
                    } else {
                        Image(systemName: "gamecontroller").font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
                .clipShape(.rect(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if isRunning {
                        Label("Running", systemImage: "play.fill")
                            .font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.green, in: .capsule)
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                }
                .overlay {
                    if isRunning { RoundedRectangle(cornerRadius: 12).stroke(.green, lineWidth: 4) }
                }
                .focusRing(isFocused)
            Text(app.title).font(.subheadline).lineLimit(2)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isRunning ? "Running" : "")
        .task(id: app.artVersion) {
            if let png = try? await client.boxArt(for: app) { art = UIImage(data: png) }
        }
    }
}
