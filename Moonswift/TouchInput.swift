import GameController
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

/// A three- (or four-) finger stream shortcut, read from where the fingers started and ended.
nonisolated enum StreamGesture: Equatable {
    case swipeUp, swipeDown, swipeLeft, swipeRight, pinch
    /// The fingers down and still for `holdTime`.
    case hold

    /// Long enough that fingers resting a moment before a swipe aren't taken for a hold.
    static let holdTime: TimeInterval = 0.8

    /// A pinch closes to `pinchClosed` of the fingers' spread; a swipe is them moving together at least 60 points.
    /// How far a pinch closes (spread now ÷ at the start) to count, like a trackpad's: a natural pinch, not every
    /// finger together. A quick flick counts sooner (see `TouchInputView`).
    static let pinchClosed: CGFloat = 0.7

    /// How far the fingers have moved left together, as it happens: the control panel follows them out of the right
    /// edge. Forgiving, as a hand's swipe drifts: anything more left than up or down by half counts (nil: it doesn't).
    static func leftPull(start: [CGPoint], now: [CGPoint]) -> CGFloat? {
        movement(start, now).flatMap { dx, dy in dx < 0 && -dx * 2 > abs(dy) ? -dx : nil }
    }

    /// The fingers' centre, moved since they landed.
    private static func movement(_ start: [CGPoint], _ now: [CGPoint]) -> (dx: CGFloat, dy: CGFloat)? {
        guard start.count >= 3, start.count == now.count else { return nil }
        let count = CGFloat(start.count)
        let dx: CGFloat = now.map(\.x).reduce(0, +) / count - start.map(\.x).reduce(0, +) / count
        let dy: CGFloat = now.map(\.y).reduce(0, +) / count - start.map(\.y).reduce(0, +) / count
        return (dx, dy)
    }

    /// A pinch's spread now ÷ at the start, as it happens: for telling a quick flick from a pinch.
    static func pinchProgress(start: [CGPoint], now: [CGPoint]) -> CGFloat? {
        guard start.count >= 3, start.count == now.count else { return nil }
        func spread(_ points: [CGPoint]) -> CGFloat {
            let c = CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
            return points.map { hypot($0.x - c.x, $0.y - c.y) }.reduce(0, +) / CGFloat(points.count)
        }
        let before = spread(start)
        return before > 0 ? spread(now) / before : nil
    }

    static func classify(start: [CGPoint], end: [CGPoint]) -> StreamGesture? {
        guard start.count >= 3, start.count == end.count else { return nil }
        func centre(_ points: [CGPoint]) -> CGPoint {
            CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
        }
        func spread(_ points: [CGPoint], _ centre: CGPoint) -> CGFloat {
            points.map { hypot($0.x - centre.x, $0.y - centre.y) }.reduce(0, +) / CGFloat(points.count)
        }
        let (from, to) = (centre(start), centre(end))
        let (before, after) = (spread(start, from), spread(end, to))
        if before > 0, after < before * pinchClosed { return .pinch }
        if after > before * 1.6 { return nil } // a spread: not used
        let (dx, dy) = (to.x - from.x, to.y - from.y)
        guard max(abs(dx), abs(dy)) >= 60 else { return nil }
        return abs(dx) > abs(dy) ? (dx > 0 ? .swipeRight : .swipeLeft) : (dy < 0 ? .swipeUp : .swipeDown)
    }
}

