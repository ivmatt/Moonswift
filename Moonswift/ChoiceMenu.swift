import SwiftUI

/// A setting's choices for the controller, drawn like the system's Liquid Glass menu (which only touch can open or
/// move through): a glass panel beside the setting's row, a tick by the current choice, and a soft light pill on the
/// highlighted one. Up/down move, A picks, B closes; a tap picks too, and a tap outside closes.
struct ChoiceMenuSpec {
    /// The row it opened from: its value fades out while the menu is open (`ChoiceRow`).
    let source: AnyHashable
    let options: [String]
    /// The current choice: ticked, and where the highlight starts; -1 for actions rather than choices (none ticked).
    let selected: Int
    /// The setting's row, in the `ChoiceMenuSpec.space` coordinate space: the menu opens beside it.
    let anchor: CGRect
    let pick: (Int) -> Void

    static let space = "choiceMenu"
}

/// Where each row is, for a choice menu to open beside; not observed, so scrolling doesn't redraw the page.
final class RowFrames {
    var frames: [AnyHashable: CGRect] = [:]
}

extension View {
    /// Records this row's frame in `frames`, for a choice menu to open beside.
    func recordsFrame(_ id: AnyHashable, in frames: RowFrames) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChoiceMenuSpec.space)) } action: { frames.frames[id] = $0 }
    }

    /// Shows `menu` while it's non-nil, beside its row (rows record their frames with `recordsFrame`).
    func choiceMenu(_ menu: Binding<ChoiceMenuSpec?>) -> some View {
        coordinateSpace(.named(ChoiceMenuSpec.space))
            .overlay {
                // No transition of its own: it grows out of the row and shrinks back into it (see ChoiceMenu). Once it's
                // gone, the row's value fades back in.
                if let spec = menu.wrappedValue {
                    ChoiceMenu(spec: spec) { withAnimation(.easeOut(duration: 0.12)) { menu.wrappedValue = nil } }
                }
            }
    }
}

/// A setting with choices: its title, and its value, which opens the system's menu by touch. Its value fades out while
/// the controller's ChoiceMenu is open over it, and back in once it closes.
struct ChoiceRow<Choices: View>: View {
    let title: String
    let value: String
    var isValueHidden = false
    /// The choices for the system menu: a `Picker` with `.pickerStyle(.inline)`, so the current one has its tick.
    @ViewBuilder var choices: Choices

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Menu { choices } label: {
                HStack(spacing: 4) {
                    Text(value)
                    Image(systemName: "chevron.up.chevron.down").font(.footnote.weight(.medium))
                }
            }
            .tint(.secondary) // grey like the system's picker value, not the accent colour
            .opacity(isValueHidden ? 0 : 1)
        }
    }
}

private struct ChoiceMenu: View {
    let spec: ChoiceMenuSpec
    let dismiss: () -> Void
    @Environment(GamepadInput.self) private var gamepad
    @State private var focus: Int
    /// Grown out of the row's value to full size; it starts and ends shrunk into it.
    @State private var isOpen = false
    /// Closing: the controller goes back to the page at once, not after the menu has shrunk away.
    @State private var isClosing = false

    private static let rowHeight: CGFloat = 44, width: CGFloat = 230, inset: CGFloat = 8, margin: CGFloat = 12
    /// The size it grows from: about the row's value, at the row's right end.
    private static let seed = CGSize(width: 120, height: 34)

    init(spec: ChoiceMenuSpec, dismiss: @escaping () -> Void) {
        self.spec = spec
        self.dismiss = dismiss
        _focus = State(initialValue: max(spec.selected, 0)) // -1: nothing ticked, the first highlighted
    }

    var body: some View {
        GeometryReader { proxy in
            // The row's frame in this view's own coordinates, whatever the page's bars and insets.
            let origin = proxy.frame(in: .named(ChoiceMenuSpec.space)).origin
            let row = spec.anchor.offsetBy(dx: -origin.x, dy: -origin.y)
            let height = CGFloat(spec.options.count) * Self.rowHeight + 2 * Self.inset
            // Over the row's right end, covering its value, like the system's; kept on screen.
            let right = min(row.maxX, proxy.size.width - Self.margin)
            let top = max(Self.margin, min(row.minY - 6, proxy.size.height - height - Self.margin))
            let size = isOpen ? CGSize(width: Self.width, height: height) : Self.seed
            let y = isOpen ? top + height / 2 : row.midY
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(.rect).onTapGesture { close() }
                panel
                    .frame(width: size.width, height: size.height, alignment: .topTrailing)
                    .clipShape(.rect(cornerRadius: isOpen ? 26 : Self.seed.height / 2))
                    .glassEffect(.regular, in: .rect(cornerRadius: isOpen ? 26 : Self.seed.height / 2))
                    .opacity(isOpen ? 1 : 0) // grows and fades in together, shrinks and fades out together
                    .position(x: right - size.width / 2, y: y)
            }
        }
        .onAppear { withAnimation(.spring(duration: 0.3, bounce: 0.2)) { isOpen = true } } // a quick, springy grow
        .onGamepad(isActive: !isClosing) { command in
            switch command {
            case .up, .down: focus = FocusMove.next(focus, count: spec.options.count, columns: 1, command)
            case .select: choose(focus)
            case .back, .options, .settings: close()
            default: break
            }
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            ForEach(spec.options.indices, id: \.self) { index in
                Button { choose(index) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark").font(.footnote.weight(.semibold))
                            .opacity(index == spec.selected ? 1 : 0)
                            .frame(width: 16)
                        Text(spec.options[index])
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: Self.rowHeight)
                    .contentShape(.capsule)
                    .background {
                        Capsule().fill(.white.opacity(0.18)) // the system menu's highlight
                            .opacity(gamepad.isActive && index == focus ? 1 : 0)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Self.inset)
        .frame(width: Self.width) // laid out at full size while it grows, so nothing reflows
        .opacity(isOpen ? 1 : 0) // the choices fade in as it grows, out as it shrinks
        .animation(.snappy(duration: 0.15), value: focus)
    }

    private func choose(_ index: Int) {
        spec.pick(index)
        close()
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        withAnimation(.easeIn(duration: 0.16)) { isOpen = false } completion: { dismiss() }
    }
}
