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
        // The selected tab in white (black in light mode) rather than blue. Set on the tab bar itself: a SwiftUI
        // tint on the TabView also reached the sliders, switches and menus inside the tabs.
        // The iPad's floating tab bar ignores this: RootView tints it.
        let tabs = UITabBarAppearance()
        for item in [tabs.stackedLayoutAppearance, tabs.inlineLayoutAppearance, tabs.compactInlineLayoutAppearance] {
            item.selected.iconColor = .label
            item.selected.titleTextAttributes = [.foregroundColor: UIColor.label]
            item.normal.iconColor = .label.withAlphaComponent(0.6) // the others dimmed, like Apple's Games app
            item.normal.titleTextAttributes = [.foregroundColor: UIColor.label.withAlphaComponent(0.6)]
        }
        UITabBar.appearance().standardAppearance = tabs
        UITabBar.appearance().scrollEdgeAppearance = tabs
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
