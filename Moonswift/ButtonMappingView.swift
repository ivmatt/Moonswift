import SwiftUI

/// Settings → Button Mapping: a layout preset (Standard or Nintendo) or a custom choice per button. Applies to every
/// controller at once, in games and in the app's menus, including mid-stream. A controller moves with up/down,
/// changes the focused row with left/right (A presses Reset) and goes back with B.
struct ButtonMappingView: View {
    private enum Layout: String, CaseIterable { case standard = "Standard", nintendo = "Nintendo", custom = "Custom" }

    @Environment(\.dismiss) private var dismiss
    @Environment(GamepadInput.self) private var gamepad
    @State private var remap = ButtonRemap.current
    @State private var focus = 0

    private var layout: Layout { remap == .standard ? .standard : remap == .nintendo ? .nintendo : .custom }
    /// Rows in screen order: the layout, each button, Reset.
    private var rowCount: Int { GameButton.allCases.count + 2 }

    var body: some View {
        List {
            Section {
                row(0) {
                    Picker("Layout", selection: Binding(get: { layout }, set: { setLayout($0) })) {
                        ForEach(Layout.allCases, id: \.self) { Text($0.rawValue) }
                    }
                }
            } footer: {
                Text("Nintendo swaps A with B and X with Y, so buttons sit where Nintendo games expect them. Applies to every controller, in games and in Moonswift's menus.")
            }
            Section("Each Button Acts As") {
                ForEach(Array(GameButton.allCases.enumerated()), id: \.element) { index, button in
                    row(index + 1) {
                        Picker(button.title, selection: target(of: button)) {
                            ForEach(GameButton.allCases, id: \.self) { Text($0.title) }
                        }
                    }
                }
            }
            Section {
                row(rowCount - 1) {
                    Button("Reset to Standard", role: .destructive) { remap = .standard }.disabled(remap == .standard)
                }
            }
        }
        .navigationTitle("Button Mapping")
        .onChange(of: remap) { ButtonRemap.current = remap }
        .onGamepad { command in
            switch command {
            case .up, .down: focus = FocusMove.next(focus, count: rowCount, columns: 1, command)
            case .left, .right: step(by: command == .left ? -1 : 1)
            case .select: if focus == rowCount - 1 { remap = .standard } else { step(by: 1) }
            case .back: dismiss()
            default: break
            }
        }
    }

    private func row(_ index: Int, @ViewBuilder content: () -> some View) -> some View {
        content().listRowBackground(gamepad.isActive && focus == index ? Color.accentColor.opacity(0.25)
                                                                       : Color(.secondarySystemGroupedBackground))
    }

    private func target(of button: GameButton) -> Binding<GameButton> {
        Binding(get: { remap.target(button) },
                set: { remap.targets[button] = $0 == button ? nil : $0 })
    }

    private func setLayout(_ layout: Layout) {
        switch layout {
        case .standard: remap = .standard
        case .nintendo: remap = .nintendo
        case .custom: break // custom is whatever the buttons below say
        }
    }

    /// Left/right on the focused row: the previous or next layout, or the previous or next target button.
    private func step(by offset: Int) {
        func next<T: Equatable>(_ value: T, in options: [T]) -> T {
            let index = options.firstIndex(of: value) ?? 0
            return options[min(max(index + offset, 0), options.count - 1)]
        }
        if focus == 0 {
            setLayout(next(layout, in: [.standard, .nintendo]))
        } else if focus < rowCount - 1 {
            let button = GameButton.allCases[focus - 1]
            target(of: button).wrappedValue = next(remap.target(button), in: GameButton.allCases)
        }
    }
}
