import SwiftUI

/// The control center's shortcuts: which show there and in what order, and your own. Controller: up/down move, A pins
/// or unpins (or opens New Shortcut), Y moves a pinned one up, X deletes one of yours, B closes.
struct ShortcutsEditView: View {
    let store: KeyShortcutStore
    @Environment(\.dismiss) private var dismiss
    @Environment(GamepadInput.self) private var gamepad
    @State private var focus = 0
    @State private var isAdding = false

    private enum Row: Hashable { case pinned(String), other(String), new }
    private var others: [KeyShortcut] { store.all.filter { !store.isPinned($0) } }
    private var rows: [Row] { store.pinned.map { .pinned($0.id) } + others.map { .other($0.id) } + [.new] }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
            List {
                Section {
                    ForEach(store.pinned) { shortcut in
                        shortcutRow(shortcut, row: .pinned(shortcut.id), symbol: "minus.circle.fill", color: .red)
                    }
                    .onMove(perform: store.movePinned)
                } header: {
                    Text("In the Control Center")
                } footer: {
                    Text("Drag to reorder. Each sends its keys to the host, as if pressed on a keyboard there.")
                }
                Section("More Shortcuts") {
                    ForEach(others) { shortcut in
                        shortcutRow(shortcut, row: .other(shortcut.id), symbol: "plus.circle.fill", color: .green)
                            .swipeActions {
                                if isCustom(shortcut) { Button("Delete", role: .destructive) { store.delete(shortcut) } }
                            }
                    }
                }
                Section {
                    Button("New Shortcut…") { isAdding = true }
                        .foregroundStyle(.primary)
                        .focusedRowBackground(isFocused(.new))
                        .id(Row.new)
                }
            }
            // The focused row stays in view as the controller moves down the list.
            .onChange(of: focus) { if rows.indices.contains(focus) { withAnimation { scroller.scrollTo(rows[focus], anchor: .center) } } }
            }
            .environment(\.editMode, .constant(.active)) // drag handles on the pinned ones
            .tint(.primary) // rows are buttons: white like a list's text, not the accent blue
            .navigationTitle("Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(isPresented: $isAdding) { NewShortcutView(store: store) }
            .buttonGuide([([.a], "Pin / Unpin"), ([.y], "Move Up"), ([.x], "Delete"), ([.b], "Done")], reportsLayout: false)
            .onGamepad(handle)
        }
    }

    private func isCustom(_ shortcut: KeyShortcut) -> Bool { store.custom.contains(shortcut) }
    private func isFocused(_ row: Row) -> Bool { gamepad.isActive && rows.indices.contains(focus) && rows[focus] == row }

    private func shortcutRow(_ shortcut: KeyShortcut, row: Row, symbol: String, color: Color) -> some View {
        Button { store.togglePin(shortcut) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(color).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(shortcut.name).foregroundStyle(.primary)
                    Text(shortcut.keys).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .focusedRowBackground(isFocused(row))
        .id(row)
    }

    private func shortcut(_ row: Row) -> KeyShortcut? {
        switch row {
        case .pinned(let id), .other(let id): store.all.first { $0.id == id }
        case .new: nil
        }
    }

    private func handle(_ command: GamepadCommand) {
        guard rows.indices.contains(focus) else { focus = 0; return }
        let row = rows[focus]
        switch command {
        case .up, .down: focus = FocusMove.next(focus, count: rows.count, columns: 1, command)
        case .select:
            if row == .new { isAdding = true } else if let shortcut = shortcut(row) { store.togglePin(shortcut) }
        case .menu: // Y: earlier in the control center
            if case .pinned = row, focus > 0 {
                store.movePinned(from: [focus], to: focus - 1)
                focus -= 1
            }
        case .alternate: // X
            if let shortcut = shortcut(row), isCustom(shortcut) { store.delete(shortcut) }
        case .back: dismiss()
        default: break
        }
    }
}

/// Makes a shortcut: a name, any of Ctrl, Alt, Shift and Win, and one key. Controller: up/down move, A flips a modifier
/// or types the name, left/right change the key, B goes back.
private struct NewShortcutView: View {
    let store: KeyShortcutStore
    @Environment(\.dismiss) private var dismiss
    @Environment(GamepadInput.self) private var gamepad
    @State private var name = ""
    @State private var modifiers: Set<KeyShortcut.Modifier> = []
    @State private var key = 0x04
    @State private var focus = 0
    @FocusState private var isNameFocused: Bool

    private enum Row: Hashable { case name, modifier(KeyShortcut.Modifier), key, save }
    private let rows: [Row] = [.name] + KeyShortcut.Modifier.allCases.map(Row.modifier) + [.key, .save]
    private var ordered: [KeyShortcut.Modifier] { KeyShortcut.Modifier.allCases.filter(modifiers.contains) }
    private var preview: KeyShortcut { KeyShortcut(id: "", name: name, modifiers: ordered, key: key) }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name).focused($isNameFocused).focusedRowBackground(isFocused(.name))
            }
            Section {
                ForEach(KeyShortcut.Modifier.allCases, id: \.self) { modifier in
                    Toggle(modifier.title, isOn: Binding(get: { modifiers.contains(modifier) },
                                                         set: { if $0 { modifiers.insert(modifier) } else { modifiers.remove(modifier) } }))
                        .tint(.green) // a switch's usual colour, under the page's white tint
                        .focusedRowBackground(isFocused(.modifier(modifier)))
                }
                Picker("Key", selection: $key) {
                    ForEach(KeyShortcut.keyChoices, id: \.self) { Text(KeyShortcut.keyName($0)).tag($0) }
                }
                .focusedRowBackground(isFocused(.key))
            } header: {
                Text("Keys")
            } footer: {
                Text("Sends \(preview.keys).")
            }
            Section {
                Button("Add Shortcut", action: save).disabled(trimmed.isEmpty)
                    .foregroundStyle(trimmed.isEmpty ? .secondary : .primary)
                    .focusedRowBackground(isFocused(.save))
            }
        }
        .tint(.primary) // the add button and picker in white, not the accent blue
        .navigationTitle("New Shortcut")
        .navigationBarTitleDisplayMode(.inline)
        .buttonGuide([([.a], "Select"), ([.b], "Back")], reportsLayout: false)
        .onGamepad(handle)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private func isFocused(_ row: Row) -> Bool { gamepad.isActive && !isNameFocused && rows[focus] == row }

    private func save() {
        guard !trimmed.isEmpty else { return }
        store.add(name: trimmed, modifiers: ordered, key: key)
        dismiss()
    }

    private func handle(_ command: GamepadCommand) {
        if [.up, .down].contains(command), isNameFocused { isNameFocused = false }
        switch command {
        case .up, .down: focus = FocusMove.next(focus, count: rows.count, columns: 1, command)
        case .left, .right:
            guard rows[focus] == .key, let index = KeyShortcut.keyChoices.firstIndex(of: key) else { return }
            let count = KeyShortcut.keyChoices.count
            key = KeyShortcut.keyChoices[(index + (command == .right ? 1 : -1) + count) % count]
        case .select:
            switch rows[focus] {
            case .name: isNameFocused = true
            case .modifier(let modifier): if modifiers.contains(modifier) { modifiers.remove(modifier) } else { modifiers.insert(modifier) }
            case .key: break
            case .save: save()
            }
        case .back: if isNameFocused { isNameFocused = false } else { dismiss() }
        default: break
        }
    }
}
