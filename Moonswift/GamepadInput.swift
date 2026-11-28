import GameController
import SwiftUI

/// What a controller (or keyboard) asks the UI to do.
nonisolated enum GamepadCommand: Equatable, Sendable {
    case up, down, left, right
    case select // A, Return
    case back // B, Esc
    case menu // Y (triangle), Space
    case alternate // X (square): a screen's second action, like Quit in the game list
    case streamMenu // Menu + View pressed together: the in-stream menu, since every other button goes to the game
    case settings // Menu (≡ / Options) pressed: open Settings from the home screen or a game list
    case options // View (⧉ / Create) pressed: a screen's extra options, like the game list's Sort & Search
    case previousTab, nextTab // L1, R1: switch between a screen's tabs or filters
}

/// iPadOS doesn't move UI focus with a game controller (only tvOS and visionOS do), so the app reads the
/// controller itself and hands commands to whichever screen is on top. The screen draws its own highlight.
@Observable final class GamepadInput {
    /// True once a controller or keyboard has been used; the focus highlight only shows then.
    private(set) var isActive = false
    /// A game controller is connected now: screens show the button legend and make room for it.
    private(set) var isControllerConnected = false

    @ObservationIgnored private var handlers: [(id: UUID, handle: (GamepadCommand) -> Void)] = []
    /// While streaming, the keyboard goes to the game instead of the menus (there can only be one handler).
    @ObservationIgnored var keyboardOverride: ((GCKeyCode, Bool) -> Void)?
    @ObservationIgnored private var dpad = HeldDirection()
    @ObservationIgnored private var stick = HeldDirection()
    @ObservationIgnored private var held: GamepadCommand?
    @ObservationIgnored private var repeatTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var comboButtons: Set<String> = []

