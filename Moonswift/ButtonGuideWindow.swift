import SwiftUI
import UIKit

/// The one button guide on screen: the topmost screen's hints (a sheet's over its tab's), drawn in a window of its
/// own above everything, sheets included, so there's only ever one and it never moves with a page or a sheet. Screens
/// say what it shows with `buttonGuide(_:)`.
@Observable final class ButtonGuideCenter {
    typealias Hint = (buttons: [ControllerHints.Button], label: String)
    @ObservationIgnored private var entries: [(id: UUID, isOverTabs: Bool, hints: [Hint])] = []
    /// The topmost screen's hints: a sheet's over a tab's (whichever came on screen last; at launch a tab can after
    /// its sheet), then the newest.
    private(set) var current: [Hint] = []
    /// The tabs' tab bar runs along the bottom (iPhones other than the Duo): the guide goes to the top, or to the
    /// bottom while the tab bar is shrunk or hidden. Otherwise bottom left.
    var isTabBarBelow = false
    /// The guide's height, for pages to keep its room at the bottom.
    var height: CGFloat = 34
    /// The tab page's side insets (the Duo's side column on one side): with the column on the left, the guide centres
    /// in the room beside it.
    var pageLeading: CGFloat = 0
    var pageTrailing: CGFloat = 0

    func set(_ id: UUID, isOverTabs: Bool, _ hints: [Hint]) {
        if let index = entries.firstIndex(where: { $0.id == id }) { entries[index].hints = hints } else { entries.append((id, isOverTabs, hints)) }
        update()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        update()
    }

    private func update() {
        let hints = (entries.last { $0.isOverTabs } ?? entries.last)?.hints ?? []
        if hints.map(\.label) != current.map(\.label) { current = hints }
    }
}

/// Draws the guide in its own window above the app's; touches pass through it.
enum ButtonGuideWindow {
    private static var window: UIWindow?

    @MainActor static func install(center: ButtonGuideCenter, gamepad: GamepadInput, tabBar: TabBarMinimize, launcher: StreamLauncher) {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let window = PassthroughWindow(windowScene: scene)
        let host = GuideHostingController(rootView: ButtonGuideOverlay(center: center, tabBar: tabBar, launcher: launcher)
            .environment(gamepad))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.windowLevel = .alert + 1 // above sheets and menus
        window.isHidden = false // shown, but never the key window: the app keeps the keyboard and focus
        self.window = window
    }

    /// The status bar and home indicator follow the app's screen on top (hidden during a stream), not this window,
    /// which, being the topmost, iOS asks instead: the status bar showed over games.
    @MainActor static func refreshSystemOverlays() {
        window?.rootViewController?.setNeedsStatusBarAppearanceUpdate()
        window?.rootViewController?.setNeedsUpdateOfHomeIndicatorAutoHidden()
        window?.rootViewController?.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }

    private final class PassthroughWindow: UIWindow {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }

    private final class GuideHostingController<Content: View>: UIHostingController<Content> {
        /// The app's own topmost screen: the main window's root, or what it presents (the stream).
        private var appScreen: UIViewController? {
            var screen = view.window?.windowScene?.windows.first { !($0 is PassthroughWindow) }?.rootViewController
            while let presented = screen?.presentedViewController, !presented.isBeingDismissed { screen = presented }
            return screen
        }
        override var childForStatusBarHidden: UIViewController? { appScreen }
        override var childForStatusBarStyle: UIViewController? { appScreen }
        override var childForHomeIndicatorAutoHidden: UIViewController? { appScreen }
        override var childForScreenEdgesDeferringSystemGestures: UIViewController? { appScreen }
    }
}

private struct ButtonGuideOverlay: View {
    let center: ButtonGuideCenter
    let tabBar: TabBarMinimize
    let launcher: StreamLauncher

    var body: some View {
        let movesToTop = center.isTabBarBelow
        let isAtBottom = !movesToTop || tabBar.isMinimized || tabBar.isHidden
        // The Duo folded, curved side up: its side column is on the left, where the guide would start.
        let isRailOnLeft = !movesToTop && UIDevice.current.userInterfaceIdiom != .pad && center.pageLeading - center.pageTrailing >= 20
        ZStack(alignment: movesToTop || isRailOnLeft ? (isAtBottom ? .bottom : .top) : .bottomLeading) {
            Color.clear
            if launcher.stream == nil, launcher.splash == nil { // not over a game or its splash
                ControllerHints(hints: center.current)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if $0 > 0 { center.height = $0 } }
                    // Bottom left 36 points in, in line with the pages' content and just into the margin above the
                    // home indicator; on iPhone on the title's line (TabTitle: 23 points down, 48 tall), or level
                    // with the shrunk tab bar.
                    .padding(.leading, movesToTop ? 0 : isRailOnLeft ? center.pageLeading : HomeView.windowLeadingInset + 36)
                    .padding(.trailing, isRailOnLeft ? center.pageTrailing : 0)
                    .padding(.top, movesToTop && !isAtBottom ? HomeView.titleTop(HomeView.windowTopInset) + 8 : 0)
                    .padding(.bottom, !isAtBottom ? 0 : movesToTop ? HomeView.windowBottomInset + 6 : HomeView.windowBottomInset - 4)
                    .id(isAtBottom) // fades out of one place and into the other
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.25), value: isAtBottom)
        .onChange(of: launcher.stream == nil || launcher.isMinimized) {
            Task { // now, and again once the stream screen has finished sliding in or out
                ButtonGuideWindow.refreshSystemOverlays()
                try? await Task.sleep(for: .milliseconds(600))
                ButtonGuideWindow.refreshSystemOverlays()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: center.current.map(\.label))
    }
}
