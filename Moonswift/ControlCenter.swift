import SwiftUI

/// The stream's control panel, pulled out from the right edge (a three-finger swipe left, which it follows) or opened
/// with Menu + View. Two tabs, switched with the bumpers: Actions (key shortcuts for the host, the clipboard, Disconnect
/// and Quit) and Quick Settings (what changes without a reconnect, and More Settings for the rest). B (or Menu + View,
/// or a tap on the game) closes it.
enum StreamPanel { case actions, settings }

/// The panel itself: Liquid Glass down the right side, with the tabs on top; it stays put while they switch.
struct ControlPanel<Content: View>: View {
    /// The modules' column, and the page icons beside it.
    static var contentWidth: CGFloat { 316 }
    static var width: CGFloat { contentWidth + 56 }
    /// The panel and its margin: how far it slides.
    static var travel: CGFloat { width + 14 }

    @Binding var tab: StreamPanel
    /// On the left edge: the page icons go on its outer side, the left.
    var isOnLeft = false
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            if isOnLeft { pageIcons }
            content
                // Modules fade out at the top and bottom as they scroll, rather than being cut off.
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 14)
                    }
                }
                .padding(.horizontal, -18) // the modules' own margin (room for the focus ring) reaches into the panel's
                .frame(width: Self.contentWidth)
            if !isOnLeft { pageIcons }
        }
        .padding(.vertical, 22)
        .padding(isOnLeft ? .trailing : .leading, 22)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .environment(\.colorScheme, .dark) // straight on the stream's dim and blur (StreamView): no box of its own
        .padding([.vertical, isOnLeft ? .leading : .trailing], 14)
    }

    /// The pages as small icons down the side, like iOS's Control Center; there's no status bar, so mid-height.
    private var pageIcons: some View {
        VStack(spacing: 18) {
            pageIcon("square.grid.2x2.fill", "Actions", .actions)
            pageIcon("slider.horizontal.3", "Quick Settings", .settings)
        }
        .frame(width: 40)
    }

    private func pageIcon(_ symbol: String, _ title: String, _ value: StreamPanel) -> some View {
        Button { withAnimation(.snappy(duration: 0.25)) { tab = value } } label: {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(tab == value ? Color.white : Color.white.opacity(0.4))
                .frame(width: 40, height: 40)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(tab == value ? .isSelected : [])
    }
}

/// The pinned shortcuts and the clipboard as a grid, Edit above it, Disconnect and Quit under it. Controller: the
/// d-pad moves around them, A presses.
struct ActionsPanel: View {
    @Binding var tab: StreamPanel
    let shortcuts: KeyShortcutStore
    let copyFromHost: () -> Void
    let sendClipboard: () -> Void
    let editShortcuts: () -> Void
    let disconnect: () -> Void
    let quit: () -> Void
    let close: () -> Void

    @Environment(GamepadInput.self) private var gamepad
    /// -1: Edit; 0..<tiles: the shortcuts' grid; then the row of icons (copy, send, disconnect, quit).
    @State private var focus = 0
    @State private var sent: String?

