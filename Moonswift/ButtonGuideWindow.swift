import GameController
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
    /// A sheet's guide is showing rather than a tab's.
    private(set) var isSheetOnTop = false
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
        let sheetOnTop = entries.contains { $0.isOverTabs }
        if sheetOnTop != isSheetOnTop { isSheetOnTop = sheetOnTop }
    }
}

/// Draws the guide in its own window above the app's; touches pass through it.
enum ButtonGuideWindow {
    private static var window: UIWindow?

    static func install(center: ButtonGuideCenter, gamepad: GamepadInput, tabBar: TabBarMinimize, launcher: StreamLauncher) {
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
    static func refreshSystemOverlays() {
        window?.rootViewController?.setNeedsStatusBarAppearanceUpdate()
        window?.rootViewController?.setNeedsUpdateOfHomeIndicatorAutoHidden()
        window?.rootViewController?.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }

    /// A stream is playing (no menu or panel): a hardware mouse's pointer is locked to it on iPad, as in moonlight-ios.
    /// Moves still arrive through GCMouse (KeyboardMouseStreamer); a trackpad's tap to click doesn't while locked.
    static var locksPointer = false { didSet { if locksPointer != oldValue { refreshPointerLock() } } }

    static func refreshPointerLock() { window?.rootViewController?.setNeedsUpdateOfPrefersPointerLocked() }

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
        // Here rather than on the app's screen, which is SwiftUI's own controller. Only with a mouse: the lock turns
        // off UIKit's pointer events, which touch input still uses for a trackpad's taps.
        override var prefersPointerLocked: Bool { ButtonGuideWindow.locksPointer && !GCMouse.mice().isEmpty }
    }
}

/// An iPhone's guide: fixed at the bottom right with a shadow to stay readable over art. Takes no room from the page.
struct PhoneButtonGuide: View {
    let hints: [ButtonGuideCenter.Hint]
    let center: ButtonGuideCenter
    @Environment(GamepadInput.self) private var gamepad
    @AppStorage(SettingsKey.buttonGuide) private var mode = ButtonGuideMode.automatic

    // Tuned by eye.
    /// Where the safe area has no side inset (the Duo): this low, the hints need this much to clear the rounded corner.
    private static let minEdge: CGFloat = 32
    private static let bottomFromEdge: CGFloat = 8
    private static let bottomOverIndicator: CGFloat = 18 // the open Duo in landscape: its home indicator is under the hints
    private static let bottomOverTabBar: CGFloat = 6
    /// Clears a portrait tab bar, at one height so the guide doesn't move when the bar shrinks or hides.
    private static let tabBarClearance: CGFloat = 52

    var body: some View {
        let windowBottom = HomeView.windowBottomInset
        // The Duo folded: its side column, on either side, stays clear.
        let railLeading = center.pageLeading - center.pageTrailing >= 20 ? center.pageLeading : 0
        let railTrailing = center.pageTrailing - center.pageLeading >= 20 ? center.pageTrailing : 0
        // Pinned to the screen, not the page: Home's page runs past the screen on a landscape iPhone.
        GeometryReader { proxy in
            let page = proxy.frame(in: .global)
            let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
            let screen = window?.bounds.size ?? page.size
            // Inside the safe area; a side column already includes its inset.
            let leadingEdge = max((window?.safeAreaInsets.left ?? 0) - railLeading, Self.minEdge)
            let trailingEdge = max((window?.safeAreaInsets.right ?? 0) - railTrailing, Self.minEdge)
            // The Duo open: centered in portrait, left in landscape. Folded: opposite its side column. Other iPhones: right.
            let alignment: Alignment = screen.height > screen.width ? .bottom
                : !screen.isShort ? .bottomLeading
                : railTrailing > 0 ? .bottomLeading : .bottomTrailing
            // In landscape the guide stays put with the tab bar over it; a portrait bar never tucks away, so it's cleared.
            let clearance = center.isTabBarBelow && screen.height > screen.width ? Self.tabBarClearance : 0
            ZStack(alignment: alignment) {
                Color.clear
                if !hints.isEmpty, mode.isShown(controllerConnected: gamepad.isControllerConnected) {
                    ControllerHints(hints: hints)
                        // Twice: one soft shadow left light labels hard to read over bright art.
                        .shadow(color: .black.opacity(0.9), radius: 1, y: 1)
                        .shadow(color: .black.opacity(0.7), radius: 4)
                        .padding(.leading, leadingEdge)
                        .padding(.trailing, trailingEdge)
                        .padding(.bottom, clearance > 0 ? Self.bottomOverTabBar : screen.isShort ? Self.bottomFromEdge : Self.bottomOverIndicator)
                        .padding(.leading, railLeading)
                        .padding(.trailing, railTrailing)
                        .padding(.bottom, clearance > 0 ? windowBottom + clearance : 0)
                        .transition(.opacity)
                }
            }
            .frame(width: screen.width, height: screen.height)
            .offset(x: -page.minX, y: -page.minY)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

}

private struct ButtonGuideOverlay: View {
    let center: ButtonGuideCenter
    let tabBar: TabBarMinimize
    let launcher: StreamLauncher
    @Environment(GamepadInput.self) private var gamepad
    @AppStorage(SettingsKey.buttonGuide) private var mode = ButtonGuideMode.automatic

    var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .phone { phoneGuide } else { padGuide }
        }
        .onChange(of: launcher.stream == nil || launcher.isMinimized) {
            Task { // now, and again once the stream screen has finished sliding in or out
                ButtonGuideWindow.refreshSystemOverlays()
                try? await Task.sleep(for: .milliseconds(600))
                ButtonGuideWindow.refreshSystemOverlays()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: center.current.map(\.label))
    }

    /// Only a sheet's guide: a tab's is drawn in its page, under the tab bar (`ButtonGuidePlacement`).
    private var phoneGuide: some View {
        ZStack {
            Color.clear
            if center.isSheetOnTop, launcher.stream == nil, launcher.splash == nil {
                PhoneButtonGuide(hints: center.current, center: center)
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private var padGuide: some View {
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
    }
}
