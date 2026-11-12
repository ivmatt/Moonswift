import GameController
import SwiftUI

/// What a controller (or keyboard) asks the UI to do.
nonisolated enum GamepadCommand: Equatable, Sendable {
    case up, down, left, right
    case select // A, Return
    case back // B, Esc
    case menu // X or Y, Space
    case streamMenu // Menu + View held for a second: the in-stream menu, since every other button goes to the game
}

/// iPadOS doesn't move UI focus with a game controller (only tvOS and visionOS do), so the app reads the
/// controller itself and hands commands to whichever screen is on top. The screen draws its own highlight.
@Observable final class GamepadInput {
    /// True once a controller or keyboard has been used; the focus highlight only shows then.
    private(set) var isActive = false

    @ObservationIgnored private var handlers: [(id: UUID, handle: (GamepadCommand) -> Void)] = []
    /// While streaming, the keyboard goes to the game instead of the menus (there can only be one handler).
    @ObservationIgnored var keyboardOverride: ((GCKeyCode, Bool) -> Void)?
    @ObservationIgnored private var dpad = HeldDirection()
    @ObservationIgnored private var stick = HeldDirection()
    @ObservationIgnored private var held: GamepadCommand?
    @ObservationIgnored private var repeatTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var comboButtons: Set<String> = []
    @ObservationIgnored private var comboTask: Task<Void, Never>?

    func start() {
        guard observers.isEmpty else { return }
        for name in [Notification.Name.GCControllerDidConnect, .GCKeyboardDidConnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.attachAll() }
            })
        }
        attachAll()
    }

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
        // Handlers run on each controller's handlerQueue, which is the main queue by default.
        for controller in GCController.controllers() {
            guard let pad = controller.extendedGamepad else { continue }
            pad.dpad.valueChangedHandler = { [weak self] _, x, y in
                MainActor.assumeIsolated { self?.hold(dpad: x, y) }
            }
            pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
                MainActor.assumeIsolated { self?.hold(stick: x, y) }
            }
            let buttons: [(GCControllerButtonInput, GamepadCommand)] =
                [(pad.buttonA, .select), (pad.buttonB, .back), (pad.buttonX, .menu), (pad.buttonY, .menu)]
            for (button, command) in buttons {
                button.pressedChangedHandler = { [weak self] _, _, pressed in
                    if pressed { MainActor.assumeIsolated { self?.send(command) } }
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

    /// Menu + View held together for a second sends .streamMenu once.
    private func combo(_ button: String, pressed: Bool) {
        if pressed { comboButtons.insert(button) } else { comboButtons.remove(button) }
        comboTask?.cancel()
        comboTask = nil
        guard comboButtons.count == 2 else { return }
        comboTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { self?.send(.streamMenu) }
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
    /// Sends controller commands to `handle` while this view is on screen and nothing newer is.
    func onGamepad(_ handle: @escaping (GamepadCommand) -> Void) -> some View {
        modifier(GamepadHandler(handle: handle))
    }

    /// The controller focus highlight: slightly bigger, an accent ring and a shadow.
    func focusRing(_ isOn: Bool, cornerRadius: CGFloat = 12) -> some View {
        self
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius + 4)
                    .stroke(Color.accentColor, lineWidth: 4)
                    .padding(-6)
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
    let handle: (GamepadCommand) -> Void

    func body(content: Content) -> some View {
        let _ = gamepad.refresh(id, handle) // the closure captured at onAppear would see stale non-State values
        content
            .onAppear { gamepad.register(id, handle) }
            .onDisappear { gamepad.unregister(id) }
    }
}
