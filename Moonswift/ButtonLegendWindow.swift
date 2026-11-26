import GameController
import SwiftUI
import UIKit

/// The one button legend on screen: the topmost screen's hints (a sheet's over its tab's), drawn in a window of its
/// own above everything, sheets included, so there's only ever one and it never moves with a page or a sheet. Screens
/// say what it shows with `buttonLegend(_:)`.
@Observable final class ButtonLegendCenter {
    typealias Hint = (buttons: [ControllerHints.Button], label: String)
    @ObservationIgnored private var entries: [(id: UUID, isOverTabs: Bool, hints: [Hint])] = []
    /// Sheets' frames on screen, by entry; kept apart as a frame can come before its entry.
    @ObservationIgnored private var frames: [UUID: CGRect] = [:]
    /// The topmost screen's hints: a sheet's over a tab's (whichever came on screen last; at launch a tab can after
    /// its sheet), then the newest.
    private(set) var current: [Hint] = []
    /// A sheet's legend is showing rather than a tab's.
    private(set) var isSheetOnTop = false
    /// The topmost sheet on screen, which the legend sits inside (a popup menu over it reports none).
    private(set) var sheetFrame: CGRect?
    /// The tab's page is fading out under the legend, which would fade the legend too if drawn in it: it's drawn in the
    /// legend's window meanwhile, in the same place.
    var fadedTab: UUID?
    var isTabFaded: Bool { fadedTab != nil }
    /// The tabs' tab bar runs along the bottom (iPhones other than the Duo): the legend goes to the top, or to the
    /// bottom while the tab bar is shrunk or hidden. Otherwise bottom left.
    var isTabBarBelow = false
    /// The legend's height, for pages to keep its room at the bottom.
    var height: CGFloat = 20
    /// The tab page's side insets (the Duo's side column on one side): with the column on the left, the legend centres
    /// in the room beside it.
    var pageLeading: CGFloat = 0
    var pageTrailing: CGFloat = 0

    func set(_ id: UUID, isOverTabs: Bool, _ hints: [Hint]) {
        if let index = entries.firstIndex(where: { $0.id == id }) { entries[index].hints = hints } else { entries.append((id, isOverTabs, hints)) }
        update()
    }

    func setFrame(_ id: UUID, _ frame: CGRect) {
        frames[id] = frame
        update()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        frames[id] = nil
        update()
    }

    private func update() {
        let hints = (entries.last { $0.isOverTabs } ?? entries.last)?.hints ?? []
        if hints.map(\.label) != current.map(\.label) { current = hints }
        let sheetOnTop = entries.contains { $0.isOverTabs }
        if sheetOnTop != isSheetOnTop { isSheetOnTop = sheetOnTop }
        let frame = entries.last { $0.isOverTabs && frames[$0.id] != nil }.flatMap { frames[$0.id] }
        if frame != sheetFrame { sheetFrame = frame }
    }
}

/// Draws the legend in its own window above the app's; touches pass through it.
enum ButtonLegendWindow {
    private static var window: UIWindow?