    func start() {
        guard observers.isEmpty else { return }
        for name in [Notification.Name.GCControllerDidConnect, .GCKeyboardDidConnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.attachAll() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateConnected() }
        })
        #if DEBUG
        // What the old Developer setting saved; the launch argument (`-MoonswiftController`) still applies.
        UserDefaults.standard.removeObject(forKey: Self.debugControllerKey)
        #endif
        attachAll()
    }

    /// The last controller gone: back to touch, so the legend and focus highlights go too.
    private func updateConnected() {
        #if DEBUG
        if let fake = Self.fakeController {
            guard fake != isControllerConnected else { return }
            return withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
                isControllerConnected = fake
                isActive = fake
            }
        }
        #endif
        let isConnected = GCController.controllers().contains { $0.extendedGamepad != nil }
        withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
            isControllerConnected = isConnected
            if !isConnected { isActive = false }
        }
    }

    #if DEBUG
    /// For previews: as if a controller were connected (and in use) or not.
    func preview(controller: Bool) {
        isControllerConnected = controller
        isActive = controller
    }

    /// Launching with `-MoonswiftController YES` or `NO` acts as if a
    /// controller were or weren't connected, whatever is, to check screens' layout both ways on the simulator.
    static let debugControllerKey = "MoonswiftController"

    static var fakeController: Bool? {
        switch UserDefaults.standard.string(forKey: debugControllerKey) {
        case "YES": true
        case "NO": false
        default: nil
        }
    }
    #endif

    // MARK: Screens

    /// The newest registration gets the commands, so only the screen on top reacts.
    func register(_ id: UUID, _ handle: @escaping (GamepadCommand) -> Void) {
        handlers.removeAll { $0.id == id }
        handlers.append((id, handle))
    }

    /// Keeps a registered handler's closure current without changing the order.
    func refresh(_ id: UUID, _ handle: @escaping (GamepadCommand) -> Void) {
        if let index = handlers.firstIndex(where: { $0.id == id }) { handlers[index].handle = handle }
    }

    func unregister(_ id: UUID) {
        handlers.removeAll { $0.id == id }
    }

    // MARK: Input

    private func attachAll() {
        updateConnected()
        // Handlers run on each controller's handlerQueue, which is the main queue by default.
        for controller in GCController.controllers() {
            guard let pad = controller.extendedGamepad else { continue }
            pad.dpad.valueChangedHandler = { [weak self] _, x, y in
                MainActor.assumeIsolated { self?.hold(dpad: x, y) }
            }
            pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
                MainActor.assumeIsolated { self?.hold(stick: x, y) }
            }
            // Through the button remap, so a swapped A and B also swap confirm and back in the menus.
            let buttons: [(GCControllerButtonInput, GameButton)] =
                [(pad.buttonA, .a), (pad.buttonB, .b), (pad.buttonX, .x), (pad.buttonY, .y),
                 (pad.leftShoulder, .leftShoulder), (pad.rightShoulder, .rightShoulder)]
            for (button, physical) in buttons {
                button.pressedChangedHandler = { [weak self] _, _, pressed in
                    guard pressed else { return }
                    MainActor.assumeIsolated {
                        if let command = Self.command(for: ButtonRemap.current.target(physical)) { self?.send(command) }
                    }
                }
            }
            let combo: [(GCControllerButtonInput?, String)] = [(pad.buttonMenu, "menu"), (pad.buttonOptions, "view")]
            for (button, name) in combo {
                button?.pressedChangedHandler = { [weak self] _, _, pressed in
                    MainActor.assumeIsolated { self?.combo(name, pressed: pressed) }
                }
            }
        }
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = { [weak self] _, _, key, pressed in
            MainActor.assumeIsolated { self?.key(key, pressed: pressed) }
        }
    }

    /// Menu + View down together sends .streamMenu at once (the game sees both pressed only for that moment: the menu
    /// pauses input, which releases them on the PC).
    private func combo(_ button: String, pressed: Bool) {
        if pressed { send(button == "menu" ? .settings : .options) }
        if pressed { comboButtons.insert(button) } else { comboButtons.remove(button) }
        if pressed, comboButtons.count == 2 { send(.streamMenu) }
    }

    /// What each button means in the app's menus.
    nonisolated static func command(for button: GameButton) -> GamepadCommand? {
        switch button {
        case .a: .select
        case .b: .back
        case .x: .alternate
        case .y: .menu
        case .leftShoulder: .previousTab
        case .rightShoulder: .nextTab
        default: nil
        }
    }

    private func hold(dpad x: Float, _ y: Float) { setHeld(dpad.update(x: x, y: y)) }
    private func hold(stick x: Float, _ y: Float) { setHeld(stick.update(x: x, y: y)) }

    private func key(_ key: GCKeyCode, pressed: Bool) {
        if let keyboardOverride {
            keyboardOverride(key, pressed)
            return
        }
        let arrows: [GCKeyCode: GamepadCommand] = [.upArrow: .up, .downArrow: .down, .leftArrow: .left, .rightArrow: .right]
        if let direction = arrows[key] {
            setHeld(pressed ? direction : nil)
        } else if pressed {
            switch key {
            case .returnOrEnter: send(.select)
            case .escape: send(.back)
            case .spacebar: send(.menu)
            default: break
            }
        }
    }

    /// Fires once, then repeats while held, like a console menu: after 0.4s, then every 0.12s.
    private func setHeld(_ direction: GamepadCommand?) {
        guard direction != held else { return }
        held = direction
        repeatTask?.cancel()
        guard let direction else { return }
        send(direction)
        repeatTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.4))
            while !Task.isCancelled {
                self?.send(direction)
                try? await Task.sleep(for: .seconds(0.12))
            }
        }
    }

    /// The screen was touched: back to touch mode, so no controller highlight lingers (it returns with the next press).
    func touched() {
        if isActive { isActive = false }
    }

    private func send(_ command: GamepadCommand) {
        isActive = true
        handlers.last?.handle(command)
    }
}

