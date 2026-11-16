import SwiftUI
import UIKit

/// A control on the on-screen controller (Touch: Controller).
nonisolated enum PadControl: String, Codable, CaseIterable {
    case leftStick, rightStick, dpad, a, b, x, y, lb, rb, lt, rt, view, menu, l3, r3

    var isStick: Bool { self == .leftStick || self == .rightStick }
    /// A, B, X and Y by where they sit: A at the bottom, B right, X left, Y top (Xbox's order; the host's too).
    var isFaceButton: Bool { [.a, .b, .x, .y].contains(self) }
    /// Height ÷ width: bumpers are wide and short, triggers about square, like on a controller.
    var aspect: CGFloat {
        switch self {
        case .lb, .rb: 0.675
        case .lt, .rt: 1.02
        default: 1
        }
    }
    /// Bumpers and triggers are rounded rectangles; everything else is round (or the d-pad's arms).
    var isRoundedRect: Bool { [.lb, .rb, .lt, .rt].contains(self) }

    /// Its name in the editor's Add menu, in the layout's labels.
    func name(_ labels: PadLabels) -> String {
        switch self {
        case .leftStick: "Left Stick"
        case .rightStick: "Right Stick"
        case .dpad: "D-Pad"
        case .view: "View"
        case .menu: "Menu"
        default:
            switch labels.label(self) {
            case .text(let text): text
            case .symbol: labels == .playstation ? ["a": "Cross", "b": "Circle", "x": "Square", "y": "Triangle"][rawValue] ?? rawValue : rawValue
            }
        }
    }
}

/// What's written on the buttons: an Xbox, PlayStation or Nintendo controller's. Only the labels change: a button
/// sends what the button in its place on an Xbox controller sends, as the host expects.
nonisolated enum PadLabels: String, Codable, CaseIterable {
    case xbox, playstation, nintendo

    var title: String {
        switch self {
        case .xbox: "Xbox"
        case .playstation: "PlayStation"
        case .nintendo: "Nintendo"
        }
    }

    enum Label { case text(String), symbol(String) }

    func label(_ control: PadControl) -> Label {
        switch (self, control) {
        case (.playstation, .a): .symbol("xmark")
        case (.playstation, .b): .symbol("circle")
        case (.playstation, .x): .symbol("square")
        case (.playstation, .y): .symbol("triangle")
        case (.playstation, .lb): .text("L1")
        case (.playstation, .rb): .text("R1")
        case (.playstation, .lt): .text("L2")
        case (.playstation, .rt): .text("R2")
        case (.nintendo, .a): .text("B") // bottom
        case (.nintendo, .b): .text("A") // right
        case (.nintendo, .x): .text("Y") // left
        case (.nintendo, .y): .text("X") // top
        case (.nintendo, .lb): .text("L")
        case (.nintendo, .rb): .text("R")
        case (.nintendo, .lt): .text("ZL")
        case (.nintendo, .rt): .text("ZR")
        case (_, .lb): .text("LB")
        case (_, .rb): .text("RB")
        case (_, .lt): .text("LT")
        case (_, .rt): .text("RT")
        case (_, .view): .symbol("rectangle.on.rectangle")
        case (_, .menu): .symbol("line.3.horizontal")
        default: .text(control.rawValue.uppercased())
        }
    }
}

