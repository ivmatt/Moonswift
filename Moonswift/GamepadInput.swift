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
    /// A game controller is connected now: screens show the button guide and make room for it.
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

    /// The last controller gone: back to touch, so the guide and focus highlights go too.
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

    /// The controller focus highlight: slightly bigger, a thin ring (white in dark mode, black in light) an even gap outside the shape, and a shadow.
    /// `cornerRadius` is the shape's own; `.infinity` for a capsule.
    func focusRing(_ isOn: Bool, cornerRadius: CGFloat = 12) -> some View {
        let gap: CGFloat = 3, line: CGFloat = 2
        return self
            .overlay {
                // Concentric: the ring's radius grows by exactly how far out it sits, so it follows the shape.
                RoundedRectangle(cornerRadius: cornerRadius + gap + line)
                    .strokeBorder(.primary, lineWidth: line) // white in dark mode, black in light
                    .padding(-(gap + line))
                    .opacity(isOn ? 1 : 0)
            }
            .scaleEffect(isOn ? 1.05 : 1)
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

/// Settings → Controller → Button Guide.
nonisolated enum ButtonGuideMode: String, CaseIterable {
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
    /// The page's button guide, placed the same on every tab. With the tab bar beside or above (the Duo, iPad): bottom
    /// left, in line with the content 36 points in. With it along the bottom (iPhone): at the top, on the title's line;
    /// while the tab bar is shrunk to its corner, in the room it left at the bottom.
    /// `reportsLayout`: a tab's page, which says where the tab bar is; false for a sheet's, whose guide shows over its
    /// tab's.
    func buttonGuide(_ hints: [(buttons: [ControllerHints.Button], label: String)], reportsLayout: Bool = true) -> some View {
        modifier(ButtonGuidePlacement(hints: hints, reportsLayout: reportsLayout))
    }

    /// For a scrolling page: follows the tab bar's shrinking (scrolling down) and coming back (scrolling up), which iOS
    /// doesn't report, so the button guide can move with it.
    func tracksTabBarMinimize() -> some View { modifier(TabBarMinimizeTracking()) }

    /// Whether the tab bar runs along the bottom, from this page's bottom inset, not counting the keyboard's: its height
    /// read as a tab bar, so the Duo and iPad were taken for iPhones (the guide went to the top, the tab bar was hidden,
    /// and both stayed so).
    /// shortcut: iOS doesn't say where its tab bar is; a bottom inset of 40 to 150 points is one, taller is a keyboard.
    /// A hardware keyboard's slim bar on an iPhone could pass for one. Revisit if the system says.
    func onTabBarBelowChange(_ action: @escaping (Bool) -> Void) -> some View { modifier(TabBarBelowWatch(action: action)) }

    /// Hides the tab bar along the bottom (iPhone) while `hide` holds, such as Library's search or a controller below
    /// a page's first row; the button guide takes its place. The Duo's rail and iPad's bar stay.
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

/// Whether the tab bar is shrunk to its corner, as far as scrolling tells. RootView resets it on a tab change.
@Observable final class TabBarMinimize {
    var isMinimized = false
    /// A page has hidden it (`hidesTabBarOnPhone`).
    var isHidden = false
}

private struct TabBarMinimizeTracking: ViewModifier {
    @Environment(TabBarMinimize.self) private var tabBar: TabBarMinimize? // none in a sheet over a stream, or a preview

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { old, new in
            guard let tabBar else { return }
            // shortcut: the system's own rule is private; this follows its direction (down shrinks, up brings it back).
            // If the guide and tab bar disagree, revisit.
            let minimized = new - old > 2 ? true : old - new > 2 ? false : tabBar.isMinimized
            if minimized != tabBar.isMinimized { tabBar.isMinimized = minimized }
        }
    }
}

private struct ButtonGuidePlacement: ViewModifier {
    let hints: [(buttons: [ControllerHints.Button], label: String)]
    let reportsLayout: Bool
    @State private var id = UUID()
    @Environment(ButtonGuideCenter.self) private var center: ButtonGuideCenter?
    @Environment(TabBarMinimize.self) private var tabBar: TabBarMinimize?
    @Environment(GamepadInput.self) private var gamepad
    @AppStorage(SettingsKey.buttonGuide) private var mode = ButtonGuideMode.automatic

    func body(content: Content) -> some View {
        let shows = mode.isShown(controllerConnected: gamepad.isControllerConnected) && !hints.isEmpty
        content
            // Room at the bottom for the guide (drawn above everything, by ButtonGuideWindow), with no spacing of the
            // system's own: Home's covers end the same 28 points above it as Play is above them. The guide sits 4
            // points into the margin below, so it looks balanced there.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if shows, !(center?.isTabBarBelow ?? false) { Color.clear.frame(height: max(0, (center?.height ?? 34) - 4)) }
            }
            .onTabBarBelowChange { if reportsLayout, !(tabBar?.isHidden ?? false) { center?.isTabBarBelow = $0 } }
            .onAppear { center?.set(id, isOverTabs: !reportsLayout, hints) }
            .onDisappear { center?.remove(id) }
            .onChange(of: hints.map(\.label)) { center?.set(id, isOverTabs: !reportsLayout, hints) }
    }
}

/// A strip of "button: action" hints along the bottom, shown as the Button Guide setting says (by default while a
/// controller is connected), with each button drawn the way the connected controller labels it (✕ ○ on DualSense,
/// A B on Xbox; Xbox's without one).
struct ControllerHints: View {
    enum Button { case a, b, x, y, l1, r1, menu, view }
    let hints: [(buttons: [Button], label: String)]
    @Environment(GamepadInput.self) private var gamepad
    @AppStorage(SettingsKey.buttonGuide) private var mode = ButtonGuideMode.automatic

    var body: some View {
        if mode.isShown(controllerConnected: gamepad.isControllerConnected), !hints.isEmpty {
            let pad = GCController.current?.extendedGamepad
            HStack(spacing: 16) {
                ForEach(hints, id: \.label) { hint in
                    HStack(spacing: 4) {
                        ForEach(hint.buttons.map { Self.symbol($0, pad) }, id: \.self) { Image(systemName: $0) }
                        Text(hint.label)
                    }
                    .fixedSize() // a hint whole or not at all: Home's guide cut "Tabs" to "…"
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            // Glass, like the tab bar and toolbar it floats with; not interactive, as it can't be tapped.
            .glassEffect(.regular, in: .capsule)
            .transition(.opacity)
            .accessibilityHidden(true) // controller-only help; VoiceOver users have the on-screen controls
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
        return switch button { // no controller (the guide set to Show): Xbox's labels
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