/// Turns an analog stick (or a D-pad's -1...1 values) into a held direction. Engages past 0.5 and only
/// releases below 0.3, so a stick resting near the threshold doesn't flicker between held and released.
nonisolated struct HeldDirection {
    private(set) var current: GamepadCommand?

    mutating func update(x: Float, y: Float) -> GamepadCommand? {
        if let held = current {
            if Self.component(of: held, x: x, y: y) >= 0.3 { return held }
            current = nil
        }
        if max(abs(x), abs(y)) > 0.5 {
            current = abs(x) > abs(y) ? (x > 0 ? .right : .left) : (y > 0 ? .up : .down)
        }
        return current
    }

    private static func component(of direction: GamepadCommand, x: Float, y: Float) -> Float {
        switch direction {
        case .up: y
        case .down: -y
        case .right: x
        case .left: -x
        default: 0
        }
    }
}

/// Where focus goes in a grid of `count` items laid out `columns` wide (a list is one column).
nonisolated enum FocusMove {
    static func next(_ index: Int, count: Int, columns: Int, _ command: GamepadCommand) -> Int {
        guard count > 0 else { return 0 }
        let index = min(max(index, 0), count - 1)
        let columns = max(columns, 1)
        switch command {
        case .left where index % columns > 0:
            return index - 1
        case .right where index % columns < columns - 1 && index + 1 < count:
            return index + 1
        case .up where index >= columns:
            return index - columns
        case .down where index + columns < count:
            return index + columns
        case .down where index / columns < (count - 1) / columns:
            return count - 1 // the row below is partial: land on its last item
        default:
            return index
        }
    }
}

extension View {
    /// Sends controller commands to `handle` while this view is on screen, `isActive`, and nothing newer is. Turning
    /// `isActive` off hands the controller back at once, for a view still animating away.
    func onGamepad(isActive: Bool = true, _ handle: @escaping (GamepadCommand) -> Void) -> some View {
        modifier(GamepadHandler(isActive: isActive, handle: handle))
    }

    /// A list row's controller highlight: the same white ring as everywhere else, drawn inside the row (a list clips
    /// anything outside it), over the row's usual background.
    func focusedRowBackground(_ isOn: Bool) -> some View {
        listRowBackground(
            Color(.secondarySystemGroupedBackground).overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.primary, lineWidth: 2)
                    .padding(3)
                    .opacity(isOn ? 1 : 0)
                    .animation(.snappy(duration: 0.15), value: isOn)
            }
        )
    }

    /// A page's main action (Continue, Connect, Done): filled blue glass, headline text. Blue even under a page's
    /// white tint, which made it white on white. Secondary actions are `.glass` (white), destructive ones red.
    func primaryButton() -> some View {
        buttonStyle(.glassProminent).tint(.blue).font(.headline)
    }

    /// The controller focus highlight: slightly bigger, a thin ring (white in dark mode, black in light) an even gap outside the shape, and a shadow.
    /// `cornerRadius` is the shape's own; `.infinity` for a capsule. `scale`: how much bigger; less for something wide.
    func focusRing(_ isOn: Bool, cornerRadius: CGFloat = 12, scale: CGFloat = 1.05) -> some View {
        let gap: CGFloat = 3, line: CGFloat = 2
        return self
            .overlay {
                // Concentric: the ring's radius grows by exactly how far out it sits, so it follows the shape.
                RoundedRectangle(cornerRadius: cornerRadius + gap + line)
                    .strokeBorder(.primary, lineWidth: line) // white in dark mode, black in light
                    .padding(-(gap + line))
                    .opacity(isOn ? 1 : 0)
            }
            .scaleEffect(isOn && !UIAccessibility.isReduceMotionEnabled ? scale : 1)
            .shadow(color: .black.opacity(isOn ? 0.3 : 0), radius: 12, y: 6)
            .zIndex(isOn ? 1 : 0)
            .animation(.snappy(duration: 0.15), value: isOn)
    }
}

private struct GamepadHandler: ViewModifier {
    @Environment(GamepadInput.self) private var gamepad
    @State private var id = UUID()
    let isActive: Bool
    let handle: (GamepadCommand) -> Void

