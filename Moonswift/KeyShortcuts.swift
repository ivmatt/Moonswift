import SwiftUI

/// A key combination sent to the host from the control center: Alt+Tab, the Steam overlay, or one you made.
nonisolated struct KeyShortcut: Codable, Hashable, Identifiable {
    enum Modifier: String, Codable, CaseIterable {
        case ctrl, alt, shift, win
        var title: String { self == .win ? "Win" : rawValue.capitalized }
        /// The HID usage of its left-hand key.
        var hidUsage: Int { switch self { case .ctrl: 0xE0; case .shift: 0xE1; case .alt: 0xE2; case .win: 0xE3 } }
    }

    var id: String
    var name: String
    var modifiers: [Modifier]
    /// The HID usage of the key pressed with them (a modifier's own, for the Windows key on its own).
    var key: Int

    /// e.g. "Alt+Tab".
    var keys: String { (modifiers.map(\.title) + [Self.keyName(key)]).joined(separator: "+") }

    static let builtIns: [KeyShortcut] = [
        KeyShortcut(id: "esc", name: "Escape", modifiers: [], key: 0x29),
        KeyShortcut(id: "alttab", name: "Switch Window", modifiers: [.alt], key: 0x2B),
        KeyShortcut(id: "win", name: "Start Menu", modifiers: [], key: 0xE3),
        KeyShortcut(id: "steam", name: "Steam Overlay", modifiers: [.shift], key: 0x2B),
        KeyShortcut(id: "altenter", name: "Fullscreen", modifiers: [.alt], key: 0x28),
        KeyShortcut(id: "altf4", name: "Close Window", modifiers: [.alt], key: 0x3D),
        KeyShortcut(id: "taskmanager", name: "Task Manager", modifiers: [.ctrl, .shift], key: 0x29),
        KeyShortcut(id: "desktop", name: "Show Desktop", modifiers: [.win], key: 0x07),
        KeyShortcut(id: "gamebar", name: "Game Bar", modifiers: [.win], key: 0x0A),
    ]
    static let defaultPinned = ["esc", "alttab", "win", "steam", "altenter"]

    /// The keys a shortcut of your own can press, in the picker's order.
    static let keyChoices: [Int] = Array(0x04...0x1D) + Array(0x1E...0x27) + Array(0x3A...0x45)
        + [0x29, 0x2B, 0x28, 0x2C, 0x2A, 0x4C, 0x4A, 0x4D, 0x4B, 0x4E, 0x52, 0x51, 0x50, 0x4F, 0x46]

    static func keyName(_ usage: Int) -> String {
        switch usage {
        case 0x04...0x1D: String(UnicodeScalar(UInt8(usage - 0x04) + 65))
        case 0x1E...0x26: String(usage - 0x1E + 1)
        case 0x27: "0"
        case 0x3A...0x45: "F\(usage - 0x3A + 1)"
        default:
            [0x29: "Esc", 0x2B: "Tab", 0x28: "Enter", 0x2C: "Space", 0x2A: "Backspace", 0x4C: "Delete", 0x4A: "Home",
             0x4D: "End", 0x4B: "Page Up", 0x4E: "Page Down", 0x52: "Up", 0x51: "Down", 0x50: "Left", 0x4F: "Right",
             0x46: "Print Screen", 0xE3: "Win"][usage] ?? "Key"
        }
    }

    /// The presses and releases, in order: modifiers down, the key down and up, modifiers up (last pressed first).
    var presses: [(usage: Int, down: Bool, modifiers: Int8)] {
        var events: [(Int, Bool, Int8)] = []
        var flags: Int8 = 0
        for modifier in modifiers {
            events.append((modifier.hidUsage, true, flags))
            flags |= KeyMap.modifier(hidUsage: modifier.hidUsage)
        }
        events += [(key, true, flags), (key, false, flags)]
        for modifier in modifiers.reversed() {
            flags &= ~KeyMap.modifier(hidUsage: modifier.hidUsage)
            events.append((modifier.hidUsage, false, flags))
        }
        return events
    }

    /// Presses it on the host, a moment between each step so games that poll the keyboard see it.
    func send() async {
        for press in presses {
            guard let key = KeyMap.key(hidUsage: press.usage) else { continue }
            KeyMap.send(key, down: press.down, modifiers: press.modifiers)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Your shortcuts and which ones the control center shows, kept on this device.
@Observable final class KeyShortcutStore {
    private(set) var custom: [KeyShortcut]
    /// The control center's buttons, in order (IDs of built-in and your own).
    private(set) var pinnedIDs: [String]

    init() {
        let defaults = UserDefaults.standard
        custom = defaults.data(forKey: "customShortcuts").flatMap { try? JSONDecoder().decode([KeyShortcut].self, from: $0) } ?? []
        pinnedIDs = defaults.stringArray(forKey: "pinnedShortcuts") ?? KeyShortcut.defaultPinned
    }

    var all: [KeyShortcut] { KeyShortcut.builtIns + custom }
    var pinned: [KeyShortcut] { pinnedIDs.compactMap { id in all.first { $0.id == id } } }

    func isPinned(_ shortcut: KeyShortcut) -> Bool { pinnedIDs.contains(shortcut.id) }

    func togglePin(_ shortcut: KeyShortcut) {
        if isPinned(shortcut) { pinnedIDs.removeAll { $0 == shortcut.id } } else { pinnedIDs.append(shortcut.id) }
        save()
    }

    func movePinned(from source: IndexSet, to destination: Int) {
        var ids = pinned.map(\.id) // only ones that still exist
        ids.move(fromOffsets: source, toOffset: destination)
        pinnedIDs = ids
        save()
    }

    /// A new one is pinned straight away.
    func add(name: String, modifiers: [KeyShortcut.Modifier], key: Int) {
        let shortcut = KeyShortcut(id: UUID().uuidString, name: name, modifiers: modifiers, key: key)
        custom.append(shortcut)
        pinnedIDs.append(shortcut.id)
        save()
    }

    func delete(_ shortcut: KeyShortcut) {
        custom.removeAll { $0.id == shortcut.id }
        pinnedIDs.removeAll { $0 == shortcut.id }
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(custom), forKey: "customShortcuts")
        UserDefaults.standard.set(pinnedIDs, forKey: "pinnedShortcuts")
    }
}