    private struct Tile { let keys: String, name: String, run: () -> Void }
    private var tiles: [Tile] {
        shortcuts.pinned.map { shortcut in Tile(keys: shortcut.keys, name: shortcut.name) { press(shortcut) } }
    }
    /// Under the shortcuts, as icons: the clipboard both ways, then leaving.
    private struct Icon { let symbol: String, label: String, isDestructive: Bool, run: () -> Void }
    private var icons: [Icon] {
        [Icon(symbol: "doc.on.clipboard", label: "Copy from Host", isDestructive: false, run: copyFromHost),
         Icon(symbol: "arrow.up.doc.on.clipboard", label: "Send Clipboard", isDestructive: false, run: sendClipboard),
         Icon(symbol: "rectangle.portrait.and.arrow.right", label: "Disconnect", isDestructive: false, run: disconnect),
         Icon(symbol: "power", label: "Quit Game", isDestructive: true, run: quit)]
    }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(sent.map { "Sent \($0)" } ?? "Shortcuts")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.secondary).contentTransition(.opacity)
                        Spacer()
                        Button("Edit", action: editShortcuts)
                            .buttonStyle(.plain)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .focusRing(isFocused(-1), cornerRadius: .infinity)
                            .id(-1)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                            // Just the keys it presses: its name is for VoiceOver and the editor.
                            Button(action: tile.run) {
                                Text(tile.keys).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                                    .padding(.horizontal, 14)
                                    .frame(maxWidth: .infinity, minHeight: Self.button)
                                    .contentShape(.capsule)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(tile.name)
                            .glassEffect(.regular.interactive(), in: .capsule) // pills, as iOS's wider controls
                            .focusRing(isFocused(index), cornerRadius: .infinity)
                            .id(index)
                        }
                    }
                    HStack(spacing: 18) {
                        ForEach(Array(icons.enumerated()), id: \.offset) { offset, icon in
                            iconButton(icon, index: tiles.count + offset)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
                }
                .padding(.horizontal, 18).padding(.vertical, 16) // room for the focus ring and its 5% grow, clear of the fades
            }
            .scrollIndicators(.hidden)
            .onChange(of: focus) { withAnimation { scroller.scrollTo(focus, anchor: .center) } }
        }
        .onGamepad(handle)
    }

    /// iOS's Control Center sizes, scaled to the panel: round buttons this wide, pills this tall.
    static let button: CGFloat = 62

    private func iconButton(_ icon: Icon, index: Int) -> some View {
        Button(action: icon.run) {
            Image(systemName: icon.symbol).font(.system(size: 24, weight: .medium))
                .frame(width: Self.button, height: Self.button).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(icon.isDestructive ? .red : .primary)
        .glassEffect(.regular.interactive(), in: .circle)
        .focusRing(isFocused(index), cornerRadius: .infinity)
        .accessibilityLabel(icon.label)
        .id(index)
    }

    private func isFocused(_ index: Int) -> Bool { gamepad.isActive && focus == index }

    private func press(_ shortcut: KeyShortcut) {
        Task { await shortcut.send() }
        withAnimation { sent = shortcut.keys }
        Task {
            try? await Task.sleep(for: .seconds(2))
            if sent == shortcut.keys { withAnimation { sent = nil } }
        }
    }

    private func handle(_ command: GamepadCommand) {
        let count = tiles.count, lastRowStart = max(0, (count - 1) / 2 * 2), iconCount = icons.count
        focus = min(focus, count + iconCount - 1) // unpinning shortcuts shortens the grid: never past the last icon
        let inGrid = (0..<count).contains(focus), inIcons = focus >= count
        switch command {
        case .back, .streamMenu: close()
        case .previousTab, .nextTab: tab = .settings
        case .up:
            if inIcons { focus = count > 0 ? lastRowStart : -1 } else if inGrid { focus = focus >= 2 ? focus - 2 : -1 }
        case .down:
            if focus == -1 { focus = count > 0 ? 0 : count } else if inGrid { focus = focus + 2 < count ? focus + 2 : count }
        case .left: if inGrid, focus % 2 == 1 { focus -= 1 } else if inIcons, focus > count { focus -= 1 }
        case .right:
            if inGrid, focus % 2 == 0, focus + 1 < count { focus += 1 } else if inIcons, focus < count + iconCount - 1 { focus += 1 }
        case .select:
            if focus == -1 { editShortcuts() } else if inGrid { tiles[focus].run() } else { icons[focus - count].run() }
        default: break
        }
    }
}

