import GameController
import MoonlightCore

/// USB HID keyboard usages (what GCKeyCode holds) to Windows virtual-key codes, which is what the host expects.
/// Ported from moonlight-ios's KeyboardSupport.m.
nonisolated enum KeyMap {
    struct Key: Equatable {
        let virtualKey: Int16
        /// Keys Windows tells apart by the 0xE0 "extended" scancode prefix, like Numpad Enter vs Enter.
        let extended: Bool
    }

    static func key(hidUsage usage: Int) -> Key? {
        switch usage {
        case 0x04...0x1D: return Key(virtualKey: Int16(usage - 0x04 + 0x41), extended: false) // A–Z
        case 0x1E...0x26: return Key(virtualKey: Int16(usage - 0x1E + 0x31), extended: false) // 1–9
        case 0x27: return Key(virtualKey: 0x30, extended: false) // 0
        case 0x3A...0x45: return Key(virtualKey: Int16(usage - 0x3A + 0x70), extended: false) // F1–F12
        case 0x68...0x73: return Key(virtualKey: Int16(usage - 0x68 + 0x7C), extended: false) // F13–F24
        case 0x59...0x61: return Key(virtualKey: Int16(usage - 0x59 + 0x61), extended: false) // keypad 1–9
        case 0x62: return Key(virtualKey: 0x60, extended: false) // keypad 0
        default: break
        }
        let table: [Int: (Int16, Bool)] = [
            0x28: (0x0D, false), 0x29: (0x1B, false), 0x2A: (0x08, false), 0x2B: (0x09, false), 0x2C: (0x20, false),
            0x2D: (0xBD, false), 0x2E: (0xBB, false), 0x2F: (0xDB, false), 0x30: (0xDD, false), 0x31: (0xDC, false),
            0x33: (0xBA, false), 0x34: (0xDE, false), 0x35: (0xC0, false), 0x36: (0xBC, false), 0x37: (0xBE, false),
            0x38: (0xBF, false), 0x39: (0x14, false),
            0x46: (0x2C, true), 0x47: (0x91, false), 0x48: (0x13, false), // Print Screen, Scroll Lock, Pause
            0x49: (0x2D, true), 0x4A: (0x24, true), 0x4B: (0x21, true), 0x4C: (0x2E, true), 0x4D: (0x23, true), 0x4E: (0x22, true),
            0x4F: (0x27, true), 0x50: (0x25, true), 0x51: (0x28, true), 0x52: (0x26, true), // arrows
            0x53: (0x90, true), 0x54: (0x6F, true), 0x55: (0x6A, false), 0x56: (0x6D, false), 0x57: (0x6B, false),
            0x58: (0x0D, true), 0x63: (0x6E, false), 0x64: (0xE2, false), 0x65: (0x5D, true), // Numpad Enter, Menu key
            0xE0: (0xA2, false), 0xE1: (0xA0, false), 0xE2: (0xA4, false), 0xE3: (0x5B, true),
            0xE4: (0xA3, true), 0xE5: (0xA1, false), 0xE6: (0xA5, true), 0xE7: (0x5C, true),
        ]
        return table[usage].map { Key(virtualKey: $0.0, extended: $0.1) }
    }

    /// The key a typed character comes from (without Shift), for shortcuts like Ctrl+C from the on-screen keyboard.
    static func hidUsage(for character: Character) -> Int? {
        guard let ascii = character.lowercased().first?.asciiValue else { return nil }
        switch ascii {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return Int(ascii - UInt8(ascii: "a")) + 0x04
        case UInt8(ascii: "1")...UInt8(ascii: "9"): return Int(ascii - UInt8(ascii: "1")) + 0x1E
        case UInt8(ascii: "0"): return 0x27
        case UInt8(ascii: " "): return 0x2C
        default: return nil
        }
    }

    /// Sends one key press or release. 0x8000 marks the code as a virtual-key code, as moonlight-ios sends it.
    static func send(_ key: Key, down: Bool, modifiers: Int8) {
        let flags = modifiers | (key.extended ? Int8(MODIFIER_EXTENDED) : 0)
        LiSendKeyboardEvent(Int16(bitPattern: 0x8000) | key.virtualKey, CChar(down ? KEY_ACTION_DOWN : KEY_ACTION_UP), CChar(flags))
    }

    /// The modifier bit a key sets while held (Shift, Ctrl, Alt, Windows/Command), if any.
    static func modifier(hidUsage usage: Int) -> Int8 {
        switch usage {
        case 0xE1, 0xE5: Int8(MODIFIER_SHIFT)
        case 0xE0, 0xE4: Int8(MODIFIER_CTRL)
        case 0xE2, 0xE6: Int8(MODIFIER_ALT)
        case 0xE3, 0xE7: Int8(MODIFIER_META)
        default: 0
        }
    }
}