/// A transparent view over the video that sends touches to the host. Three-finger (and, if on, four-finger) gestures are
/// shortcuts: those set to Keyboard show the on-screen keyboard (whose text and keys it sends to the PC), a swipe down
/// hides it, and the rest go to `onGesture`.
final class TouchInputView: UIView, UIKeyInput {
    var mode = TouchMode.touchscreen { didSet { if mode != oldValue { cancelAll() } } }
    var streamSize = CGSize(width: 1920, height: 1080)
    var isPaused = false {
        didSet {
            guard isPaused else { return }
            cancelAll()
            _ = resignFirstResponder() // the keyboard goes away with the menu
        }
    }
    var onGesture: (TouchGesture) -> Void = { _ in }
    /// A three-finger swipe left's distance while the fingers are down; nil once they lift (or it isn't one).
    var onSwipeProgress: (CGFloat?) -> Void = { _ in }
    /// The gestures set to Keyboard: they show it (or hide it) here, rather than going to `onGesture`.
    var keyboardGestures: Set<TouchGesture> = []
    /// The finger counts whose swipe left pulls out the control panel.
    var followsSwipeLeft: Set<Int> = []
    var allowsFourFingers = false
    /// The hold fired: lifting the fingers afterwards isn't a swipe.
    private var didHold = false
    /// How far out the fingers have pulled the panel: past 50 points it opens when they lift, however the swipe ended
    /// (fingers drifting together read as a pinch, and iOS can cancel touches at the screen's edge).
    private var pulled: CGFloat = 0
    private var holdCheck = 0

