import SwiftUI
import UIKit

/// A control on the on-screen controller (Touch: Controller).
nonisolated enum PadControl: String, Codable, CaseIterable {
    case leftStick, rightStick, dpad, a, b, x, y, lb, rb, lt, rt, view, menu, l3, r3

    var isStick: Bool { self == .leftStick || self == .rightStick }
    var isFaceButton: Bool { [.a, .b, .x, .y].contains(self) }
    /// Shoulders and triggers are drawn as wide capsules.
    var isWide: Bool { [.lb, .rb, .lt, .rt].contains(self) }

    var label: String {
        switch self {
        case .leftStick: "Left Stick"
        case .rightStick: "Right Stick"
        case .dpad: "D-Pad"
        case .a, .b, .x, .y: rawValue.uppercased()
        case .lb: "LB"
        case .rb: "RB"
        case .lt: "LT"
        case .rt: "RT"
        case .view: "View"
        case .menu: "Menu"
        case .l3: "L3"
        case .r3: "R3"
        }
    }
}

/// One control's place: its centre as a share of the controller's area (the screen inside its safe area), and its
/// size in points (a wide control is this wide and about half as tall).
nonisolated struct PadItem: Codable, Hashable {
    var control: PadControl
    var x: CGFloat
    var y: CGFloat
    var size: CGFloat

    func frame(in area: CGSize) -> CGRect {
        let height = control.isWide ? size * 0.55 : size
        return CGRect(x: x * area.width - size / 2, y: y * area.height - height / 2, width: size, height: height)
    }
}

/// A named set of controls and where they sit.
nonisolated struct PadLayout: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var items: [PadItem]
    /// How solid the controls are drawn, 0.2...1.
    var opacity: Double = 0.6
    /// The left stick appears wherever a thumb lands in the left part of the screen, outside the other controls.
    var floatingLeftStick = false

    /// Everything but the stick clicks: sticks low on each side, the d-pad and the A, B, X, Y diamond inside them,
    /// shoulders and triggers in the top corners, View and Menu between.
    static let standard = PadLayout(id: "standard", name: "Standard", items: [
        PadItem(control: .leftStick, x: 0.12, y: 0.58, size: 130),
        PadItem(control: .dpad, x: 0.27, y: 0.82, size: 112),
        PadItem(control: .y, x: 0.88, y: 0.43, size: 56),
        PadItem(control: .x, x: 0.81, y: 0.56, size: 56),
        PadItem(control: .b, x: 0.95, y: 0.56, size: 56),
        PadItem(control: .a, x: 0.88, y: 0.69, size: 56),
        PadItem(control: .rightStick, x: 0.72, y: 0.82, size: 112),
        PadItem(control: .lt, x: 0.07, y: 0.08, size: 76),
        PadItem(control: .lb, x: 0.17, y: 0.08, size: 76),
        PadItem(control: .rb, x: 0.83, y: 0.08, size: 76),
        PadItem(control: .rt, x: 0.93, y: 0.08, size: 76),
        PadItem(control: .view, x: 0.44, y: 0.08, size: 44),
        PadItem(control: .menu, x: 0.56, y: 0.08, size: 44),
    ])
}

/// What the on-screen controller shows pressed and where its sticks are, for drawing.
@Observable final class PadPresses {
    var buttons: Set<PadControl> = []
    var dpad = (up: false, down: false, left: false, right: false)
    /// -1...1 each way, up negative (as on screen).
    var leftStick = CGPoint.zero
    var rightStick = CGPoint.zero
    /// Where a floating left stick sits while a thumb holds it.
    var floatingCenter: CGPoint?

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
    let send: (PadSnapshot) -> Void
    @State private var presses = PadPresses()

    var body: some View {
        GeometryReader { proxy in
            // One container, so the system draws all the glass together (cheaper over a live game).
            GlassEffectContainer(spacing: 0) { // 0: pieces near each other don't melt together
            ZStack {
                ForEach(layout.items, id: \.control) { item in
                    PadControlView(item: item, area: proxy.size, presses: presses)
                }
                if let center = presses.floatingCenter, let stick = layout.items.first(where: { $0.control == .leftStick }) {
                    // The floating stick where the thumb landed; the fixed one stays drawn faintly.
                    PadControlView(item: PadItem(control: .leftStick, x: center.x / max(proxy.size.width, 1),
                                                 y: center.y / max(proxy.size.height, 1), size: stick.size),
                                   area: proxy.size, presses: presses, isFloating: true)
                }
            }
            }
            .opacity(layout.opacity)
            .overlay { PadTouchLayer(layout: layout, presses: presses, isPaused: isPaused, send: send) }
        }
    }
}

