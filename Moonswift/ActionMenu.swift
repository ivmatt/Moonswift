import SwiftUI

/// A small menu or message that can be driven by touch or a controller. System alerts can't be
/// focused with a controller on iPad, so the app uses this instead.
struct MenuSpec {
    struct Action {
        let title: String
        var isDestructive = false
        let run: () -> Void
    }

    let title: String
    var message: String?
    var actions: [Action]
    /// The last row, which just closes the menu; nil for none.
    var cancelTitle: String?
    /// An X in the top-right corner that just closes the menu (B does the same on a controller).
    var closable = true

    static func error(_ message: String, title: String = "Something went wrong") -> MenuSpec {
        MenuSpec(title: title, message: message, actions: [], cancelTitle: "OK", closable: false) // OK is enough
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
        overlay {
            if let spec = menu.wrappedValue {
                ActionMenu(spec: spec) { menu.wrappedValue = nil }
            }
        }
    }
}

private struct ActionMenu: View {
    let spec: MenuSpec
    let dismiss: () -> Void
    @Environment(GamepadInput.self) private var gamepad
    @State private var focus = 0

    /// The spec's actions plus Cancel (or OK) last.
    private var rows: [MenuSpec.Action] { spec.actions + (spec.cancelTitle.map { [MenuSpec.Action(title: $0) {}] } ?? []) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: dismiss)
            VStack(spacing: 12) {
                Text(spec.title).font(.headline).multilineTextAlignment(.center)
                    .padding(.horizontal, spec.closable ? 28 : 0) // keep long titles clear of the X
                if let message = spec.message {
                    Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                ForEach(rows.indices, id: \.self) { index in
                    Button { choose(index) } label: {
                        Text(rows[index].title).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(rows[index].isDestructive ? .red : .primary)
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
            .background(.regularMaterial, in: .rect(cornerRadius: 28))
            .padding()
        }
        .onGamepad { command in
            switch command {
            case .up, .down: focus = FocusMove.next(focus, count: rows.count, columns: 1, command)
            case .select: choose(focus)
            case .back, .menu, .alternate, .options: dismiss() // View closes what it opened (Library's filter menu)
            case .left, .right, .streamMenu, .settings, .previousTab, .nextTab: break
            }
        }
    }

    private func choose(_ index: Int) {
        dismiss()
        rows[index].run()
    }
}