    private var ids: [ObjectIdentifier: UInt32] = [:]
    private var nextID: UInt32 = 0
    private var trackpad = TrackpadGestures()
    /// The finger driving the absolute mouse on hosts without touch support.
    private var mouseFinger: ObjectIdentifier?
    /// Three or more fingers down: this gesture is a shortcut and nothing else reaches the host until all lift.
    /// Games lose three-finger touches in exchange.
    private var isShortcutGesture = false
    private var shortcutStart: [ObjectIdentifier: CGPoint] = [:]
    private var shortcutLast: [ObjectIdentifier: CGPoint] = [:]
    private var activeTouches = 0
    /// The pinch's last moments (time, spread ratio), for how fast it was closing when the fingers lifted.
    private var pinchSamples: [(time: TimeInterval, progress: CGFloat)] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("not used from storyboards") }

    private var video: CGRect { VideoGeometry.videoRect(stream: streamSize, in: bounds) }
    private var hostSupportsTouch: Bool { LiGetHostFeatureFlags() & UInt32(LI_FF_PEN_TOUCH_EVENTS) != 0 }

    override func touchesBegan(_ all: Set<UITouch>, with event: UIEvent?) {
        for touch in all where touch.type == .indirectPointer {
            pointerTouches[ObjectIdentifier(touch)] = (touch.timestamp, event?.buttonMask.contains(.secondary) == true)
        }
        let touches = fingers(all)
        guard !touches.isEmpty else { return }
        if activeTouches == 0 { isShortcutGesture = false }
        activeTouches += touches.count
        if isShortcutGesture { // a finger joining an ongoing shortcut (the fourth of a pinch) starts where it lands
            for touch in touches { shortcutStart[ObjectIdentifier(touch)] = touch.location(in: self) }
            for touch in touches { shortcutLast[ObjectIdentifier(touch)] = touch.location(in: self) }
        }
        if activeTouches >= 3, !isShortcutGesture {
            cancelAll()
            isShortcutGesture = true
            didHold = false
            pulled = 0
            holdCheck += 1
            let check = holdCheck
            DispatchQueue.main.asyncAfter(deadline: .now() + StreamGesture.holdTime) { [weak self] in self?.checkHold(check) }
            // Where every finger now down starts; later fingers (a fourth) aren't part of the shape.
            let down = (event?.allTouches ?? touches).filter { $0.phase != .ended && $0.phase != .cancelled }
            shortcutStart = Dictionary(down.map { (ObjectIdentifier($0), $0.location(in: self)) }, uniquingKeysWith: { a, _ in a })
            shortcutLast = shortcutStart
        }
        guard !isShortcutGesture, !isPaused else { return }
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

    override func touchesMoved(_ all: Set<UITouch>, with event: UIEvent?) {
        let touches = fingers(all)
        guard !touches.isEmpty else { return }
        if isShortcutGesture { return track(touches) }
        guard !isPaused else { return }
        for touch in touches {
            guard let id = ids[ObjectIdentifier(touch)] else { continue }
            switch mode {
            case .trackpad: perform(trackpad.moved(Int(id), to: touch.location(in: self)))
            case .touchscreen: sendTouch(touch, event: LI_TOUCH_EVENT_MOVE)
            }
        }
    }

    override func touchesEnded(_ all: Set<UITouch>, with event: UIEvent?) {
        pointerEnded(all, cancelled: false)
        let touches = fingers(all)
        if !touches.isEmpty { finish(touches, event: event, cancelled: false) }
    }

    override func touchesCancelled(_ all: Set<UITouch>, with event: UIEvent?) {
        pointerEnded(all, cancelled: true)
        let touches = fingers(all)
        if !touches.isEmpty { finish(touches, event: event, cancelled: true) }
    }

    // MARK: Trackpad and mouse pointer

    /// A trackpad's or mouse's touches (the pointer), when they started and whether it was a secondary (two-finger)
    /// click. Moves and physical clicks reach the host through GCMouse (KeyboardMouseStreamer), not here; only a
    /// trackpad's tap to click doesn't, so a quick one with no physical click sends a click. (Upstream Moonlight
    /// misses tap to click too.)
    private var pointerTouches: [ObjectIdentifier: (start: TimeInterval, isSecondary: Bool)] = [:]

    /// Finger touches: the pointer's aren't touches on the game, nor trackpad-mode gestures.
    private func fingers(_ touches: Set<UITouch>) -> Set<UITouch> { touches.filter { $0.type != .indirectPointer } }

    private func pointerEnded(_ touches: Set<UITouch>, cancelled: Bool) {
        for touch in touches where touch.type == .indirectPointer {
            guard let (start, isSecondary) = pointerTouches.removeValue(forKey: ObjectIdentifier(touch)),
                  !cancelled, !isPaused, touch.timestamp - start < 0.3,
                  KeyboardMouseStreamer.lastPhysicalClick < start - 0.05 // a real click: GCMouse has sent it
            else { continue }
            let button = isSecondary ? BUTTON_RIGHT : BUTTON_LEFT
            LiSendMouseButtonEvent(CChar(BUTTON_ACTION_PRESS), button)
            LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), button)
        }
    }

    private func track(_ touches: Set<UITouch>) {
        for touch in touches where shortcutStart[ObjectIdentifier(touch)] != nil {
            shortcutLast[ObjectIdentifier(touch)] = touch.location(in: self)
        }
        guard !isPaused else { return }
        let keys = Array(shortcutStart.keys)
        let start = keys.compactMap { shortcutStart[$0] }, now = keys.compactMap { shortcutLast[$0] }
        guard counts(start.count), !didHold else { return }
        if let progress = StreamGesture.pinchProgress(start: start, now: now) {
            let time = CACurrentMediaTime()
            pinchSamples.append((time, progress))
            pinchSamples.removeAll { time - $0.time > 0.12 }
        }
        if followsSwipeLeft.contains(start.count) {
            let pull = StreamGesture.leftPull(start: start, now: now)
            pulled = pull ?? 0
            onSwipeProgress(pull)
        }
    }

    /// Three fingers always; four only with four-finger gestures on.
    private func counts(_ fingers: Int) -> Bool { fingers == 3 || (fingers == 4 && allowsFourFingers) }

    private func finish(_ touches: Set<UITouch>, event: UIEvent?, cancelled: Bool) {
        if isShortcutGesture { track(touches) }
        activeTouches = max(0, activeTouches - touches.count)
        if !isShortcutGesture, !isPaused {
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
        guard activeTouches == 0, isShortcutGesture else { return }
        defer { // whatever it was, the fingers are up: after the gesture, so the panel can take over first
            onSwipeProgress(nil)
            pinchSamples = []
            pulled = 0
        }
        if pulled >= 50, !didHold, !isPaused, counts(shortcutStart.count) {
            return perform(TouchGesture(kind: .swipeLeft, fingers: shortcutStart.count))
        }
        guard !cancelled, !isPaused else { return }
        let keys = Array(shortcutStart.keys)
        let start = keys.compactMap { shortcutStart[$0] }, end = keys.compactMap { shortcutLast[$0] }
        // A pinch still closing fast when the fingers lift counts before it gets as far, like a flick on a trackpad.
        let isFlick = pinchSamples.count >= 2 && {
            let (first, last) = (pinchSamples.first!, pinchSamples.last!)
            let speed = (last.progress - first.progress) / max(last.time - first.time, 0.001) // per second
            return speed < -1 && last.progress < 0.92
        }()
        guard !didHold, counts(start.count),
              let gesture = isFlick ? .pinch : StreamGesture.classify(start: start, end: end) else { return }
        perform(TouchGesture(kind: gesture, fingers: start.count))
    }

    /// Exactly three fingers, down for `holdTime` and barely moved: a hold, once.
    private func checkHold(_ check: Int) {
        guard check == holdCheck, isShortcutGesture, !didHold, !isPaused, activeTouches == shortcutStart.count,
              counts(shortcutStart.count) else { return }
        let moved = shortcutStart.contains { id, start in
            shortcutLast[id].map { hypot($0.x - start.x, $0.y - start.y) > 10 } ?? true
        }
        guard !moved else { return }
        didHold = true
        onSwipeProgress(nil)
        perform(TouchGesture(kind: .hold, fingers: shortcutStart.count))
    }

    private func perform(_ gesture: TouchGesture) {
        if gesture.kind == .swipeDown, isFirstResponder { _ = resignFirstResponder(); return } // the keyboard goes back down
        if keyboardGestures.contains(gesture) {
            _ = isFirstResponder ? resignFirstResponder() : becomeFirstResponder()
            return
        }
        onGesture(gesture)
    }

    // MARK: On-screen keyboard

    override var canBecomeFirstResponder: Bool { true }
    /// iOS's own three-finger editing gestures (pinch to copy, swipe to undo) would fight the stream shortcuts.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    override var inputAccessoryView: UIView? { keyBar }
    var hasText: Bool { true } // so Backspace always reaches deleteBackward, even with nothing typed here
    // Typed text goes straight to the PC, so iOS shouldn't "fix" it on the way.
    var autocorrectionType = UITextAutocorrectionType.no
    var autocapitalizationType = UITextAutocapitalizationType.none
    var spellCheckingType = UITextSpellCheckingType.no
    var smartQuotesType = UITextSmartQuotesType.no
    var smartDashesType = UITextSmartDashesType.no
    var smartInsertDeleteType = UITextSmartInsertDeleteType.no
    var inlinePredictionType = UITextInlinePredictionType.no
    var keyboardAppearance = UIKeyboardAppearance.dark

    /// Ctrl and Alt from the key bar, held for the next key (HID usages).
    private var stickyModifiers: [Int] = [] { didSet { keyBar.highlight(stickyModifiers) } }
    private lazy var keyBar = KeyBar { [weak self] usage in self?.keyBarTapped(usage) }

    /// A hardware keyboard already reaches the PC through GameController; taking its keys here too would type twice.
    private var isSoftKeyboardInput: Bool { !isPaused && GCKeyboard.coalesced == nil }

    func insertText(_ text: String) {
        guard isSoftKeyboardInput else { return }
        if text == "\n" { return tap(0x28) } // Return
        // A shortcut like Ctrl+C has to be the key itself; plain text goes as text, so any language and emoji work.
        if !stickyModifiers.isEmpty, text.count == 1, let usage = text.first.flatMap(KeyMap.hidUsage) { return tap(usage) }
        stickyModifiers = []
        LiSendUtf8TextEvent(text, UInt32(text.utf8.count))
    }

    func deleteBackward() {
        if isSoftKeyboardInput { tap(0x2A) } // Backspace
    }

    private func keyBarTapped(_ usage: Int) {
        switch usage {
        case KeyBar.hide: _ = resignFirstResponder()
        case 0xE0, 0xE2: // Ctrl, Alt: toggle for the next key
            if let index = stickyModifiers.firstIndex(of: usage) { stickyModifiers.remove(at: index) } else { stickyModifiers.append(usage) }
        default: tap(usage)
        }
    }

    /// Presses and releases one key, with any held Ctrl/Alt around it.
    private func tap(_ usage: Int) {
        guard let key = KeyMap.key(hidUsage: usage) else { return }
        let held = stickyModifiers.compactMap { usage in KeyMap.key(hidUsage: usage).map { (usage, $0) } }
        var flags: Int8 = 0
        for (usage, modifier) in held {
            flags |= KeyMap.modifier(hidUsage: usage)
            KeyMap.send(modifier, down: true, modifiers: flags)
        }
        KeyMap.send(key, down: true, modifiers: flags)
        KeyMap.send(key, down: false, modifiers: flags)
        for (usage, modifier) in held.reversed() {
            flags &= ~KeyMap.modifier(hidUsage: usage)
            KeyMap.send(modifier, down: false, modifiers: flags)
        }
        stickyModifiers = []
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
    let onGesture: (TouchGesture) -> Void
    var onSwipeProgress: (CGFloat?) -> Void = { _ in }
    var keyboardGestures: Set<TouchGesture> = []
    var followsSwipeLeft: Set<Int> = []
    var allowsFourFingers = false

    func makeUIView(context: Context) -> TouchInputView { TouchInputView(frame: .zero) }

    func updateUIView(_ view: TouchInputView, context: Context) {
        view.mode = mode
        view.streamSize = streamSize
        view.isPaused = isPaused
        view.onGesture = onGesture
        view.onSwipeProgress = onSwipeProgress
        view.keyboardGestures = keyboardGestures
        view.followsSwipeLeft = followsSwipeLeft
        view.allowsFourFingers = allowsFourFingers
    }
}

/// The row above the on-screen keyboard: keys it lacks. Each button reports a HID usage (or `hide`).
private final class KeyBar: UIInputView {
    static let hide = -1
    private static let keys: [(title: String?, symbol: String?, usage: Int)] = [
        ("Esc", nil, 0x29), ("Tab", nil, 0x2B), ("Ctrl", nil, 0xE0), ("Alt", nil, 0xE2), ("Win", nil, 0xE3),
        (nil, "arrow.left", 0x50), (nil, "arrow.up", 0x52), (nil, "arrow.down", 0x51), (nil, "arrow.right", 0x4F),
        (nil, "keyboard.chevron.compact.down", hide),
    ]
    private var buttons: [Int: UIButton] = [:]

    init(onTap: @escaping (Int) -> Void) {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        for key in Self.keys {
            var config = UIButton.Configuration.gray()
            config.title = key.title
            config.image = key.symbol.map { UIImage(systemName: $0) } ?? nil
            config.contentInsets = .init(top: 6, leading: 2, bottom: 6, trailing: 2)
            let button = UIButton(configuration: config, primaryAction: UIAction { _ in onTap(key.usage) })
            if key.usage == Self.hide { button.accessibilityLabel = "Hide keyboard" }
            buttons[key.usage] = button
            row.addArrangedSubview(button)
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used from storyboards") }

    /// Held modifiers look pressed.
    func highlight(_ usages: [Int]) {
        for usage in [0xE0, 0xE2] {
            buttons[usage]?.configuration?.baseBackgroundColor = usages.contains(usage) ? .tintColor : nil
            buttons[usage]?.configuration?.baseForegroundColor = usages.contains(usage) ? .white : nil
        }
    }
}