    func body(content: Content) -> some View {
        let _ = gamepad.refresh(id, handle) // the closure captured at onAppear would see stale non-State values
        content
            .onAppear { if isActive { gamepad.register(id, handle) } }
            .onDisappear { gamepad.unregister(id) }
            .onChange(of: isActive) { if isActive { gamepad.register(id, handle) } else { gamepad.unregister(id) } }
    }
}

/// Settings → Controller → Button Legend.
nonisolated enum ButtonLegendMode: String, CaseIterable {
    case automatic = "Automatic", show = "Show", hide = "Hide"

    /// Automatic: while a controller is connected.
    func isShown(controllerConnected: Bool) -> Bool {
        switch self {
        case .automatic: controllerConnected
        case .show: true
        case .hide: false
        }
    }
}

extension View {
    /// The page's button legend, placed the same on every tab. With the tab bar beside or above (the Duo, iPad): bottom
    /// left, in line with the content 36 points in. With it along the bottom (iPhone): at the top, on the title's line;
    /// while the tab bar is shrunk to its corner, in the room it left at the bottom.
    /// `reportsLayout`: a tab's page, which says where the tab bar is; false for a sheet's, whose legend shows over its
    /// tab's.
    func buttonLegend(_ hints: [(buttons: [ControllerHints.Button], label: String)], reportsLayout: Bool = true, backs: Bool = true) -> some View {
        modifier(ButtonLegendPlacement(hints: hints, reportsLayout: reportsLayout, backs: backs))
    }

    /// Whether the tab bar runs along the bottom, from this page's bottom inset, not counting the keyboard's: its height
    /// read as a tab bar, so the Duo and iPad were taken for iPhones (the legend went to the top, the tab bar was hidden,
    /// and both stayed so).
    /// shortcut: iOS doesn't say where its tab bar is; a bottom inset of 40 to 150 points is one, taller is a keyboard.
    /// A hardware keyboard's slim bar on an iPhone could pass for one. Revisit if the system says.
    func onTabBarBelowChange(_ action: @escaping (Bool) -> Void) -> some View { modifier(TabBarBelowWatch(action: action)) }

    /// Hides the tab bar along the bottom (iPhone) while `hide` holds, such as Library's search or a controller below
    /// a page's first row; the button legend takes its place. The Duo's rail and iPad's bar stay.
    func hidesTabBarOnPhone(_ hide: Bool) -> some View { modifier(PhoneTabBarHiding(hide: hide)) }
}

private struct TabBarBelowWatch: ViewModifier {
    let action: (Bool) -> Void

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottom in
            // An on-screen keyboard is taller than any tab bar: while one is up, the last answer stands. (Watching the
            // keyboard's notifications came too late: the inset had already changed.)
            guard bottom < 150 else { return }
            action(UIDevice.current.userInterfaceIdiom != .pad && bottom > 40) // iPad's tab bar is never along the bottom
        }
    }
}

private struct PhoneTabBarHiding: ViewModifier {
    let hide: Bool
    /// Measured only while the bar shows: hidden, the bottom inset no longer says where it was.
    @State private var isTabBarBelow = false
    @Environment(TabBarMinimize.self) private var tabBar: TabBarMinimize?

    func body(content: Content) -> some View {
        let hidden = hide && isTabBarBelow
        content
            .toolbar(hidden ? .hidden : .automatic, for: .tabBar)
            .animation(.snappy, value: hidden)
            .onChange(of: hidden, initial: true) { tabBar?.isHidden = hidden }
            .onDisappear { if hidden { tabBar?.isHidden = false } }
            .onTabBarBelowChange { if !hidden { isTabBarBelow = $0 } }
    }
}

/// The tab bar's state where pages set it, for the legend's placement.
@Observable final class TabBarMinimize {
    /// A page has hidden it (`hidesTabBarOnPhone`).
    var isHidden = false
    /// Home has tucked it away (an iPhone in landscape): the legend stays where it was, as the bar will be back.
    var isAway = false
}

