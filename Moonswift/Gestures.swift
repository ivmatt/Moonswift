import SwiftUI

/// What a stream gesture does (Settings → Interface → Experience → Gestures).
nonisolated enum GestureAction: Hashable, Sendable {
    case nothing, keyboard, controlPanel, quickSettings, overlay
    /// The on-screen controller's layout editor (Controller mode).
    case editLayout
    /// One of the key shortcuts, by ID.
    case shortcut(String)

    /// Every choice but the shortcuts, which come from the shortcut list.
    static let fixed: [GestureAction] = [.nothing, .keyboard, .controlPanel, .quickSettings, .overlay, .editLayout]

    /// How it's saved: "overlay", or "shortcut:alttab".
    var stored: String {
        switch self {
        case .nothing: "nothing"
        case .keyboard: "keyboard"
        case .controlPanel: "controlPanel"
        case .quickSettings: "quickSettings"
        case .overlay: "overlay"
        case .editLayout: "editLayout"
        case .shortcut(let id): "shortcut:" + id
        }
    }

    init?(stored: String) {
        if stored.hasPrefix("shortcut:") { self = .shortcut(String(stored.dropFirst("shortcut:".count))); return }
        guard let action = Self.fixed.first(where: { $0.stored == stored }) else { return nil }
        self = action
    }

    /// Its button in the on-screen controller's actions row: a symbol, or a shortcut's keys.
    func rowLabel(_ shortcuts: [KeyShortcut]) -> (symbol: String?, text: String?) {
        switch self {
        case .nothing: (nil, nil)
        case .keyboard: ("keyboard", nil)
        case .controlPanel: ("square.grid.2x2", nil)
        case .quickSettings: ("slider.horizontal.3", nil)
        case .overlay: ("gauge.with.dots.needle.67percent", nil)
        case .editLayout: ("square.and.pencil", nil)
        case .shortcut(let id): (nil, shortcuts.first { $0.id == id }?.keys)
        }
    }

    /// Its name in the Gestures page; a shortcut by its name (`shortcuts`: all of them, to look it up).
    func title(_ shortcuts: [KeyShortcut]) -> String {
        switch self {
        case .nothing: "Nothing"
        case .keyboard: "Keyboard"
        case .controlPanel: "Control Panel"
        case .quickSettings: "Quick Settings"
        case .overlay: "Performance Overlay"
        case .editLayout: "Edit Layout"
        case .shortcut(let id): shortcuts.first { $0.id == id }.map { "\($0.name) (\($0.keys))" } ?? "Nothing"
        }
    }
}

/// A stream gesture with three or four fingers (four only with Settings → Experience → Gestures → Four-Finger
/// Gestures on).
nonisolated struct TouchGesture: Hashable {
    let kind: StreamGesture
    let fingers: Int

    /// The gestures you can set for that many fingers, in the Gestures page's order.
    static func all(fingers: Int) -> [TouchGesture] {
        [StreamGesture.swipeLeft, .swipeRight, .swipeUp, .swipeDown, .hold, .pinch].map { TouchGesture(kind: $0, fingers: fingers) }
    }

    static var fourFingersOn: Bool { UserDefaults.standard.bool(forKey: SettingsKey.fourFingerGestures) }
    /// Every gesture that can do something now.
    static var active: [TouchGesture] { all(fingers: 3) + (fourFingersOn ? all(fingers: 4) : []) }

    var title: String {
        switch kind {
        case .swipeLeft: "Swipe Left"
        case .swipeRight: "Swipe Right"
        case .swipeUp: "Swipe Up"
        case .swipeDown: "Swipe Down"
        case .hold: "Hold"
        case .pinch: "Pinch"
        }
    }

    /// Three fingers: the panel left, keyboard up, the overlay on a hold. Four: nothing until you set them.
    /// (Picture in Picture isn't a gesture: it starts when you leave the app mid-stream.)
    var defaultAction: GestureAction {
        switch (kind, fingers) {
        case (.swipeLeft, 3): .controlPanel
        case (.swipeUp, 3): .keyboard
        case (.hold, 3): .overlay
        default: .nothing
        }
    }

    /// Three fingers keep the keys they had before four-finger gestures existed.
    private var key: String { fingers == 3 ? "gesture.\(kind)" : "gesture\(fingers).\(kind)" }

    /// What it's set to now; a shortcut that's since been deleted does nothing.
    var action: GestureAction {
        UserDefaults.standard.string(forKey: key).flatMap(GestureAction.init(stored:)) ?? defaultAction
    }

    func set(_ action: GestureAction) { UserDefaults.standard.set(action.stored, forKey: key) }
    func reset() { UserDefaults.standard.removeObject(forKey: key) }
}