/// What changes without a reconnect: bitrate, the performance overlay and the trackpad; More Settings for the rest.
struct QuickSettingsPanel: View {
    @Binding var tab: StreamPanel
    /// Resolution, codec, frame rate and bitrate now.
    /// Read by its own line, so only that line redraws as the numbers change (not the panel and its menus).
    let stats: () -> String
    let target: StreamTarget
    @Binding var showsPerformance: Bool
    @Binding var touchMode: TouchMode
    /// Changes the running stream's bitrate; returns what happened, to show under the slider.
    let setBitrate: (Int) async -> String
    /// The on-screen controller's layouts, and the one this game uses (shown while Touch is Controller).
    let padLayouts: PadLayoutStore
    @Binding var padLayoutID: String
    let editLayout: () -> Void
    let moreSettings: () -> Void
    let close: () -> Void

    @AppStorage(SettingsKey.bitrate) private var bitrate = 0 // kbps; 0 = automatic
    @Environment(GamepadInput.self) private var gamepad
    @State private var focusIndex = 0

    private enum Row: Hashable { case bitrate, overlay, touch, layout, editLayout, more }
    /// The on-screen controller is showing: Automatic without a game controller, or Controller.
    private var showsPad: Bool { touchMode.resolved(controllerConnected: gamepad.isControllerConnected) == .controller }
    /// In screen order.
    private var rows: [Row] {
        [.bitrate, .overlay, .touch] + (showsPad ? [.layout, .editLayout] : []) + [.more]
    }
    private var focus: Row { rows[min(focusIndex, rows.count - 1)] }
    @State private var bitrateNote: String?
    @State private var bitrateChange: Task<Void, Never>?

