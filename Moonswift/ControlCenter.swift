import SwiftUI

/// The stream's control panel, pulled out from the right edge (a three-finger swipe left, which it follows) or opened
/// with Menu + View. Two tabs, switched with the bumpers: Actions (key shortcuts for the host, the clipboard, Disconnect
/// and Quit) and Quick Settings (what changes without a reconnect, and More Settings for the rest). B (or Menu + View,
/// or a tap on the game) closes it.
enum StreamPanel { case actions, settings }

/// The panel itself: Liquid Glass down the right side, with the tabs on top; it stays put while they switch.
struct ControlPanel<Content: View>: View {
    static var width: CGFloat { 440 }
    /// The panel and its margin: how far it slides.
    static var travel: CGFloat { width + 14 }

    @Binding var tab: StreamPanel
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                tabButton("Actions", .actions)
                tabButton("Quick Settings", .settings)
            }
            .padding(5)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 4)
            content
                // Rows fade out at the top and bottom as they scroll, rather than being cut off.
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 14)
                    }
                }
                .padding(.horizontal, -18) // the rows' own margin (room for the focus ring) reaches into the panel's
        }
        .padding(22)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
        .environment(\.colorScheme, .dark)
        .padding([.vertical, .trailing], 14)
    }

    /// Like Settings' Stream | Interface switch: the chosen one sits in a darker capsule.
    private func tabButton(_ title: String, _ value: StreamPanel) -> some View {
        Button { withAnimation(.snappy(duration: 0.25)) { tab = value } } label: {
            Text(title).font(.body.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background { if tab == value { Capsule().fill(.black.opacity(0.35)).matchedGeometryEffect(id: "tab", in: tabs) } }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    @Namespace private var tabs
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
    /// -1: Edit; 0..<tiles: the grid; then Disconnect and Quit.
    @State private var focus = 0
    @State private var sent: String?

    private struct Tile { let name: String, detail: String, run: () -> Void }
    private var tiles: [Tile] {
        shortcuts.pinned.map { shortcut in Tile(name: shortcut.name, detail: shortcut.keys) { press(shortcut) } }
            + [Tile(name: "Copy from Host", detail: "Clipboard", run: copyFromHost),
               Tile(name: "Send Clipboard", detail: "To the host", run: sendClipboard)]
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
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                            Button(action: tile.run) {
                                VStack(spacing: 3) {
                                    Text(tile.name).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
                                    Text(tile.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, minHeight: 54)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                            .focusRing(isFocused(index), cornerRadius: 16)
                            .id(index)
                        }
                    }
                    VStack(spacing: 10) { // centred and not full width, so the highlight's grow stays inside the panel
                        bottomButton("Disconnect", index: tiles.count, action: disconnect)
                        bottomButton("Quit Game", index: tiles.count + 1, isDestructive: true, action: quit)
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

    private func bottomButton(_ title: String, index: Int, isDestructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline).frame(width: 220, height: 46).contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isDestructive ? .red : .primary)
        .glassEffect(.regular.interactive(), in: .capsule)
        .focusRing(isFocused(index), cornerRadius: .infinity)
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
        let count = tiles.count, lastRowStart = (count - 1) / 2 * 2
        focus = min(focus, count + 1) // unpinning shortcuts shortens the grid: never past Quit, never a stale Quit
        let inGrid = (0..<count).contains(focus)
        switch command {
        case .back, .streamMenu: close()
        case .previousTab, .nextTab: tab = .settings
        case .up:
            if focus == count + 1 { focus = count } else if focus == count { focus = lastRowStart }
            else if inGrid { focus = focus >= 2 ? focus - 2 : -1 }
        case .down:
            if focus == -1 { focus = 0 } else if inGrid { focus = focus + 2 < count ? focus + 2 : count }
            else if focus == count { focus = count + 1 }
        case .left: if inGrid, focus % 2 == 1 { focus -= 1 }
        case .right: if inGrid, focus % 2 == 0, focus + 1 < count { focus += 1 }
        case .select:
            if focus == -1 { editShortcuts() } else if inGrid { tiles[focus].run() } else if focus == count { disconnect() } else { quit() }
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
    private var rows: [Row] { [.bitrate, .overlay, .touch] + (touchMode.usesOnScreenController ? [.layout, .editLayout] : []) + [.more] }
    private var focus: Row { rows[min(focusIndex, rows.count - 1)] }
    @State private var bitrateNote: String?
    @State private var bitrateChange: Task<Void, Never>?

    private var automatic: Int { StreamSettings.bitrate(width: target.width, height: target.height, fps: target.fps) }
    private var shown: Int { bitrate == 0 ? automatic : bitrate }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                StatsLine(text: stats)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Bitrate")
                        Spacer()
                        Text("\(shown / 1000) Mbps" + (bitrate == 0 ? " · Auto" : "")).foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { Double(shown) }, set: { bitrate = StreamSettings.steppedBitrate(Int($0), by: 0) }),
                           in: Double(StreamSettings.bitrateRange.lowerBound)...Double(StreamSettings.bitrateRange.upperBound))
                    if let bitrateNote { Text(bitrateNote).font(.caption).foregroundStyle(.secondary) }
                }
                .panelRow(isFocused(.bitrate))
                Toggle("Performance Overlay", isOn: $showsPerformance).panelRow(isFocused(.overlay))
                VStack(alignment: .leading, spacing: 8) {
                    Text("Touch")
                    Picker("Touch", selection: $touchMode) {
                        ForEach(TouchMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .panelRow(isFocused(.touch))
                if touchMode.usesOnScreenController {
                    HStack {
                        Text("Layout")
                        Spacer()
                        Menu {
                            Picker("Layout", selection: $padLayoutID) {
                                ForEach(padLayouts.layouts) { Text($0.name).tag($0.id) }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(padLayouts.layout(padLayoutID).name)
                                Image(systemName: "chevron.up.chevron.down").font(.footnote.weight(.medium))
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                    .panelRow(isFocused(.layout))
                    Button(action: editLayout) {
                        HStack {
                            Text("Edit Layout")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .panelRow(isFocused(.editLayout))
                }
                Button(action: moreSettings) {
                    HStack {
                        Text("More Settings")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .panelRow(isFocused(.more))
            }
            .padding(.horizontal, 18).padding(.vertical, 16) // room for the focus ring and its 5% grow, clear of the fades
        }
        .scrollIndicators(.hidden)
        .onChange(of: bitrate) { applyBitrate() }
        .onGamepad(handle)
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
        case .up, .down: focusIndex = FocusMove.next(min(focusIndex, rows.count - 1), count: rows.count, columns: 1, command)
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

private extension View {
    /// A panel row: full width, a little padding, and the controller's highlight when it's on it.
    func panelRow(_ isFocused: Bool) -> some View {
        padding(.vertical, 10).padding(.horizontal, 14)
            .background(.white.opacity(isFocused ? 0.12 : 0), in: .rect(cornerRadius: 14))
            .focusRing(isFocused, cornerRadius: 14)
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
