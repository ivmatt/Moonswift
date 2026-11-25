import SwiftUI

/// A small menu or message that can be driven by touch or a controller. System alerts can't be
/// focused with a controller on iPad, so the app uses this instead.
struct MenuSpec {
    struct Action {
        let title: String
        var isDestructive = false
        let run: () -> Void
    }

    struct Field {
        let placeholder: String
        let text: Binding<String>
    }

    let title: String
    var message: String?
    /// A text field above the actions, which stay disabled while it's blank ("New Layout").
    var field: Field?
    var actions: [Action]
    /// The last row, which just closes the menu; nil for none.
    var cancelTitle: String?
    /// An X in the top-right corner that just closes the menu (B does the same on a controller).
    var closable = true

    static func error(_ message: String, title: String = "Something went wrong") -> MenuSpec {
        MenuSpec(title: title, message: message, actions: [], cancelTitle: "OK", closable: false) // OK is enough
    }

    static func wakeFailed(_ name: String) -> MenuSpec {
        .error("Check that this device is on its network and that Wake-on-LAN is on in the PC's settings.",
               title: "\(name) didn't wake")
    }

    /// An error's own short title ("Permission needed") when it has one, and its message.
    static func error(_ error: Error) -> MenuSpec {
        .error(error.localizedDescription, title: (error as? TitledError)?.title ?? "Something went wrong")
    }
}

/// An error with a short title of its own, for the box that shows it.
nonisolated protocol TitledError: Error {
    var title: String { get }
}

extension View {
    /// Shows `menu` over this view while it's non-nil.
    func actionMenu(_ menu: Binding<MenuSpec?>) -> some View {
        popup(menu.wrappedValue, onTapOutside: { menu.wrappedValue = nil }) { spec in
            ActionMenu(spec: spec) { menu.wrappedValue = nil }
        }
    }

    /// A spinner and `text` in the popup box while `text` is non-nil ("Quitting…").
    func busyBox(_ text: String?) -> some View {
        popup(text) { text in ProgressView(text).padding(24).popupBox() }
    }

    /// The look every popup box shares.
    func popupBox() -> some View { glassEffect(.regular, in: .rect(cornerRadius: 28)) }

    /// A dimmed backdrop and a box that fades in growing from 95%, and leaves the same way, while `item` is non-nil.
    private func popup<Item, Box: View>(_ item: Item?, onTapOutside: (() -> Void)? = nil,
                                        @ViewBuilder box: @escaping (Item) -> Box) -> some View {
        overlay {
            ZStack {
                if item != nil {
                    Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { onTapOutside?() }.transition(.opacity)
                }
                if let item { box(item).transition(.opacity.combined(with: .scale(scale: 0.95))) }
            }
            .animation(.easeInOut(duration: 0.25), value: item != nil)
            // Centred on the screen, not between the Duo's one-sided tab rail and the far edge. Still clear of the keyboard.
            .ignoresSafeArea(.container, edges: .horizontal)
        }
    }
}

private struct ActionMenu: View {
    let spec: MenuSpec
    let dismiss: () -> Void
    @Environment(GamepadInput.self) private var gamepad
    @State private var focus = 0
    @FocusState private var isTyping: Bool

    /// The spec's actions plus Cancel (or OK) last.
    private var rows: [MenuSpec.Action] { spec.actions + (spec.cancelTitle.map { [MenuSpec.Action(title: $0) {}] } ?? []) }

    var body: some View {
        VStack(spacing: 12) {
            Text(spec.title).font(.headline).multilineTextAlignment(.center)
                .padding(.horizontal, spec.closable ? 28 : 0) // keep long titles clear of the X
            if let message = spec.message {
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let field = spec.field {
                TextField(field.placeholder, text: field.text)
                    .textFieldStyle(.roundedBorder)
                    .focused($isTyping)
                    .onAppear { isTyping = true }
            }
            ForEach(rows.indices, id: \.self) { index in
                Button { choose(index) } label: {
                    Text(rows[index].title).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(rows[index].isDestructive ? .red : .primary)
                .disabled(index < spec.actions.count && isBlank)
                .focusRing(gamepad.isActive && focus == index, cornerRadius: 20)
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
        .overlay(alignment: .topTrailing) {
            if spec.closable {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 32, height: 32)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .tint(.secondary)
                .padding(12)
                .accessibilityLabel("Close")
            }
        }
        .popupBox()
        .padding()
        // Its own hints over the page's, which all just close it. Behind the box so the guide's room doesn't pad it.
        .background { Color.clear.buttonGuide([([.a], "Select"), ([.b], "Close")], reportsLayout: false) }
        .onGamepad { command in
            switch command {
            case .up, .down: focus = FocusMove.next(focus, count: rows.count, columns: 1, command)
            case .select: choose(focus)
            case .back, .menu, .alternate, .options: dismiss() // View closes what it opened (Library's filter menu)
            case .left, .right, .streamMenu, .settings, .previousTab, .nextTab: break
            }
        }
    }

    private var isBlank: Bool { spec.field?.text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty ?? false }

    private func choose(_ index: Int) {
        guard index >= spec.actions.count || !isBlank else { return }
        dismiss()
        rows[index].run()
    }
}