    static func install(center: ButtonLegendCenter, gamepad: GamepadInput, launcher: StreamLauncher) {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let window = PassthroughWindow(windowScene: scene)
        let host = LegendHostingController(rootView: ButtonLegendOverlay(center: center, launcher: launcher)
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

    private final class LegendHostingController<Content: View>: UIHostingController<Content> {
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
        override var prefersPointerLocked: Bool { ButtonLegendWindow.locksPointer && !GCMouse.mice().isEmpty }
    }
}

/// The legend: fixed in a bottom corner with a shadow to stay readable over art. Pages fade out above it (`LegendBacking`).
struct FixedButtonLegend: View {
    let hints: [ButtonLegendCenter.Hint]
    let center: ButtonLegendCenter
    /// The sheet it sits inside, on screen; nil for the screen itself.
    var sheet: CGRect? = nil
    @Environment(GamepadInput.self) private var gamepad
    @AppStorage(SettingsKey.buttonLegend) private var mode = ButtonLegendMode.automatic

    /// The pages' content inset from the safe area.
    /// shortcut: the same 36 as HeroCard's inset, kept in step by hand; share one constant if a third place needs it.
    private static let pageInset: CGFloat = 36
    // Tuned by eye.
    private static let bottomFromEdge: CGFloat = 8
    private static let bottomOverIndicator: CGFloat = 18 // iPad and the open Duo in landscape: the home indicator is under the hints
    /// Inside a sheet that ends above the screen's bottom (iPad): up from its edge, clear of its rounded corners.
    static let bottomInSheet: CGFloat = 18
    private static let bottomOverTabBar: CGFloat = 6
    /// Clears a portrait tab bar, at one height so the legend doesn't move when the bar shrinks or hides.
    private static let tabBarClearance: CGFloat = 52

    var body: some View {
        let windowBottom = HomeView.windowBottomInset
        // The Duo folded: its side column, on either side, stays clear (a sheet already covers it).
        let railLeading = sheet == nil && center.pageLeading - center.pageTrailing >= 20 ? center.pageLeading : 0
        let railTrailing = sheet == nil && center.pageTrailing - center.pageLeading >= 20 ? center.pageTrailing : 0
        // Pinned to the screen, not the page: Home's page runs past the screen on a landscape iPhone.
        GeometryReader { proxy in
            let page = proxy.frame(in: .global)
            let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
            let screen = window?.bounds.size ?? page.size
            // The screen, or the sheet on top, with the screen's safe area.
            let box = sheet ?? CGRect(origin: .zero, size: screen)
            let left = max(box.minX, (window?.safeAreaInsets.left ?? 0) - railLeading)
            let right = max(screen.width - box.maxX, (window?.safeAreaInsets.right ?? 0) - railTrailing)
            // A page's frame stops at the safe area: floating only if it ends above the home indicator's room too.
            let isFloating = box.maxY < screen.height - windowBottom - 1
            // In line with the pages' content: their 36-point inset (a side column already includes its inset). Also
            // clears the screen's and a sheet's rounded corners.
            let leadingEdge = left + Self.pageInset
            let trailingEdge = right + Self.pageInset
            // iPad and the Duo open: left in landscape, centered in portrait. Folded: opposite its side column. iPhones: right.
            let alignment: Alignment = screen.height > screen.width ? .bottom
                : !screen.isShort ? .bottomLeading
                : railTrailing > 0 ? .bottomLeading : .bottomTrailing
            // In landscape the legend stays put with the tab bar over it; a portrait bar never tucks away, so it's cleared.
            let clearance = center.isTabBarBelow && screen.height > screen.width ? Self.tabBarClearance : 0
            ZStack(alignment: alignment) {
                Color.clear
                if !hints.isEmpty, mode.isShown(controllerConnected: gamepad.isControllerConnected) {
                    ControllerHints(hints: hints)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if $0 > 0, center.height != $0 { center.height = $0 } }
                        // Twice: one soft shadow left light labels hard to read over bright art.
                        .shadow(color: .black.opacity(0.9), radius: 1, y: 1)
                        .shadow(color: .black.opacity(0.7), radius: 4)
                        .padding(.leading, leadingEdge)
                        .padding(.trailing, trailingEdge)
                        .padding(.bottom, clearance > 0 ? Self.bottomOverTabBar : isFloating ? screen.height - box.maxY + Self.bottomInSheet : Self.bottom(screen))
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

    /// From the screen's bottom edge to the hints, without a tab bar to clear.
    static func bottom(_ screen: CGSize) -> CGFloat { screen.isShort ? bottomFromEdge : bottomOverIndicator }
    /// The hints' top, from the screen's bottom edge: where room kept for them starts.
    static func top(_ center: ButtonLegendCenter?) -> CGFloat {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        return bottom(window?.bounds.size ?? .zero) + (center?.height ?? 20)
    }
}

private struct ButtonLegendOverlay: View {
    let center: ButtonLegendCenter
    let launcher: StreamLauncher
    @Environment(GamepadInput.self) private var gamepad
    @AppStorage(SettingsKey.buttonLegend) private var mode = ButtonLegendMode.automatic

    var body: some View {
        ZStack {
            Color.clear
            // A sheet's legend, or a faded tab's: a tab's is otherwise drawn in its page, under the tab bar
            // (`ButtonLegendPlacement`).
            if center.isSheetOnTop || center.isTabFaded, launcher.stream == nil, launcher.splash == nil {
                FixedButtonLegend(hints: center.current, center: center, sheet: center.isSheetOnTop ? center.sheetFrame : nil)
            }
        }
        .ignoresSafeArea()
        .onChange(of: launcher.stream == nil || launcher.isMinimized) {
            Task { // now, and again once the stream screen has finished sliding in or out
                ButtonLegendWindow.refreshSystemOverlays()
                try? await Task.sleep(for: .milliseconds(600))
                ButtonLegendWindow.refreshSystemOverlays()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: center.current.map(\.label))
    }
}