/// One control's place, in points from the nearest edges of the controller's area (the screen inside its safe area),
/// so a layout keeps its shape on any screen: A, B, X and Y stay evenly apart on a tall screen or a wide one.
nonisolated struct PadItem: Codable, Hashable {
    enum Across: String, Codable { case leading, center, trailing }
    enum Down: String, Codable { case top, bottom }

    var control: PadControl
    var across: Across
    var down: Down
    /// From the leading or trailing edge to the centre (from the middle, rightward, for `center`).
    var x: CGFloat
    /// From the top or bottom edge to the centre.
    var y: CGFloat
    /// Its width in points; its height follows from its shape.
    var size: CGFloat

    init(control: PadControl, _ across: Across, _ down: Down, x: CGFloat, y: CGFloat, size: CGFloat) {
        self.control = control
        self.across = across
        self.down = down
        self.x = x
        self.y = y
        self.size = size
    }

    func center(in area: CGSize) -> CGPoint {
        let cx = switch across {
        case .leading: x
        case .center: area.width / 2 + x
        case .trailing: area.width - x
        }
        return CGPoint(x: cx, y: down == .top ? y : area.height - y)
    }

    func frame(in area: CGSize) -> CGRect {
        let center = center(in: area), height = size * control.aspect
        return CGRect(x: center.x - size / 2, y: center.y - height / 2, width: size, height: height)
    }

    /// The same control with its centre at `center`, measured from whichever edges are nearest now (the middle,
    /// across, for anything in its central fifth).
    func moved(to center: CGPoint, in area: CGSize) -> PadItem {
        var item = self
        let middle = area.width / 2
        if abs(center.x - middle) < area.width * 0.1 {
            (item.across, item.x) = (.center, center.x - middle)
        } else if center.x < middle {
            (item.across, item.x) = (.leading, center.x)
        } else {
            (item.across, item.x) = (.trailing, area.width - center.x)
        }
        (item.down, item.y) = center.y < area.height / 2 ? (.top, center.y) : (.bottom, area.height - center.y)
        return item
    }

    /// Its position on a `step`-point grid, measured from the same edges.
    func snapped(to step: CGFloat) -> PadItem {
        var item = self
        item.x = (x / step).rounded() * step
        item.y = (y / step).rounded() * step
        return item
    }

    /// Layouts saved before positions were in points held shares of the area: read them as if on an 888 × 600 one.
    private enum CodingKeys: String, CodingKey { case control, across, down, x, y, size }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        control = try values.decode(PadControl.self, forKey: .control)
        size = try values.decode(CGFloat.self, forKey: .size)
        let x = try values.decode(CGFloat.self, forKey: .x), y = try values.decode(CGFloat.self, forKey: .y)
        if let across = try values.decodeIfPresent(Across.self, forKey: .across),
           let down = try values.decodeIfPresent(Down.self, forKey: .down) {
            (self.across, self.down, self.x, self.y) = (across, down, x, y)
        } else {
            let area = CGSize(width: 888, height: 600)
            self = PadItem(control: control, .leading, .top, x: 0, y: 0, size: size)
                .moved(to: CGPoint(x: x * area.width, y: y * area.height), in: area)
        }
    }
}