/// Sends a hardware keyboard and mouse to the host while streaming.
final class KeyboardMouseStreamer {
    /// When a mouse or trackpad button was last pressed for real (system uptime), so a trackpad's tap to click, which
    /// GCMouse doesn't report, can be told from a physical click (TouchInputView).
    static var lastPhysicalClick: TimeInterval = 0
    private weak var gamepad: GamepadInput?
    private var pressed: [Int: KeyMap.Key] = [:] // by HID usage, so they can all be released
    private var heldButtons: Set<Int32> = [] // mouse buttons down on the host, so they can be released too
    private var modifiers: Int8 = 0
    private var mouseRemainder = (x: Float(0), y: Float(0))
    private var observer: (any NSObjectProtocol)?
    var isPaused = false { didSet { if isPaused { releaseAll() }; ButtonGuideWindow.locksPointer = !isPaused } }

    func start(gamepad: GamepadInput) {
        self.gamepad = gamepad
        gamepad.keyboardOverride = { [weak self] key, down in self?.key(key, down: down) }
        observer = NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.attachMice(); ButtonGuideWindow.refreshPointerLock() }
        }
        attachMice()
        ButtonGuideWindow.locksPointer = !isPaused // the menus and panel need the pointer, so only while playing
    }

    func stop() {
        releaseAll()
        ButtonGuideWindow.locksPointer = false
        gamepad?.keyboardOverride = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        for mouse in GCMouse.mice() {
            guard let input = mouse.mouseInput else { continue }
            input.mouseMovedHandler = nil
            input.scroll.valueChangedHandler = nil
            ([input.leftButton] + [input.rightButton, input.middleButton].compactMap { $0 } + (input.auxiliaryButtons ?? []))
                .forEach { $0.pressedChangedHandler = nil }
        }
    }

    private func key(_ code: GCKeyCode, down: Bool) {
        let usage = Int(code.rawValue)
        guard !isPaused, let key = KeyMap.key(hidUsage: usage) else { return }
        let bit = KeyMap.modifier(hidUsage: usage)
        if down { modifiers |= bit } else { modifiers &= ~bit }
        if down { pressed[usage] = key } else { pressed[usage] = nil }
        KeyMap.send(key, down: down, modifiers: modifiers)
    }

    /// Lifts every held key, so nothing stays stuck down on the host (menu opened, stream closed).
    private func releaseAll() {
        modifiers = 0
        for key in pressed.values { KeyMap.send(key, down: false, modifiers: 0) }
        pressed = [:]
        for button in heldButtons { LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), button) }
        heldButtons = []
    }

    private func mouseButton(_ button: Int32, pressed: Bool) {
        guard !isPaused else { return }
        if pressed { heldButtons.insert(button) } else { heldButtons.remove(button) }
        LiSendMouseButtonEvent(CChar(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE), button)
    }

    private func attachMice() {
        for mouse in GCMouse.mice() {
            guard let input = mouse.mouseInput else { continue }
            input.mouseMovedHandler = { [weak self] _, dx, dy in
                MainActor.assumeIsolated { self?.move(dx: dx, dy: -dy) } // GameController's y points up; screens' down
            }
            input.scroll.valueChangedHandler = { [weak self] _, _, y in
                MainActor.assumeIsolated {
                    // shortcut: 120 wheel units per reported unit (one notch on a typical mouse); tune on more mice.
                    if self?.isPaused == false, y != 0 { LiSendHighResScrollEvent(Int16(clamping: Int(y * 120))) }
                }
            }
            let buttons: [(GCControllerButtonInput?, Int32)] = [(input.leftButton, BUTTON_LEFT), (input.rightButton, BUTTON_RIGHT),
                                                                (input.middleButton, BUTTON_MIDDLE)]
                + (input.auxiliaryButtons ?? []).prefix(2).enumerated().map { ($1, $0 == 0 ? BUTTON_X1 : BUTTON_X2) }
            for (button, code) in buttons {
                button?.pressedChangedHandler = { [weak self] _, _, pressed in
                    MainActor.assumeIsolated {
                        if pressed { KeyboardMouseStreamer.lastPhysicalClick = ProcessInfo.processInfo.systemUptime }
                        self?.mouseButton(code, pressed: pressed)
                    }
                }
            }
        }
    }

    private func move(dx: Float, dy: Float) {
        guard !isPaused else { return }
        mouseRemainder.x += dx
        mouseRemainder.y += dy
        let x = mouseRemainder.x.rounded(.towardZero), y = mouseRemainder.y.rounded(.towardZero)
        mouseRemainder.x -= x
        mouseRemainder.y -= y
        if x != 0 || y != 0 { LiSendMouseMoveEvent(Int16(clamping: Int(x)), Int16(clamping: Int(y))) }
    }
}
