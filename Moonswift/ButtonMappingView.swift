import SwiftUI

/// Settings → Button Mapping: a layout preset (Standard or Nintendo) or a custom choice per button. Applies to every
/// controller at once, in games and in the app's menus, including mid-stream. A controller moves with up/down, A shows
/// a row's choices to pick from (or presses Reset), and B goes back.
struct ButtonMappingView: View {
    private enum Layout: String, CaseIterable { case standard = "Standard", nintendo = "Nintendo", custom = "Custom" }

    @Environment(\.dismiss) private var dismiss
    @Environment(GamepadInput.self) private var gamepad
    @State private var remap = ButtonRemap.current
    @State private var focus = 0
    /// A row's choices, for the controller, beside it.
    @State private var choice: ChoiceMenuSpec?
    @State private var rowFrames = RowFrames()

    private var layout: Layout { remap == .standard ? .standard : remap == .nintendo ? .nintendo : .custom }
    /// Rows in screen order: the layout, each button, Reset.
    private var rowCount: Int { GameButton.allCases.count + 2 }

    var body: some View {
        ScrollViewReader { scroller in
        List {
            Section {
                row(0) {
                    ChoiceRow(title: "Layout", value: layout.rawValue, isValueHidden: choice?.source == AnyHashable(0)) {
                        Picker("Layout", selection: Binding(get: { layout }, set: { setLayout($0) })) {
                            ForEach(Layout.allCases, id: \.self) { Text($0.rawValue) }
                        }
                        .pickerStyle(.inline)
                    }
                }
            } footer: {
                Text("Nintendo swaps A with B and X with Y. Applies to every controller, in games and menus.")
            }
            Section("Each Button Acts As") {
                ForEach(Array(GameButton.allCases.enumerated()), id: \.element) { index, button in
                    row(index + 1) {
                        ChoiceRow(title: button.title, value: remap.target(button).title,
                                  isValueHidden: choice?.source == AnyHashable(index + 1)) {
                            Picker(button.title, selection: target(of: button)) {
                                ForEach(GameButton.allCases, id: \.self) { Text($0.title) }
                            }
                            .pickerStyle(.inline)
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
        // The focused row in the middle, so its section's title and notes show too.
        .onChange(of: focus) { withAnimation { scroller.scrollTo(focus, anchor: .center) } }
        }
        .navigationTitle("Button Mapping")
        .onChange(of: remap) { ButtonRemap.current = remap }
        .buttonLegend([([.a], "Select"), ([.b], "Back")], reportsLayout: false)
        .choiceMenu($choice)
        .onGamepad { command in
            switch command {
            case .up, .down: focus = FocusMove.next(focus, count: rowCount, columns: 1, command)
            case .select: select()
            case .back: dismiss()
            default: break
            }
        }
    }

    private func row(_ index: Int, @ViewBuilder content: () -> some View) -> some View {
        // The id outermost: under the row background a list doesn't find it, and the list didn't scroll to the focus.
        content().recordsFrame(index, in: rowFrames).focusedRowBackground(gamepad.isActive && focus == index).id(index)
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

    /// The controller's A on a row: its choices to pick from (the layouts, or what a button acts as), or Reset.
    private func select() {
        if focus == 0 {
            let layouts: [Layout] = [.standard, .nintendo]
            let spec = ChoiceMenuSpec(source: focus, options: layouts.map(\.rawValue), selected: layout == .nintendo ? 1 : 0,
                                      anchor: rowFrames.frames[focus] ?? .zero) { setLayout(layouts[$0]) }
            withAnimation(.easeOut(duration: 0.12)) { choice = spec }
        } else if focus < rowCount - 1 {
            let button = GameButton.allCases[focus - 1]
            let spec = ChoiceMenuSpec(source: focus, options: GameButton.allCases.map(\.title),
                                      selected: GameButton.allCases.firstIndex(of: remap.target(button)) ?? 0,
                                      anchor: rowFrames.frames[focus] ?? .zero) { target(of: button).wrappedValue = GameButton.allCases[$0] }
            withAnimation(.easeOut(duration: 0.12)) { choice = spec }
        } else if remap != .standard {
            remap = .standard
        }
    }
}
