#if DEBUG
import SwiftData
import SwiftUI

// Xcode's canvas previews of every tab, with the demo PC and its games (see DemoMode), with and without a controller.
// Pick the iPhone Duo (or iPad) in the canvas's device menu; the colour scheme follows the canvas's settings. Edits show
// here within a second or two, without building or installing.

/// The app's shared models, as MyApp makes them in demo mode.
private final class PreviewModels {
    let gamepad = GamepadInput()
    let directory = PCDirectory()
    let catalog = GameCatalog()
    let launcher: StreamLauncher
    let container = DemoMode.container()

    init(controller: Bool) {
        launcher = StreamLauncher(catalog: catalog)
        DemoMode.seed(catalog, directory)
        gamepad.preview(controller: controller)
    }
}

private extension View {
    func previewModels(controller: Bool) -> some View {
        let models = PreviewModels(controller: controller)
        return environment(models.gamepad)
            .environment(models.directory)
            .environment(models.catalog)
            .environment(models.launcher)
            .modelContainer(models.container)
    }
}

#Preview("Home", traits: .landscapeLeft) { RootView(startingTab: .home).previewModels(controller: false) }
#Preview("Home, controller", traits: .landscapeLeft) { RootView(startingTab: .home).previewModels(controller: true) }
#Preview("Library", traits: .landscapeLeft) { RootView(startingTab: .library).previewModels(controller: false) }
#Preview("Library, controller", traits: .landscapeLeft) { RootView(startingTab: .library).previewModels(controller: true) }
#Preview("Hosts", traits: .landscapeLeft) { RootView(startingTab: .pcs).previewModels(controller: false) }
#Preview("Settings", traits: .landscapeLeft) { SettingsView().previewModels(controller: false) }
#endif
