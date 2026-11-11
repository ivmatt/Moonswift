import SwiftData
import SwiftUI

@main struct MyApp: App {
    @State private var gamepad = GamepadInput()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(gamepad)
                .onAppear { gamepad.start() }
        }
        .modelContainer(for: SavedHost.self)
    }
}