private struct ButtonLegendPlacement: ViewModifier {
    let hints: [(buttons: [ControllerHints.Button], label: String)]
    let reportsLayout: Bool
    /// Whether the page fades out above the legend. Home doesn't: its art is full bleed, and it makes its own room.
    let backs: Bool
    @State private var id = UUID()
    @Environment(ButtonLegendCenter.self) private var center: ButtonLegendCenter?
    @Environment(TabBarMinimize.self) private var tabBar: TabBarMinimize?
    @Environment(GamepadInput.self) private var gamepad
    @AppStorage(SettingsKey.buttonLegend) private var mode = SettingsDefault.buttonLegend

    func body(content: Content) -> some View {
        let shows = mode.isShown(controllerConnected: gamepad.isControllerConnected) && !hints.isEmpty
        content
            .modifier(LegendBacking(isOn: shows && backs, isTab: reportsLayout, center: center))
            // iPad's Home: room at the bottom for the legend, with no spacing of the system's own: the covers end the
            // same 28 points above it as Play is above them. (An iPhone's Home lifts its content instead.)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if shows, !backs, UIDevice.current.userInterfaceIdiom == .pad { Color.clear.frame(height: max(0, FixedButtonLegend.top(center) - HomeView.windowBottomInset)) }
            }
            .onTabBarBelowChange { if reportsLayout, !(tabBar?.isHidden ?? false), !(tabBar?.isAway ?? false) { center?.isTabBarBelow = $0 } }
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets in
                guard reportsLayout else { return }
                center?.pageLeading = insets.leading
                center?.pageTrailing = insets.trailing
            }
            // A sheet's frame, for the legend to sit inside it. Not a popup menu's (`backs` false).
            // Measured past the side safe area: a page declared inside a sheet (Getting Started's) is inset by it, and
            // on the folded Duo its evened-out insets put the legend ~83 points left of every other screen's.
            .background {
                Color.clear
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        if !reportsLayout, backs { center?.setFrame(id, frame) }
                    }
                    .ignoresSafeArea(.container, edges: .horizontal)
            }
            .onAppear {
                center?.set(id, isOverTabs: !reportsLayout, hints)
                if reportsLayout { ButtonLegendWindow.installTabLayer() }
            }
            .onDisappear { center?.remove(id) }
            .onChange(of: hints.map(\.label)) { center?.set(id, isOverTabs: !reportsLayout, hints) }
    }
}

/// Keeps a page's content out from under the legend without moving the legend: content fades out behind and above the
/// hints, and scrolling content gets room to end above them. On whatever the tab bar does: the tabs' legend is drawn
/// outside the pages, so the bar can cover it either way.
private struct LegendBacking: ViewModifier {
    let isOn: Bool
    /// A tab's page; a sheet's otherwise.
    let isTab: Bool
    let center: ButtonLegendCenter?

    /// Between the hints and content above them: the same 28 points as Home's between Play and its covers.
    private static let gap: CGFloat = 28
    /// The fade runs from the hints' bottom, where nothing shows, to this far above their top.
    private static let fadeAbove: CGFloat = 32
    /// The page ends above the screen's bottom: a floating sheet (iPad), which the legend sits inside.
    @State private var isFloating = false

    func body(content: Content) -> some View {
        // The hints' top, from the page's bottom edge.
        let hintsTop = isFloating ? FixedButtonLegend.bottomInSheet + (center?.height ?? 20) : FixedButtonLegend.top(center)
        content
            // Scrolled to the end, the last row stops above the fade. Added to the safe area, which keeps the home
            // indicator's room (a floating sheet has none).
            .safeAreaPadding(.bottom, isOn ? max(0, hintsTop + Self.gap - (isFloating ? 0 : HomeView.windowBottomInset)) : 0)
            // From the page's frame, not its safe area, which includes the padding above.
            .onGeometryChange(for: Bool.self) { proxy in
                let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.bounds.height ?? 0
                return screen - proxy.frame(in: .global).maxY > HomeView.windowBottomInset + 1 // past the safe area's edge
            } action: { isFloating = $0 && !isTab } // only a sheet floats: a tab's page on iPhone measured as one
            // In UIKit, on the page's own view: a SwiftUI mask or compositing group re-hosts a List, which then loses
            // its side margins (Settings' rows widened 8 points).
            .background {
                let hints = center?.height ?? 20
                PageFade(fade: isOn ? hints + Self.fadeAbove : 0, clear: isOn ? hintsTop - hints : 0)
            }
    }
}