/// A named set of controls and where they sit, with how they look.
nonisolated struct PadLayout: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var items: [PadItem]
    /// How solid the controls are drawn, 0.2...1.
    var opacity: Double = 0.6
    /// A stick appears wherever a thumb lands on its side of the screen, outside the other controls.
    var floatingLeftStick = false
    var floatingRightStick = false
    /// Liquid Glass controls (opt in: plain ones cost less while streaming).
    var glass = false
    /// Seconds untouched before the controls fade away (for cutscenes); 0: never. A touch brings them back.
    var hideAfter = 0
    /// The actions row along the top keeps the top strip to itself (controls stay below it). Control Center always
    /// leads it, so there's always a way to the control panel; these follow (Quick Settings, the keyboard,
    /// shortcuts…), yours to add, remove and order.
    var actions: [GestureAction] = PadLayout.defaultActions
    static let defaultActions: [GestureAction] = [.quickSettings, .keyboard, .editLayout]
    /// The row stays out of sight until its strip is touched, then shows for a few seconds (less distracting over a
    /// game, especially at a high opacity).
    var actionsOnTouch = false
    /// What the row shows: Control Center, then the layout's own.
    var rowActions: [GestureAction] { [.controlPanel] + actions }
    /// The top strip's height, in points: controls sit below it.
    static let actionStrip: CGFloat = 56

    /// A stick that floats has no fixed place: it's drawn (and touched) only where a thumb lands.
    func isFloating(_ control: PadControl) -> Bool {
        (control == .leftStick && floatingLeftStick) || (control == .rightStick && floatingRightStick)
    }
    var labels = PadLabels.xbox

    init(id: String, name: String, items: [PadItem]) {
        self.id = id
        self.name = name
        self.items = items
    }

    /// Everything but the stick clicks: sticks low on each side, the d-pad and the A, B, X, Y diamond inside them
    /// (evenly apart), triggers and bumpers in the top corners and View and Menu between them, all below the actions
    /// row's strip.
    static let standard = PadLayout(id: "standard", name: "Standard", items: [
        PadItem(control: .leftStick, .leading, .bottom, x: 110, y: 150, size: 130),
        PadItem(control: .dpad, .leading, .bottom, x: 270, y: 100, size: 150),
        PadItem(control: .a, .trailing, .bottom, x: 120, y: 107, size: 56),
        PadItem(control: .b, .trailing, .bottom, x: 62, y: 165, size: 56),
        PadItem(control: .x, .trailing, .bottom, x: 178, y: 165, size: 56),
        PadItem(control: .y, .trailing, .bottom, x: 120, y: 223, size: 56),
        PadItem(control: .rightStick, .trailing, .bottom, x: 280, y: 100, size: 120),
        // Below the actions row's strip (56 points).
        PadItem(control: .lt, .leading, .top, x: 50, y: 100, size: 72),
        PadItem(control: .lb, .leading, .top, x: 136, y: 88, size: 72),
        PadItem(control: .rb, .trailing, .top, x: 136, y: 88, size: 72),
        PadItem(control: .rt, .trailing, .top, x: 50, y: 100, size: 72),
        PadItem(control: .view, .center, .top, x: -40, y: 90, size: 44),
        PadItem(control: .menu, .center, .top, x: 40, y: 90, size: 44),
    ])

    private enum CodingKeys: String, CodingKey { case id, name, items, opacity, floatingLeftStick, floatingRightStick, glass, labels, hideAfter, actions, actionsOnTouch }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        items = try values.decode([PadItem].self, forKey: .items)
        opacity = try values.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.6
        floatingLeftStick = try values.decodeIfPresent(Bool.self, forKey: .floatingLeftStick) ?? false
        floatingRightStick = try values.decodeIfPresent(Bool.self, forKey: .floatingRightStick) ?? false
        glass = try values.decodeIfPresent(Bool.self, forKey: .glass) ?? false
        labels = try values.decodeIfPresent(PadLabels.self, forKey: .labels) ?? .xbox
        hideAfter = try values.decodeIfPresent(Int.self, forKey: .hideAfter) ?? 0
        actionsOnTouch = try values.decodeIfPresent(Bool.self, forKey: .actionsOnTouch) ?? false
        // Control Center was once one of these, removable: it's always first now, apart from them.
        actions = (try values.decodeIfPresent([String].self, forKey: .actions)?.compactMap(GestureAction.init(stored:))
            ?? Self.defaultActions).filter { $0 != .controlPanel }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(items, forKey: .items)
        try values.encode(opacity, forKey: .opacity)
        try values.encode(floatingLeftStick, forKey: .floatingLeftStick)
        try values.encode(floatingRightStick, forKey: .floatingRightStick)
        try values.encode(glass, forKey: .glass)
        try values.encode(labels, forKey: .labels)
        try values.encode(hideAfter, forKey: .hideAfter)
        try values.encode(actions.map(\.stored), forKey: .actions)
        try values.encode(actionsOnTouch, forKey: .actionsOnTouch)
    }
}

/// What the on-screen controller shows pressed and where its sticks are, for drawing.
@Observable final class PadPresses {
    var buttons: Set<PadControl> = []
    var dpad = (up: false, down: false, left: false, right: false)
    /// -1...1 each way, up negative (as on screen).
    var leftStick = CGPoint.zero
    var rightStick = CGPoint.zero
    /// Where a floating stick sits while a thumb holds it.
    var floatingLeft: CGPoint?
    var floatingRight: CGPoint?
    /// A finger is on a control: the controls don't hide while one is held.
    var isHeld = false
    /// Bumped on every touch, to bring hidden controls back and restart their idle time.
    var touches = 0

    /// The pad as the host gets it.
    var snapshot: PadSnapshot {
        var pad = PadSnapshot(a: buttons.contains(.a), b: buttons.contains(.b), x: buttons.contains(.x), y: buttons.contains(.y),
                              up: dpad.up, down: dpad.down, left: dpad.left, right: dpad.right,
                              leftShoulder: buttons.contains(.lb), rightShoulder: buttons.contains(.rb),
                              leftStickClick: buttons.contains(.l3), rightStickClick: buttons.contains(.r3),
                              menu: buttons.contains(.menu), options: buttons.contains(.view))
        pad.leftTrigger = buttons.contains(.lt) ? 1 : 0
        pad.rightTrigger = buttons.contains(.rt) ? 1 : 0
        pad.leftStick = (Float(leftStick.x), Float(-leftStick.y))
        pad.rightStick = (Float(rightStick.x), Float(-rightStick.y))
        return pad
    }
}