struct PadControlView: View {
    let item: PadItem
    let area: CGSize
    let presses: PadPresses
    var isFloating = false

    var body: some View {
        let frame = item.frame(in: area)
        Group {
            switch item.control {
            case .leftStick, .rightStick:
                let offset = item.control == .leftStick && (presses.floatingCenter == nil || isFloating) ? presses.leftStick
                    : item.control == .rightStick ? presses.rightStick : .zero
                let isHeld = offset != .zero
                Color.clear
                    .glassEffect(.regular, in: .circle)
                    .overlay {
                        Color.clear
                            .frame(width: frame.width * 0.45, height: frame.width * 0.45)
                            .glassEffect(.regular.tint(.white.opacity(isHeld ? 0.5 : 0.25)), in: .circle)
                            .offset(x: offset.x * frame.width * 0.3, y: offset.y * frame.width * 0.3)
                    }
            case .dpad:
                DPadView(size: frame.width, presses: presses)
            default:
                let isPressed = presses.buttons.contains(item.control)
                let shape = item.control.isWide ? AnyShape(Capsule()) : AnyShape(Circle())
                label
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glassEffect(.regular.tint(isPressed ? .white.opacity(0.5) : nil), in: shape)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
        .allowsHitTesting(false)
    }

    @ViewBuilder private var label: some View {
        switch item.control {
        case .view: Image(systemName: "rectangle.on.rectangle").font(.system(size: item.size * 0.36, weight: .semibold))
        case .menu: Image(systemName: "line.3.horizontal").font(.system(size: item.size * 0.38, weight: .semibold))
        default: Text(item.control.label).font(.system(size: item.size * (item.control.isWide ? 0.24 : 0.38), weight: .bold))
        }
    }
}

/// Four glass arms (DPadArm) with their points towards the middle, each with a chevron pointing out, lighting up
/// while pressed. Each arm's outline is drawn already pointing its way: glass in a container doesn't follow rotations.
private struct DPadView: View {
    let size: CGFloat
    let presses: PadPresses

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
            .frame(width: isVertical ? width : length, height: isVertical ? length : width)
            .glassEffect(.regular.tint(isPressed ? .white.opacity(0.5) : nil), in: DPadArm(direction: direction))
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

private struct PadTouchLayer: UIViewRepresentable {
    let layout: PadLayout
    let presses: PadPresses
    let isPaused: Bool
    let send: (PadSnapshot) -> Void

    func makeUIView(context: Context) -> PadTouchView { PadTouchView(presses: presses) }

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
            .filter { frame($0).insetBy(dx: -Self.slack, dy: -Self.slack).contains(point) }
            .sorted { distance(point, frame($0)) < distance(point, frame($1)) }
    }

    private func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat { hypot(point.x - rect.midX, point.y - rect.midY) }

    private var floatingZone: CGRect { CGRect(x: 0, y: bounds.height * 0.2, width: bounds.width * 0.45, height: bounds.height * 0.8) }

    /// Only the controls (and a floating stick's zone) take touches; the rest reach the stream below.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        !isPaused && (!hits(point).isEmpty || (layout.floatingLeftStick && floatingZone.contains(point)))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isPaused else { return }
        for touch in touches {
            let point = touch.location(in: self)
            let found = hits(point)
            let grab: Grab?
            if let stick = found.first(where: { $0.control.isStick }) {
                let rect = frame(stick)
                grab = .stick(stick.control, center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2, isFloating: false)
            } else if let dpad = found.first(where: { $0.control == .dpad }) {
                let rect = frame(dpad)
                grab = .dpad(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2)
            } else if let nearest = found.first {
                grab = nearest.control.isFaceButton ? .buttons(faceButtons(at: point), isFace: true) : .buttons([nearest.control], isFace: false)
            } else if layout.floatingLeftStick, floatingZone.contains(point),
                      let stick = layout.items.first(where: { $0.control == .leftStick }) {
                grab = .stick(.leftStick, center: point, radius: stick.size / 2, isFloating: true)
            } else {
                grab = nil
            }
            if let grab { grabs[ObjectIdentifier(touch)] = (grab, point) }
        }
        update()
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
        var floating: CGPoint?
        for (grab, point) in grabs.values {
            switch grab {
            case .stick(let control, let center, let radius, let isFloating):
                let vector = Self.stickVector(from: center, to: point, radius: radius)
                if control == .leftStick { left = vector } else { right = vector }
                if isFloating { floating = center }
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
        presses.floatingCenter = floating
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
