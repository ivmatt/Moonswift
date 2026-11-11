import SwiftUI

/// A paired PC's games as a box-art grid. Tapping a game launches it, or offers Resume/Quit if it's running.
struct AppLibraryView: View {
    let client: HostClient
    let name: String

    @State private var apps: [HostApp] = []
    @State private var runningID = 0 // 0 = nothing running
    @State private var loadError: String?
    @State private var isLoaded = false
    @State private var busy: String? // e.g. "Launching Hades…" while a request is in flight
    @State private var actionError: String?
    @State private var choosing: HostApp? // the game whose Resume/Quit dialog is open

    private var running: HostApp? { apps.first { $0.id == runningID } }
    /// The running game first, the rest in the host's order.
    private var ordered: [HostApp] { apps.filter { $0.id == runningID } + apps.filter { $0.id != runningID } }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 24)], spacing: 28) {
                ForEach(ordered) { app in
                    Button { tapped(app) } label: {
                        AppTile(client: client, app: app, isRunning: app.id == runningID)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
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
        // One centered alert, not a dialog per tile: per-item dialogs in a lazy grid showed the wrong game.
        .alert(choosing.map(dialogTitle) ?? "", isPresented: isPresented($choosing), presenting: choosing) { app in
            dialogActions(app)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Something went wrong", isPresented: isPresented($actionError)) {
            Button("OK") {}
        } message: {
            Text(actionError ?? "")
        }
    }

    @ViewBuilder private func dialogActions(_ app: HostApp) -> some View {
        if app.id == runningID {
            Button("Resume") { perform("Resuming \(app.title)…") { try await client.resume(app, width: mode.width, height: mode.height, fps: fps) } }
            Button("Quit", role: .destructive) { perform("Quitting \(app.title)…") { try await client.quit() } }
        } else {
            Button("Quit and Launch", role: .destructive) {
                perform("Launching \(app.title)…") {
                    try await client.quit()
                    try await client.launch(app, width: mode.width, height: mode.height, fps: fps)
                }
            }
        }
    }

    private func dialogTitle(_ app: HostApp) -> String {
        app.id == runningID ? "\(app.title) is running" : "Quit \(running?.title ?? "the running game") to launch \(app.title)?"
    }

    private func tapped(_ app: HostApp) {
        if runningID == 0 {
            perform("Launching \(app.title)…") { try await client.launch(app, width: mode.width, height: mode.height, fps: fps) }
        } else {
            choosing = app
        }
    }

    /// Runs a host action behind a progress overlay, then re-checks which game is running.
    private func perform(_ label: String, _ action: @escaping () async throws -> Void) {
        busy = label
        Task {
            do { try await action() } catch { actionError = error.localizedDescription }
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

    // shortcut: always asks for the screen's native resolution at 60 fps; becomes a setting with the streaming stage.
    private var fps: Int { 60 }
    private var mode: (width: Int, height: Int) {
        let size = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.nativeBounds.size
            ?? CGSize(width: 1920, height: 1080)
        return (Int(max(size.width, size.height)), Int(min(size.width, size.height))) // nativeBounds is portrait
    }

    private func isPresented<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding { value.wrappedValue != nil } set: { if !$0 { value.wrappedValue = nil } }
    }
}

private struct AppTile: View {
    let client: HostClient
    let app: HostApp
    let isRunning: Bool
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