/// Settings → Interface → Experience → Gestures: an action for each stream gesture. Controller: up/down move, A shows
/// a gesture's choices (or resets), B goes back.
struct GesturesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(GamepadInput.self) private var gamepad
    @State private var shortcuts = KeyShortcutStore()
    /// Mirrors what's saved, so a change redraws.
    @State private var actions: [TouchGesture: GestureAction] = [:]
    @AppStorage(SettingsKey.fourFingerGestures) private var fourFingers = false
    @State private var focus = 0
    @State private var choice: ChoiceMenuSpec?
    @State private var rowFrames = RowFrames()

    private enum Row: Hashable { case gesture(TouchGesture), fourFingers, reset }
    private var rows: [Row] {
        TouchGesture.all(fingers: 3).map(Row.gesture) + [.fourFingers]
            + (fourFingers ? TouchGesture.all(fingers: 4).map(Row.gesture) : []) + [.reset]
    }
    private var options: [GestureAction] { GestureAction.fixed + shortcuts.all.map { .shortcut($0.id) } }

    var body: some View {
        ScrollViewReader { scroller in
            Form {
                Section {
                    gestureRows(fingers: 3)
                } header: {
                    Text("Three Fingers")
                } footer: {
                    Text("While streaming. Control Panel and Quick Settings follow a swipe left out of the right edge. A "
                         + "swipe down always hides the keyboard first. A hold is the fingers resting still for a moment.")
                }
                Section {
                    Toggle("Four-Finger Gestures", isOn: $fourFingers)
                        .focusedRowBackground(isFocused(.fourFingers))
                        .id(Row.fourFingers)
                    if fourFingers { gestureRows(fingers: 4) }
                } footer: {
                    Text("The same six gestures with four fingers, for more actions. Off, four fingers do nothing.")
                }
                Section {
                    Button("Reset to Defaults", action: reset)
                        .foregroundStyle(.primary)
                        .focusedRowBackground(isFocused(.reset))
                        .id(Row.reset)
                }
            }
            .onChange(of: focus) { if rows.indices.contains(focus) { withAnimation { scroller.scrollTo(rows[focus], anchor: .center) } } }
        }
        .navigationTitle("Gestures")
        .navigationBarTitleDisplayMode(.inline)
        .choiceMenu($choice)
        .buttonGuide([([.a], "Select"), ([.b], "Back")], reportsLayout: false)
        .onAppear { load() }
        .onGamepad(handle)
    }

    private func isFocused(_ row: Row) -> Bool { gamepad.isActive && rows.indices.contains(focus) && rows[focus] == row }

    private func gestureRows(fingers: Int) -> some View {
        ForEach(TouchGesture.all(fingers: fingers), id: \.self) { gesture in
            let row = Row.gesture(gesture)
            ChoiceRow(title: gesture.title, value: (actions[gesture] ?? gesture.action).title(shortcuts.all),
                      isValueHidden: choice?.source == AnyHashable(row)) {
                Picker(gesture.title, selection: Binding(get: { actions[gesture] ?? gesture.action }, set: { set(gesture, $0) })) {
                    ForEach(options, id: \.self) { Text($0.title(shortcuts.all)).tag($0) }
                }
                .pickerStyle(.inline)
            }
            .recordsFrame(row, in: rowFrames)
            .focusedRowBackground(isFocused(row))
            .id(row)
        }
    }

    private func load() {
        let all = TouchGesture.all(fingers: 3) + TouchGesture.all(fingers: 4)
        actions = Dictionary(uniqueKeysWithValues: all.map { ($0, $0.action) })
    }

    private func set(_ gesture: TouchGesture, _ action: GestureAction) {
        gesture.set(action)
        actions[gesture] = action
    }

    private func reset() {
        (TouchGesture.all(fingers: 3) + TouchGesture.all(fingers: 4)).forEach { $0.reset() }
        load()
    }

    private func handle(_ command: GamepadCommand) {
        switch command {
        case .up, .down: focus = FocusMove.next(focus, count: rows.count, columns: 1, command)
        case .select:
            guard rows.indices.contains(focus) else { return }
            switch rows[focus] {
            case .reset: reset()
            case .fourFingers: fourFingers.toggle()
            case .gesture(let gesture):
                let options = options, current = actions[gesture] ?? gesture.action
                let spec = ChoiceMenuSpec(source: rows[focus], options: options.map { $0.title(shortcuts.all) },
                                          selected: options.firstIndex(of: current) ?? 0,
                                          anchor: rowFrames.frames[rows[focus]] ?? .zero) { set(gesture, options[$0]) }
                withAnimation(.easeOut(duration: 0.12)) { choice = spec }
            }
        case .back: dismiss()
        default: break
        }
    }
}