/// The on-screen controller: drawn in SwiftUI, touched through a UIKit view (many fingers at once, each following
/// its own control). Touches that miss every control pass through to the stream's own touch layer (for gestures).
struct OnScreenController: View {
    let layout: PadLayout
    /// The game isn't taking input (a menu or panel is up): touches are let go and ignored.
    let isPaused: Bool
    /// Bumped by touches elsewhere on the stream: they bring the controls back too.
    var wake = 0
    /// Where the stream's touch layer finds this controller, for floating sticks.
    var router: PadTouchRouter?
    /// The key shortcuts, for the actions row's shortcut buttons.
    var shortcuts: [KeyShortcut] = []
    /// An actions-row button was tapped.
    var perform: (GestureAction) -> Void = { _ in }
    let send: (PadSnapshot) -> Void
    @State private var presses = PadPresses()
    @State private var isIdle = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // One container, so the system draws all the glass together (cheaper over a live game).
                GlassEffectContainer(spacing: 0) { // 0: pieces near each other don't melt together
                    ZStack { controls(.body, in: proxy.size) }
                }
                // Floating sticks come and go with the thumb: in a container of their own, as a glass piece joining
                // the controls' container made the system redraw all of them (they went dark).
                GlassEffectContainer(spacing: 0) {
                    ZStack { floatingSticks(.body, in: proxy.size) }
                }
                // Labels above the glass, not in it: glass blurs what it holds.
                controls(.label, in: proxy.size)
                floatingSticks(.label, in: proxy.size)
            }
            // Only the drawing fades: iOS doesn't send touches to what's invisible, and hidden controls must still work.
            .opacity(drawnOpacity)
            .overlay { PadTouchLayer(router: router, layout: layout, presses: presses, isPaused: isPaused, send: send) }
            .overlay(alignment: .top) {
                ActionsRow(layout: layout, shortcuts: shortcuts, faceOpacity: drawnOpacity) { action in
                    presses.touches += 1 // a tap wakes hidden controls too
                    perform(action)
                }
            }
            .animation(.easeInOut(duration: isIdle ? 0.6 : 0.2), value: isIdle)
        }
        // Hide When Idle: fades away after its time untouched (never while a finger is on a control); any touch,
        // on a control or elsewhere on the stream, brings it back. Hidden controls still work where they were.
        .task(id: "\(presses.touches)|\(wake)|\(layout.hideAfter)") {
            isIdle = false
            guard layout.hideAfter > 0 else { return }
            repeat { try? await Task.sleep(for: .seconds(layout.hideAfter)) } while presses.isHeld && !Task.isCancelled
            if !Task.isCancelled { isIdle = true }
        }
    }

    private var drawnOpacity: Double { isIdle ? 0 : layout.opacity }

    /// Every placed control's body or label (a floating stick has no place: see floatingSticks).
    @ViewBuilder private func controls(_ part: PadControlView.Part, in area: CGSize) -> some View {
        ForEach(layout.items.filter { !layout.isFloating($0.control) }, id: \.control) { item in
            PadControlView(item: item, layout: layout, area: area, presses: presses, part: part)
        }
    }

    /// A floating stick where its thumb is, while one holds it.
    @ViewBuilder private func floatingSticks(_ part: PadControlView.Part, in area: CGSize) -> some View {
        ForEach([(PadControl.leftStick, presses.floatingLeft), (.rightStick, presses.floatingRight)], id: \.0) { control, center in
            if let center, let stick = layout.items.first(where: { $0.control == control }) {
                PadControlView(item: stick.moved(to: center, in: area), layout: layout, area: area,
                               presses: presses, part: part)
            }
        }
    }
}

/// The row along the top: one button per action, in the layout's look.
struct ActionsRow: View {
    let layout: PadLayout
    let shortcuts: [KeyShortcut]
    /// The faces fade with the controls; the buttons stay tappable even when they're faded out.
    var faceOpacity: Double = 1
    let perform: (GestureAction) -> Void
    /// Show on Touch: shown for a few seconds after its strip is touched.
    @State private var isRevealed = false
    @State private var revealTime = 0

    private var isShown: Bool { !layout.actionsOnTouch || isRevealed }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(layout.rowActions.enumerated()), id: \.offset) { _, action in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    revealTime += 1 // stays up a little longer after each use
                    perform(action)
                } label: {
                    ActionButtonFace(action: action, shortcuts: shortcuts, isGlass: layout.glass)
                }
                .buttonStyle(ActionPressStyle(opacity: faceOpacity))
                .disabled(!isShown) // hidden: the first touch only shows it
            }
        }
        .opacity(isShown ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: isShown)
        .frame(maxWidth: .infinity)
        .frame(height: PadLayout.actionStrip)
        .background {
            if !isShown {
                // The whole strip, out of sight: a touch on it shows the row.
                Color.clear.contentShape(.rect).onTapGesture { revealTime += 1 }
            }
        }
        .task(id: revealTime) {
            guard layout.actionsOnTouch, revealTime > 0 else { return }
            isRevealed = true
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { isRevealed = false }
        }
    }
}