/// Fades out the bottom of the page this sits in (its view controller's view): `clear` points up from its bottom show
/// nothing, then the page fades in over `fade` points.
private struct PageFade: UIViewRepresentable {
    let fade: CGFloat
    let clear: CGFloat

    func makeUIView(context: Context) -> FadeView { FadeView() }

    func updateUIView(_ view: FadeView, context: Context) {
        view.fade = fade
        view.clear = clear
        view.setNeedsLayout()
    }

    final class FadeView: UIView {
        var fade: CGFloat = 0
        var clear: CGFloat = 0
        private let gradient = CAGradientLayer()
        private weak var page: UIView?

        // Gone with its page's legend (a sheet closing): the page shows whole again.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil, let page, page.layer.mask === gradient { page.layer.mask = nil }
            // Back with it (a tab shown again): mask again, as SwiftUI won't call for an update when nothing changed.
            if window != nil { setNeedsLayout() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            var responder: UIResponder? = self
            while let next = responder, !(next is UIViewController) { responder = next.next }
            guard let page = (responder as? UIViewController)?.view else { return }
            self.page = page
            guard fade > 0 else {
                if page.layer.mask === gradient { page.layer.mask = nil }
                return
            }
            let height = page.bounds.height
            let clearInPage = min(height, clear)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradient.frame = page.bounds
            // Eased (smoothstep) rather than straight, so neither end of the fade shows as an edge, with the gentlest middle
            // of the eased curves: no line across the hints.
            let steps = (0...16).map { CGFloat($0) / 16 }
            let start = height - clearInPage - fade
            gradient.colors = ([UIColor.black] + steps.map { .black.withAlphaComponent(1 - $0 * $0 * (3 - 2 * $0)) } + [.clear])
                .map(\.cgColor)
            gradient.locations = ([0] + steps.map { max(0, start + fade * $0) / height } + [1]).map { NSNumber(value: Double($0)) }
            page.layer.mask = gradient
            CATransaction.commit()
        }
    }
}

/// A strip of "button: action" hints along the bottom, shown as the Button Legend setting says (by default while a
/// controller is connected), with each button drawn the way the connected controller labels it (✕ ○ on DualSense,
/// A B on Xbox; Xbox's without one): Kenney's Input Prompts for PlayStation, Xbox and Nintendo, the system's otherwise.
struct ControllerHints: View {
    enum Button { case a, b, x, y, l1, r1, menu, view }
    let hints: [(buttons: [Button], label: String)]
    @Environment(GamepadInput.self) private var gamepad
    @AppStorage(SettingsKey.buttonLegend) private var mode = SettingsDefault.buttonLegend

