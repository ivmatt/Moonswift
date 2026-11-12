import MoonlightCore
import SwiftUI
import UIKit

enum TouchMode: String {
    /// Each finger is a real Windows touch (or an absolute mouse on hosts without touch support).
    case touchscreen
    /// Laptop-style: one finger moves the cursor, tap clicks, two-finger tap right-clicks, two-finger drag scrolls.
    case trackpad
}

/// Where the video sits inside the view (aspect fit) and how view points map to it.
nonisolated enum VideoGeometry {
    static func videoRect(stream: CGSize, in bounds: CGRect) -> CGRect {
        guard stream.width > 0, stream.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / stream.width, bounds.height / stream.height)
        let size = CGSize(width: stream.width * scale, height: stream.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// 0...1 inside the video; touches on the black bars are clamped to its edge.
    static func normalized(_ point: CGPoint, in video: CGRect) -> CGPoint {
        CGPoint(x: min(max((point.x - video.minX) / video.width, 0), 1),
                y: min(max((point.y - video.minY) / video.height, 0), 1))
    }
}

/// Turns finger movement into mouse actions, like a laptop trackpad. Pure logic, so it can be tested.
nonisolated struct TrackpadGestures {
    enum Action: Equatable {
        case move(dx: Int16, dy: Int16)
        case click(Int32) // BUTTON_LEFT or BUTTON_RIGHT
        case scroll(Int16) // high-resolution wheel units, 120 per notch; positive scrolls up
    }

    /// Host pixels per point of finger movement.
    var cursorScale: Double = 2
    /// Wheel units per point of two-finger movement.
    var scrollScale: Double = 3
    static let tapDuration: TimeInterval = 0.25
    static let tapSlop: Double = 10 // points a tap may wander

    private var touches: [Int: (start: CGPoint, last: CGPoint)] = [:]
    private var maxFingers = 0
    private var gestureStart: TimeInterval = 0
    private var hasMoved = false
    private var remainder = (x: 0.0, y: 0.0, scroll: 0.0)

    mutating func began(_ id: Int, at point: CGPoint, time: TimeInterval) {
        if touches.isEmpty {
            maxFingers = 0
            gestureStart = time
            hasMoved = false
        }
        touches[id] = (point, point)
        maxFingers = max(maxFingers, touches.count)
    }

    mutating func moved(_ id: Int, to point: CGPoint) -> [Action] {
        guard let touch = touches[id] else { return [] }
        touches[id]?.last = point
        if hypot(point.x - touch.start.x, point.y - touch.start.y) > Self.tapSlop { hasMoved = true }
        let dx = Double(point.x - touch.last.x), dy = Double(point.y - touch.last.y)
        switch touches.count {
        case 1:
            remainder.x += dx * cursorScale
            remainder.y += dy * cursorScale
            let x = remainder.x.rounded(.towardZero), y = remainder.y.rounded(.towardZero)
            remainder.x -= x
            remainder.y -= y
            return x == 0 && y == 0 ? [] : [.move(dx: Int16(clamping: Int(x)), dy: Int16(clamping: Int(y)))]
        case 2:
            // Both fingers report their own movement, so each counts half. The content follows the fingers
            // ("natural" scrolling): fingers moving down turn the wheel up, which is positive.
            remainder.scroll += dy * scrollScale / 2
            let amount = remainder.scroll.rounded(.towardZero)
            remainder.scroll -= amount
            return amount == 0 ? [] : [.scroll(Int16(clamping: Int(amount)))]
        default:
            return []
        }
    }

    mutating func ended(_ id: Int, time: TimeInterval) -> [Action] {
        guard touches.removeValue(forKey: id) != nil, touches.isEmpty else { return [] }
        guard !hasMoved, time - gestureStart <= Self.tapDuration else { return [] }
        switch maxFingers {
        case 1: return [.click(BUTTON_LEFT)]
        case 2: return [.click(BUTTON_RIGHT)]
        default: return []
        }
    }

    mutating func cancelAll() {
        touches = [:]
        hasMoved = true // a cancelled gesture is never a tap
    }
}

/// A transparent view over the video that sends touches to the host, and opens the stream menu on a four-finger tap.
final class TouchInputView: UIView {
    var mode = TouchMode.touchscreen { didSet { if mode != oldValue { cancelAll() } } }
    var streamSize = CGSize(width: 1920, height: 1080)
    var isPaused = false { didSet { if isPaused { cancelAll() } } }
    var onMenu: () -> Void = {}

    private var ids: [ObjectIdentifier: UInt32] = [:]
    private var nextID: UInt32 = 0
    private var trackpad = TrackpadGestures()
    /// The finger driving the absolute mouse on hosts without touch support.
    private var mouseFinger: ObjectIdentifier?
    /// Four fingers down: this gesture is the menu shortcut and nothing else reaches the host until all lift.
    private var isMenuGesture = false
    private var gestureStart: TimeInterval = 0
    private var activeTouches = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("not used from storyboards") }

    private var video: CGRect { VideoGeometry.videoRect(stream: streamSize, in: bounds) }
    private var hostSupportsTouch: Bool { LiGetHostFeatureFlags() & UInt32(LI_FF_PEN_TOUCH_EVENTS) != 0 }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if activeTouches == 0 {
            isMenuGesture = false
            gestureStart = event?.timestamp ?? 0
        }
        activeTouches += touches.count
        if activeTouches >= 4, !isMenuGesture {
            cancelAll()
            isMenuGesture = true
        }
        guard !isMenuGesture, !isPaused else { return }
        for touch in touches {
            let id = nextID
            nextID &+= 1
            ids[ObjectIdentifier(touch)] = id
            switch mode {
            case .trackpad:
                trackpad.cursorScale = Double(streamSize.width / max(video.width, 1)) // finger across the video = cursor across the screen
                trackpad.began(Int(id), at: touch.location(in: self), time: touch.timestamp)
            case .touchscreen:
                sendTouch(touch, event: LI_TOUCH_EVENT_DOWN)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isMenuGesture, !isPaused else { return }
        for touch in touches {
            guard let id = ids[ObjectIdentifier(touch)] else { continue }
            switch mode {
            case .trackpad: perform(trackpad.moved(Int(id), to: touch.location(in: self)))
            case .touchscreen: sendTouch(touch, event: LI_TOUCH_EVENT_MOVE)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, event: event, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, event: event, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, event: UIEvent?, cancelled: Bool) {
        activeTouches = max(0, activeTouches - touches.count)
        if !isMenuGesture, !isPaused {
            for touch in touches {
                guard let id = ids[ObjectIdentifier(touch)] else { continue }
                switch mode {
                case .trackpad:
                    if cancelled { trackpad.cancelAll() } else { perform(trackpad.ended(Int(id), time: touch.timestamp)) }
                case .touchscreen:
                    sendTouch(touch, event: cancelled ? LI_TOUCH_EVENT_CANCEL : LI_TOUCH_EVENT_UP)
                }
            }
        }
        for touch in touches { ids[ObjectIdentifier(touch)] = nil }
        if activeTouches == 0, isMenuGesture, !cancelled, (event?.timestamp ?? 0) - gestureStart < 0.6 {
            onMenu()
        }
    }

    /// Lifts everything already sent, so nothing stays pressed on the host.
    private func cancelAll() {
        if mode == .touchscreen, !ids.isEmpty {
            if hostSupportsTouch {
                LiSendTouchEvent(UInt8(LI_TOUCH_EVENT_CANCEL_ALL), 0, 0, 0, 0, 0, 0, UInt16(LI_ROT_UNKNOWN))
            } else if mouseFinger != nil {
                LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), BUTTON_LEFT)
            }
        }
        mouseFinger = nil
        trackpad.cancelAll()
        ids = [:]
    }

    private func sendTouch(_ touch: UITouch, event: Int32) {
        guard let id = ids[ObjectIdentifier(touch)] else { return }
        let video = video
        let point = VideoGeometry.normalized(touch.location(in: self), in: video)
        if hostSupportsTouch {
            let pressure = touch.maximumPossibleForce > 0 ? Float(touch.force / touch.maximumPossibleForce) : 0
            let contact = Float(touch.majorRadius * 2 / max(video.width, 1))
            LiSendTouchEvent(UInt8(event), id, Float(point.x), Float(point.y), pressure, contact, contact, UInt16(LI_ROT_UNKNOWN))
            return
        }
        // Fallback: the first finger is an absolute mouse with the left button held.
        let finger = ObjectIdentifier(touch)
        if event == LI_TOUCH_EVENT_DOWN, mouseFinger == nil { mouseFinger = finger }
        guard mouseFinger == finger else { return }
        let width = Int16(streamSize.width), height = Int16(streamSize.height)
        LiSendMousePositionEvent(Int16(point.x * Double(width)), Int16(point.y * Double(height)), width, height)
        if event == LI_TOUCH_EVENT_DOWN { LiSendMouseButtonEvent(CChar(BUTTON_ACTION_PRESS), BUTTON_LEFT) }
        if event == LI_TOUCH_EVENT_UP || event == LI_TOUCH_EVENT_CANCEL {
            LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), BUTTON_LEFT)
            mouseFinger = nil
        }
    }

    private func perform(_ actions: [TrackpadGestures.Action]) {
        for action in actions {
            switch action {
            case .move(let dx, let dy): LiSendMouseMoveEvent(dx, dy)
            case .scroll(let amount): LiSendHighResScrollEvent(amount)
            case .click(let button):
                LiSendMouseButtonEvent(CChar(BUTTON_ACTION_PRESS), button)
                LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), button)
            }
        }
    }
}

/// Puts a TouchInputView over the video in SwiftUI.
struct TouchInputLayer: UIViewRepresentable {
    let mode: TouchMode
    let streamSize: CGSize
    let isPaused: Bool
    let onMenu: () -> Void

    func makeUIView(context: Context) -> TouchInputView { TouchInputView(frame: .zero) }

    func updateUIView(_ view: TouchInputView, context: Context) {
        view.mode = mode
        view.streamSize = streamSize
        view.isPaused = isPaused
        view.onMenu = onMenu
    }
}