/// An action button's face pressed: lit like a pressed control, and a little smaller.
private struct ActionPressStyle: ButtonStyle {
    let opacity: Double

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.actionIsPressed, configuration.isPressed)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .opacity(opacity)
            .contentShape(.capsule)
    }
}

extension EnvironmentValues {
    @Entry var actionIsPressed = false
}

/// One action's face: a round button with its symbol, or a capsule with a shortcut's keys; label above the body.
struct ActionButtonFace: View {
    let action: GestureAction
    let shortcuts: [KeyShortcut]
    let isGlass: Bool
    @Environment(\.actionIsPressed) private var isPressed

    var body: some View {
        let label = action.rowLabel(shortcuts)
        let isCapsule = label.text != nil
        Group {
            if let text = label.text {
                Text(text).font(.footnote.weight(.semibold)).padding(.horizontal, 14)
            } else if let symbol = label.symbol {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(minWidth: 42, minHeight: 42)
        .background {
            if isCapsule {
                PadSurface(shape: Capsule(), isGlass: isGlass, isPressed: isPressed)
            } else {
                PadSurface(shape: Circle(), isGlass: isGlass, isPressed: isPressed)
            }
        }
        .contentShape(.capsule)
    }
}

/// One control, drawn plain or in Liquid Glass, lit while pressed.
struct PadControlView: View {
    let item: PadItem
    let layout: PadLayout
    let area: CGSize
    let presses: PadPresses
    /// Its body, its label, or both: over glass, labels are drawn apart, above it, so the glass doesn't blur them.
    var part = Part.whole
    enum Part { case body, label, whole }

    var body: some View {
        let frame = item.frame(in: area)
        let showsBody = part != .label, showsLabel = part != .body
        Group {
            switch item.control {
            case .leftStick, .rightStick:
                // The base is body; the thumb (and, on glass, a sharp edge) is drawn with the labels, above the
                // glass, which would blur it.
                ZStack {
                    if showsBody { PadSurface(shape: Circle(), isGlass: layout.glass, isPressed: false) }
                    if showsLabel { stickTop(frame) }
                }
            case .dpad:
                DPadView(size: frame.width, isGlass: layout.glass, presses: presses, showsArms: showsBody, showsChevrons: showsLabel)
            default:
                let isPressed = presses.buttons.contains(item.control)
                let shape = item.control.isRoundedRect
                    ? AnyShape(RoundedRectangle(cornerRadius: item.size * 0.16, style: .continuous)) : AnyShape(Circle())
                ZStack {
                    if showsBody { PadSurface(shape: shape, isGlass: layout.glass, isPressed: isPressed) }
                    if showsLabel { label.foregroundStyle(.white) }
                }
            }
        }
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
        .allowsHitTesting(false)
    }

    /// A stick's thumb, pushed the way it's held, solid so it stays sharp; over glass, a crisp ring for the base too.
    private func stickTop(_ frame: CGRect) -> some View {
        let isLeft = item.control == .leftStick
        let offset = isLeft ? presses.leftStick : presses.rightStick
        let isHeld = offset != .zero
        return ZStack {
            if layout.glass { Circle().stroke(.white.opacity(0.45), lineWidth: 1.5) }
            Circle().fill(.white.opacity(isHeld ? 0.95 : 0.8))
                .overlay { Circle().stroke(.white, lineWidth: 1) }
                .frame(width: frame.width * 0.45, height: frame.width * 0.45)
                .offset(x: offset.x * frame.width * 0.3, y: offset.y * frame.width * 0.3)
        }
    }

    @ViewBuilder private var label: some View {
        let text = item.size * (item.control.isRoundedRect ? 0.26 : 0.38)
        switch layout.labels.label(item.control) {
        case .text(let string): Text(string).font(.system(size: text, weight: .bold))
        case .symbol(let name): Image(systemName: name).font(.system(size: text * 0.9, weight: .bold))
        }
    }
}

/// A control's body: Liquid Glass, or a dark see-through fill with a white edge; white while pressed.
struct PadSurface<S: Shape>: View {
    let shape: S
    let isGlass: Bool
    let isPressed: Bool
    /// A stick's thumb: a little brighter.
    var isThumb = false

    var body: some View {
        if isGlass {
            Color.clear.glassEffect(.regular.tint(isPressed ? .white.opacity(0.5) : isThumb ? .white.opacity(0.25) : nil), in: shape)
        } else {
            shape.fill(isPressed ? .white.opacity(0.6) : isThumb ? .white.opacity(0.75) : .black.opacity(0.3))
                .overlay { shape.stroke(.white.opacity(0.7), lineWidth: 2) }
        }
    }
}

/// Four glass arms (DPadArm) with their points towards the middle, each with a chevron pointing out, lighting up
/// while pressed. Each arm's outline is drawn already pointing its way: glass in a container doesn't follow rotations.
private struct DPadView: View {
    let size: CGFloat
    let isGlass: Bool
    let presses: PadPresses
    var showsArms = true
    var showsChevrons = true

    var body: some View {
        // The arm's drawing is 124 × 180.3; two of them tip to tip, with a gap between the tips, span the d-pad.
        let gap: CGFloat = 42, unit = size / (2 * DPadArm.length + gap)
        let width = DPadArm.width * unit, length = DPadArm.length * unit
        let reach = (gap / 2 + DPadArm.length / 2) * unit // the middle to an arm's centre
        ZStack {
            arm(.up, presses.dpad.up, width: width, length: length).offset(y: -reach)
            arm(.down, presses.dpad.down, width: width, length: length).offset(y: reach)
            arm(.left, presses.dpad.left, width: width, length: length).offset(x: -reach)
            arm(.right, presses.dpad.right, width: width, length: length).offset(x: reach)
        }
        .frame(width: size, height: size)
    }

    private func arm(_ direction: DPadArm.Direction, _ isPressed: Bool, width: CGFloat, length: CGFloat) -> some View {
        let isVertical = direction == .up || direction == .down
        let out = length * 0.16 // the chevron sits towards the flat, outer end
        let shift: CGSize = switch direction {
        case .up: CGSize(width: 0, height: -out)
        case .down: CGSize(width: 0, height: out)
        case .left: CGSize(width: -out, height: 0)
        case .right: CGSize(width: out, height: 0)
        }
        return Image(systemName: "chevron.\(direction)")
            .font(.system(size: width * 0.42, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .offset(shift)
            .opacity(showsChevrons ? 1 : 0)
            .frame(width: isVertical ? width : length, height: isVertical ? length : width)
            .background { if showsArms { PadSurface(shape: DPadArm(direction: direction), isGlass: isGlass, isPressed: isPressed) } }
    }
}

/// One d-pad arm, from its design (direction.svg): a rounded tab with a 45° point towards the d-pad's middle and a flat
/// outer end. Drawn for its direction (the up arm's point is at its bottom), in a rect as tall as it is long.
nonisolated struct DPadArm: Shape {
    enum Direction: String { case up, down, left, right }
    static let width: CGFloat = 124
    static let length: CGFloat = 180.301

    let direction: Direction

    func path(in rect: CGRect) -> Path {
        let (w, l) = (Self.width, Self.length)
        // The design has its point at the top (the down arm); each direction turns its points.
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let (u, v): (CGFloat, CGFloat) = switch direction {
            case .down: (x / w, y / l)
            case .up: ((w - x) / w, (l - y) / l)
            case .left: ((l - y) / l, x / w) // point at the right
            case .right: (y / l, (w - x) / w) // point at the left
            }
            return CGPoint(x: rect.minX + u * rect.width, y: rect.minY + v * rect.height)
        }
        var path = Path()
        path.move(to: p(0, 61.9998))
        path.addCurve(to: p(6.15076, 47.1505), control1: p(0, 56.4302), control2: p(2.21249, 51.0888))
        path.addLine(to: p(47.1507, 6.15053))
        path.addCurve(to: p(76.8492, 6.15051), control1: p(55.3518, -2.05048), control2: p(68.6482, -2.0505))
        path.addLine(to: p(117.849, 47.1505))
        path.addCurve(to: p(124, 61.9998), control1: p(121.787, 51.0888), control2: p(124, 56.4302))
        path.addLine(to: p(124, 159.301))
        path.addCurve(to: p(103, 180.301), control1: p(124, 170.899), control2: p(114.598, 180.301))
        path.addLine(to: p(21, 180.301))
        path.addCurve(to: p(0, 159.301), control1: p(9.40202, 180.301), control2: p(0, 170.899))
        path.closeSubpath()
        return path
    }
}

/// Joins the stream's touch layer and the on-screen controller: the layer hands floating sticks their touches, and
/// the actions row's Keyboard button reaches the layer's keyboard.
final class PadTouchRouter {
    weak var pad: PadTouchView?
    weak var touchView: TouchInputView?
}

private struct PadTouchLayer: UIViewRepresentable {
    var router: PadTouchRouter?
    let layout: PadLayout
    let presses: PadPresses
    let isPaused: Bool
    let send: (PadSnapshot) -> Void

    func makeUIView(context: Context) -> PadTouchView {
        let view = PadTouchView(presses: presses)
        router?.pad = view
        return view
    }

    func updateUIView(_ view: PadTouchView, context: Context) {
        view.layout = layout
        view.isPaused = isPaused
        view.send = send
    }
}

/// The controller's touches. Each finger takes the control it lands on (a touch area 12 points bigger than drawn) and
/// keeps it until it lifts: a stick follows it, the d-pad reads its direction, and a finger on A, B, X or Y slides from
/// one to the next (and between two, presses both).
final class PadTouchView: UIView {
    var layout = PadLayout.standard
    var isPaused = false { didSet { if isPaused, !grabs.isEmpty { grabs = [:]; update() } } }
    var send: (PadSnapshot) -> Void = { _ in }

    private let presses: PadPresses
    private let haptics = UIImpactFeedbackGenerator(style: .light)
    /// What each finger holds.
    private enum Grab {
        case stick(PadControl, center: CGPoint, radius: CGFloat, isFloating: Bool)
        case dpad(center: CGPoint, radius: CGFloat)
        case buttons(Set<PadControl>, isFace: Bool)
    }
    private var grabs: [ObjectIdentifier: (grab: Grab, point: CGPoint)] = [:]
    static let slack: CGFloat = 12

    init(presses: PadPresses) {
        self.presses = presses
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("not used from storyboards") }

    private func frame(_ item: PadItem) -> CGRect { item.frame(in: bounds.size) }

    /// The controls a point is on, nearest first.
    private func hits(_ point: CGPoint) -> [PadItem] {
        layout.items
            .filter { !layout.isFloating($0.control) } // a floating stick is wherever the thumb lands, not here
            .filter { frame($0).insetBy(dx: -Self.slack, dy: -Self.slack).contains(point) }
            .sorted { distance(point, frame($0)) < distance(point, frame($1)) }
    }

    private func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat { hypot(point.x - rect.midX, point.y - rect.midY) }

    /// Where a floating stick can land: its side of the screen, below the top fifth (the shoulders' row).
    private func floatingZone(_ stick: PadControl) -> CGRect {
        let width = bounds.width * 0.45
        return CGRect(x: stick == .leftStick ? 0 : bounds.width - width, y: bounds.height * 0.2, width: width, height: bounds.height * 0.8)
    }

    /// A floating stick whose side this point is on, if it's turned on.
    private func floatingStick(at point: CGPoint) -> PadControl? {
        [(PadControl.leftStick, layout.floatingLeftStick), (.rightStick, layout.floatingRightStick)]
            .first { $0.1 && floatingZone($0.0).contains(point) }?.0
    }

    /// Only the controls take touches; the rest reach the stream's touch layer, which hands one- and two-finger
    /// touches on a floating stick's side back here (floatingBegan), and keeps three for a gesture.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        !isPaused && !hits(point).isEmpty
    }

    // MARK: Floating sticks, by way of the stream's touch layer

    /// A touch the stream's touch layer got instead: a floating stick's, or (should one ever slip past this view) a
    /// control's, so a control is never unreachable.
    func floatingBegan(_ touch: UITouch) {
        let point = touch.location(in: self)
        guard !isPaused, let grab = grab(at: point) else { return }
        grabs[ObjectIdentifier(touch)] = (grab, point)
        presses.touches += 1
        update()
    }

    func floatingMoved(_ touch: UITouch) {
        guard let held = grabs[ObjectIdentifier(touch)] else { return }
        grabs[ObjectIdentifier(touch)] = (held.grab, touch.location(in: self))
        update()
    }

    func floatingEnded(_ touch: UITouch) {
        guard grabs.removeValue(forKey: ObjectIdentifier(touch)) != nil else { return }
        update()
    }

    func cancelFloating() {
        let before = grabs.count
        grabs = grabs.filter { if case .stick(_, _, _, true) = $0.value.grab { false } else { true } }
        if grabs.count != before { update() }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isPaused else { return }
        for touch in touches {
            let point = touch.location(in: self)
            if let grab = grab(at: point) { grabs[ObjectIdentifier(touch)] = (grab, point) }
        }
        presses.touches += 1
        update()
    }

    /// What a finger landing here takes: the control under it (a stick, the d-pad, or buttons), else a floating stick
    /// if this is its side.
    private func grab(at point: CGPoint) -> Grab? {
        let found = hits(point)
        if let stick = found.first(where: { $0.control.isStick }) {
            let rect = frame(stick)
            return .stick(stick.control, center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2, isFloating: false)
        }
        if let dpad = found.first(where: { $0.control == .dpad }) {
            let rect = frame(dpad)
            return .dpad(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2)
        }
        if let nearest = found.first {
            return nearest.control.isFaceButton ? .buttons(faceButtons(at: point), isFace: true) : .buttons([nearest.control], isFace: false)
        }
        if let control = floatingStick(at: point) {
            let size = layout.items.first { $0.control == control }?.size ?? 120
            return .stick(control, center: point, radius: size / 2, isFloating: true)
        }
        return nil
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let held = grabs[ObjectIdentifier(touch)] else { continue }
            let point = touch.location(in: self)
            if case .buttons(_, true) = held.grab {
                grabs[ObjectIdentifier(touch)] = (.buttons(faceButtons(at: point), isFace: true), point) // slides across
            } else {
                grabs[ObjectIdentifier(touch)] = (held.grab, point)
            }
        }
        update()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }

    private func lift(_ touches: Set<UITouch>) {
        for touch in touches { grabs[ObjectIdentifier(touch)] = nil }
        update()
    }

    /// A, B, X and Y under a point: between two, both.
    private func faceButtons(at point: CGPoint) -> Set<PadControl> {
        Set(hits(point).map(\.control).filter(\.isFaceButton))
    }

    /// Everything held now, drawn and sent; a light tap for each new press.
    private func update() {
        var buttons: Set<PadControl> = []
        var dpad = (up: false, down: false, left: false, right: false)
        var left = CGPoint.zero, right = CGPoint.zero
        var floatingLeft: CGPoint?, floatingRight: CGPoint?
        for (grab, point) in grabs.values {
            switch grab {
            case .stick(let control, let center, let radius, let isFloating):
                let vector = Self.stickVector(from: center, to: point, radius: radius)
                if control == .leftStick { left = vector } else { right = vector }
                if isFloating, control == .leftStick { floatingLeft = center }
                if isFloating, control == .rightStick { floatingRight = center }
            case .dpad(let center, let radius):
                let directions = Self.dpadDirections(from: center, to: point, radius: radius)
                dpad = (dpad.up || directions.up, dpad.down || directions.down,
                        dpad.left || directions.left, dpad.right || directions.right)
            case .buttons(let held, _):
                buttons.formUnion(held)
            }
        }
        let newPress = !buttons.isSubset(of: presses.buttons)
            || (dpad.up && !presses.dpad.up) || (dpad.down && !presses.dpad.down)
            || (dpad.left && !presses.dpad.left) || (dpad.right && !presses.dpad.right)
        if newPress { haptics.impactOccurred() }
        presses.buttons = buttons
        presses.dpad = dpad
        presses.leftStick = left
        presses.rightStick = right
        presses.isHeld = !grabs.isEmpty
        presses.floatingLeft = floatingLeft
        presses.floatingRight = floatingRight
        send(presses.snapshot)
    }

    /// -1...1 each way, the edge of the base being 1; a little dead zone in the middle.
    nonisolated static func stickVector(from center: CGPoint, to point: CGPoint, radius: CGFloat) -> CGPoint {
        let dx = (point.x - center.x) / max(radius, 1), dy = (point.y - center.y) / max(radius, 1)
        let length = hypot(dx, dy)
        guard length > 0.1 else { return .zero }
        let scale = min(length, 1) / length
        return CGPoint(x: dx * scale, y: dy * scale)
    }

    /// Up, down, left and right from where a finger is on the d-pad: diagonals press two; the middle presses none.
    nonisolated static func dpadDirections(from center: CGPoint, to point: CGPoint,
                                           radius: CGFloat) -> (up: Bool, down: Bool, left: Bool, right: Bool) {
        let dx = point.x - center.x, dy = point.y - center.y
        let length = hypot(dx, dy)
        guard length > radius * 0.2 else { return (false, false, false, false) }
        let (nx, ny) = (dx / length, dy / length)
        return (ny < -0.38, ny > 0.38, nx < -0.38, nx > 0.38)
    }
}