    var body: some View {
        if mode.isShown(controllerConnected: gamepad.isControllerConnected), !hints.isEmpty {
            let pad = GCController.current?.extendedGamepad
            // As many hints as fit, most important (first) kept.
            ViewThatFits(in: .horizontal) {
                ForEach(Array(stride(from: hints.count, to: 0, by: -1)), id: \.self) { count in
                    row(Array(hints.prefix(count)), pad)
                }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.85))
            .transition(.opacity)
            .accessibilityHidden(true) // controller-only help; VoiceOver users have the on-screen controls
        }
    }

    private func row(_ hints: [(buttons: [Button], label: String)], _ pad: GCExtendedGamepad?) -> some View {
        HStack(spacing: 16) {
            ForEach(hints, id: \.label) { hint in
                HStack(spacing: 2) {
                    ForEach(hint.buttons, id: \.self) { icon($0, pad) }
                    Text(hint.label)
                }
                .fixedSize() // a hint whole or not at all: Home's legend cut "Tabs" to "…"
            }
        }
    }

    private func icon(_ button: Button, _ pad: GCExtendedGamepad?) -> some View { Icon(button: button) }

    /// One button drawn the way the connected controller labels it, as in the legend; also inside a button's own label.
    struct Icon: View {
        let button: Button
        @ScaledMetric private var size: CGFloat // the art has a margin inside its square

        init(button: Button, size: CGFloat = 18, relativeTo style: Font.TextStyle = .caption) {
            self.button = button
            _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        }

        var body: some View {
            let symbol = ControllerHints.symbol(button, GCController.current?.extendedGamepad)
            if let name = ControllerHints.packIcon(button, symbol: symbol), UIImage(named: name) != nil {
                Image(name).resizable().frame(width: size, height: size)
            } else {
                Image(systemName: symbol)
            }
        }
    }

    /// The icon pack's art for this controller; nil for one it doesn't cover, which keeps the system's symbol.
    private static func packIcon(_ button: Button, symbol: String) -> String? {
        var category = GCController.current?.productCategory
        #if DEBUG
        category = UserDefaults.standard.string(forKey: "MoonswiftPad") ?? category // `-MoonswiftPad DualSense`, for screenshots
        #endif
        if let category, category.contains("DualSense") || category.contains("DualShock") {
            let isDualSense = category.contains("DualSense")
            return switch button {
            case .a: "playstation_button_cross_outline"
            case .b: "playstation_button_circle_outline"
            case .x: "playstation_button_square_outline"
            case .y: "playstation_button_triangle_outline"
            case .l1: "playstation_trigger_l1_outline"
            case .r1: "playstation_trigger_r1_outline"
            case .menu: isDualSense ? "playstation5_button_options_outline" : "playstation4_button_options_outline"
            case .view: isDualSense ? "playstation5_button_create_outline" : "playstation4_button_share_outline"
            }
        }
        if let category, category.contains("Switch") || category.contains("Joy-Con") || category == "Pro Controller" {
            return switch button {
            case .l1: "switch_button_l_outline"
            case .r1: "switch_button_r_outline"
            case .menu: "switch_button_plus_outline"
            case .view: "switch_button_minus_outline"
            // By the letter iOS reports: Nintendo's A and B sit where Xbox's B and A do.
            default: "switch_button_\(symbol.prefix { $0 != "." })_outline"
            }
        }
        guard category == nil || category?.contains("Xbox") == true else { return nil }
        return switch button {
        case .a: "xbox_button_a_outline"
        case .b: "xbox_button_b_outline"
        case .x: "xbox_button_x_outline"
        case .y: "xbox_button_y_outline"
        case .l1: "xbox_lb_outline"
        case .r1: "xbox_rb_outline"
        case .menu: "xbox_button_menu_outline"
        case .view: "xbox_button_view_outline"
        }
    }

    private static func symbol(_ button: Button, _ pad: GCExtendedGamepad?) -> String {
        let element: GCControllerElement? = switch button {
        case .a: pad?.buttonA
        case .b: pad?.buttonB
        case .x: pad?.buttonX
        case .y: pad?.buttonY
        case .l1: pad?.leftShoulder
        case .r1: pad?.rightShoulder
        case .menu: pad?.buttonMenu
        case .view: pad?.buttonOptions
        }
        if let name = element?.sfSymbolsName { return name }
        return switch button { // no controller (the legend set to Show): Xbox's labels
        case .a: "a.circle"
        case .b: "b.circle"
        case .x: "x.circle"
        case .y: "y.circle"
        case .l1: "lb.rectangle.roundedbottom"
        case .r1: "rb.rectangle.roundedbottom"
        case .menu: "line.3.horizontal.circle"
        case .view: "rectangle.on.rectangle.circle"
        }
    }
}
