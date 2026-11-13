import SwiftData
import SwiftUI

@main struct MyApp: App {
    @State private var gamepad = GamepadInput()
    @State private var directory: PCDirectory
    @State private var catalog: GameCatalog
    @State private var launcher: StreamLauncher

    private var container: ModelContainer

    private static func makeContainer() -> ModelContainer {
        do { return try ModelContainer(for: SavedHost.self) } catch { fatalError("Can't open the saved hosts: \(error)") }
    }

    init() {
        let catalog = GameCatalog()
        let directory = PCDirectory()
        _directory = State(initialValue: directory)
        container = Self.makeContainer()
        #if DEBUG
        if DemoMode.isOn {
            container = DemoMode.container()
            DemoMode.seed(catalog, directory)
        }
        #endif
        _catalog = State(initialValue: catalog)
        _launcher = State(initialValue: StreamLauncher(catalog: catalog))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(gamepad)
                .environment(directory)
                .environment(catalog)
                .environment(launcher)
                .onAppear { gamepad.start() }
        }
        .modelContainer(container)
    }
}