    private var automatic: Int { StreamSettings.bitrate(width: target.width, height: target.height, fps: target.fps) }
    private var shown: Int { bitrate == 0 ? automatic : bitrate }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                StatsLine(text: stats)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Bitrate", systemImage: "speedometer").font(.headline)
                        Spacer()
                        Text("\(shown / 1000) Mbps" + (bitrate == 0 ? " · Auto" : "")).foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { Double(shown) }, set: { bitrate = StreamSettings.steppedBitrate(Int($0), by: 0) }),
                           in: Double(StreamSettings.bitrateRange.lowerBound)...Double(StreamSettings.bitrateRange.upperBound))
                        .tint(.white)
                    if let bitrateNote { Text(bitrateNote).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: 28))
                .focusRing(isFocused(.bitrate), cornerRadius: 28)
                button(.overlay, symbol: "chart.bar.xaxis", title: "Performance Overlay", value: showsPerformance ? "On" : "Off",
                       isOn: showsPerformance) { showsPerformance.toggle() }
                pill(.touch, symbol: "hand.tap.fill", title: "Touch", value: touchMode.title) {
                    Picker("Touch", selection: $touchMode) {
                        ForEach(TouchMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                if showsPad {
                    pill(.layout, symbol: "gamecontroller.fill", title: "Controller Layout", value: padLayouts.layout(padLayoutID).name) {
                        Picker("Controller Layout", selection: $padLayoutID) {
                            ForEach(padLayouts.layouts) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                if showsPad { button(.editLayout, symbol: "square.and.pencil", title: "Edit Layout", action: editLayout) }
                button(.more, symbol: "gearshape.fill", title: "More Settings", action: moreSettings)
            }
            .padding(.horizontal, 18).padding(.vertical, 16) // room for the focus ring and its 5% grow, clear of the fades
        }
        .scrollIndicators(.hidden)
        .onChange(of: bitrate) { applyBitrate() }
        .onGamepad(handle)
    }

    /// A pill like iOS's Focus control: an icon in its circle, the setting and its value, a menu of choices.
    private func pill(_ row: Row, symbol: String, title: String, value: String,
                      @ViewBuilder choices: () -> some View) -> some View {
        Menu {
            choices()
        } label: {
            pillLabel(symbol: symbol, title: title, value: value, trailing: "chevron.up.chevron.down")
        }
        .tint(.white) // white, not the accent colour a menu gives its label
        .glassEffect(.regular.interactive(), in: .capsule)
        .focusRing(isFocused(row), cornerRadius: .infinity)
    }

    /// The same pill as a button; a switch's icon circle is white while on, as iOS's are.
    private func button(_ row: Row, symbol: String, title: String, value: String? = nil, isOn: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            pillLabel(symbol: symbol, title: title, value: value, isOn: isOn, trailing: value == nil ? "chevron.right" : nil)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .focusRing(isFocused(row), cornerRadius: .infinity)
    }

    private func pillLabel(symbol: String, title: String, value: String?, isOn: Bool = false, trailing: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isOn ? Color.black : .white)
                .frame(width: 40, height: 40)
                .background(isOn ? .white : .white.opacity(0.18), in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                if let value { Text(value).font(.footnote).foregroundStyle(.white.opacity(0.7)) }
            }
            Spacer(minLength: 0)
            if let trailing { Image(systemName: trailing).font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.7)) }
        }
        .foregroundStyle(.white)
        .padding(.leading, 11).padding(.trailing, 18)
        .frame(maxWidth: .infinity, minHeight: ActionsPanel.button)
        .contentShape(.capsule)
    }

    private func isFocused(_ row: Row) -> Bool { gamepad.isActive && focus == row }

    /// The next layout (or the one before), for the controller's left and right on the Layout row.
    private func cycledLayout(by step: Int) {
        let all = padLayouts.layouts, index = all.firstIndex { $0.id == padLayoutID } ?? 0
        padLayoutID = all[(index + step + all.count) % all.count].id
    }

    private func cycled(_ mode: TouchMode, by step: Int) -> TouchMode {
        let all = TouchMode.allCases, index = all.firstIndex(of: mode) ?? 0
        return all[(index + step + all.count) % all.count]
    }

    /// Sends the new bitrate once the slider or controller has rested for a moment.
    private func applyBitrate() {
        let kbps = StreamSettings.effectiveBitrate(saved: bitrate, width: target.width, height: target.height, fps: target.fps)
        bitrateChange = applyLiveBitrate(kbps, replacing: bitrateChange, send: setBitrate) { bitrateNote = $0 }
    }

    private func handle(_ command: GamepadCommand) {
        switch command {
        case .back, .streamMenu: close()
        case .previousTab, .nextTab: tab = .actions
        case .up, .down:
            let index = rows.firstIndex(of: focus) ?? 0
            focusIndex = min(max(index + (command == .down ? 1 : -1), 0), rows.count - 1)
        case .left, .right:
            let step = command == .right ? 1 : -1
            switch focus {
            case .bitrate: bitrate = StreamSettings.steppedBitrate(shown, by: step)
            case .touch: touchMode = cycled(touchMode, by: step)
            case .layout: cycledLayout(by: step)
            default: break
            }
        case .select:
            switch focus {
            case .overlay: showsPerformance.toggle()
            case .touch: touchMode = cycled(touchMode, by: 1)
            case .layout: cycledLayout(by: 1)
            case .editLayout: editLayout()
            case .more: moreSettings()
            case .bitrate: break
            }
        default: break
        }
    }
}

/// A three-finger drag sideways over the open panel or the game beside it: how far right while it moves, and where it
/// ended. UIKit's recognizer, so one- and two-finger touches still scroll, slide and press as usual.
struct ThreeFingerSwipe: UIGestureRecognizerRepresentable {
    let moved: (CGFloat) -> Void
    let ended: (CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.minimumNumberOfTouches = 3
        recognizer.maximumNumberOfTouches = 3
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let dx = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed: moved(dx)
        case .ended: ended(dx)
        case .cancelled, .failed: ended(0)
        default: break
        }
    }
}

private struct StatsLine: View {
    let text: () -> String

    var body: some View {
        let text = text()
        if !text.isEmpty { Text(text).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14) }
    }
}
