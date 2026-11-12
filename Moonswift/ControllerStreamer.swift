import CoreHaptics
import GameController
import MoonlightCore

/// What one controller looks like right now, independent of GameController types (so it can be tested).
nonisolated struct PadSnapshot: Equatable {
    var a = false, b = false, x = false, y = false
    var up = false, down = false, left = false, right = false
    var leftShoulder = false, rightShoulder = false
    var leftStickClick = false, rightStickClick = false
    var menu = false, options = false, home = false
    var touchpadClick = false, share = false
    var paddles: [Bool] = []
    var leftTrigger: Float = 0, rightTrigger: Float = 0
    var leftStick = (x: Float(0), y: Float(0)), rightStick = (x: Float(0), y: Float(0))

    static func == (lhs: Self, rhs: Self) -> Bool { ControllerMapping.state(lhs) == ControllerMapping.state(rhs) }
}

/// The library's controller event fields.
nonisolated struct PadState: Equatable {
    var buttons: Int32
    var leftTrigger: UInt8, rightTrigger: UInt8
    var leftX: Int16, leftY: Int16, rightX: Int16, rightY: Int16
}

nonisolated enum ControllerMapping {
    static func state(_ pad: PadSnapshot) -> PadState {
        var flags: Int32 = 0
        let pairs: [(Bool, Int32)] = [
            (pad.a, A_FLAG), (pad.b, B_FLAG), (pad.x, X_FLAG), (pad.y, Y_FLAG),
            (pad.up, UP_FLAG), (pad.down, DOWN_FLAG), (pad.left, LEFT_FLAG), (pad.right, RIGHT_FLAG),
            (pad.leftShoulder, LB_FLAG), (pad.rightShoulder, RB_FLAG),
            (pad.leftStickClick, LS_CLK_FLAG), (pad.rightStickClick, RS_CLK_FLAG),
            (pad.menu, PLAY_FLAG), (pad.options, BACK_FLAG), (pad.home, SPECIAL_FLAG),
            (pad.touchpadClick, TOUCHPAD_FLAG), (pad.share, MISC_FLAG),
        ]
        for (pressed, flag) in pairs where pressed { flags |= flag }
        for (index, pressed) in pad.paddles.prefix(4).enumerated() where pressed { flags |= PADDLE1_FLAG << index }
        return PadState(buttons: flags,
                        leftTrigger: trigger(pad.leftTrigger), rightTrigger: trigger(pad.rightTrigger),
                        leftX: axis(pad.leftStick.x), leftY: axis(pad.leftStick.y),
                        rightX: axis(pad.rightStick.x), rightY: axis(pad.rightStick.y))
    }

    /// GameController gives -1...1 with up positive, which is also XInput's convention.
    static func axis(_ value: Float) -> Int16 { Int16((max(-1, min(1, value)) * 32767).rounded()) }
    static func trigger(_ value: Float) -> UInt8 { UInt8((max(0, min(1, value)) * 255).rounded()) }

    /// GameController reports acceleration in g, the library wants m/s² (moonlight-ios's conversion and signs).
    static func acceleration(x: Double, y: Double, z: Double) -> (Float, Float, Float) {
        let g = 9.80665
        return (Float(x * -g), Float(y * -g), Float(z * -g))
    }

    /// GameController reports rad/s, the library wants deg/s on SDL's axes (moonlight-ios's mapping).
    static func rotation(x: Double, y: Double, z: Double) -> (Float, Float, Float) {
        let degrees = 180 / Double.pi
        return (Float(x * degrees), Float(z * degrees), Float(-y * degrees))
    }

    /// A DualSense touchpad axis pair (-1...1, up positive) as the library's 0...1 coordinates (SDL's mapping).
    static func touchpadPoint(x: Float, y: Float) -> (Float, Float) { ((1 + x) / 2, 1 - (1 + y) / 2) }
}

/// Sends every connected controller to the host while streaming, and applies what the host sends back:
/// rumble, trigger rumble, motion-sensor requests and the light bar colour.
final class ControllerStreamer {
    private final class Slot {
        let index: Int
        let controller: GCController
        var last: PadState?
        var motors: [GCHapticsLocality: HapticMotor] = [:]
        var motionTimers: [UInt8: Timer] = [:]
        var touching = [false, false]
        init(index: Int, controller: GCController) { self.index = index; self.controller = controller }
    }

    private var slots: [ObjectIdentifier: Slot] = [:]
    private var observers: [any NSObjectProtocol] = []
    private var batteryTimer: Timer?
    /// While the stream menu is open, the controller drives the menu instead of the game.
    var isPaused = false {
        didSet { if isPaused { slots.values.forEach(sendNeutral) } }
    }

    private var activeMask: Int16 { slots.values.reduce(0) { $0 | Int16(1 << $1.index) } }

    func start() {
        for (name, connected) in [(Notification.Name.GCControllerDidConnect, true), (.GCControllerDidDisconnect, false)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { connected ? self?.attachAll() : self?.detachGone() }
            })
        }
        attachAll()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.slots.values.forEach { self?.sendBattery($0) } }
        }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        batteryTimer?.invalidate()
        for slot in slots.values { release(slot) }
        slots = [:]
    }

    // MARK: Host requests (from the library's callbacks, delivered on the main thread)

    func rumble(controller number: Int, low: UInt16, high: UInt16) {
        guard let slot = slot(number) else { return }
        // Big (low-frequency) motor on the left grip, small (high-frequency) on the right, as on an Xbox pad.
        if slot.motors[.leftHandle] != nil {
            slot.motors[.leftHandle]?.set(low)
            slot.motors[.rightHandle]?.set(high)
        } else {
            slot.motors[.default]?.set(max(low, high))
        }
    }

    func rumbleTriggers(controller number: Int, left: UInt16, right: UInt16) {
        guard let slot = slot(number) else { return }
        slot.motors[.leftTrigger]?.set(left)
        slot.motors[.rightTrigger]?.set(right)
    }

    func setMotion(controller number: Int, type: UInt8, rateHz: Int) {
        guard let slot = slot(number), let motion = slot.controller.motion else { return }
        slot.motionTimers[type]?.invalidate()
        slot.motionTimers[type] = nil
        if rateHz > 0, type == LI_MOTION_TYPE_GYRO ? motion.hasRotationRate : true {
            // The timer's closure may not hold GameController objects (not Sendable): look the pad up each time.
            slot.motionTimers[type] = Timer.scheduledTimer(withTimeInterval: 1 / Double(rateHz), repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sendMotion(controller: number, type: type) }
            }
        }
        // DualSense sensors are off unless switched on; keep them on only while the host wants samples.
        if motion.sensorsRequireManualActivation { motion.sensorsActive = !slot.motionTimers.isEmpty }
    }

    private func sendMotion(controller number: Int, type: UInt8) {
        guard !isPaused, let motion = slot(number)?.controller.motion else { return }
        if type == LI_MOTION_TYPE_GYRO {
            let rate = motion.rotationRate
            let (x, y, z) = ControllerMapping.rotation(x: rate.x, y: rate.y, z: rate.z)
            LiSendControllerMotionEvent(UInt8(number), UInt8(LI_MOTION_TYPE_GYRO), x, y, z)
        } else {
            let acceleration = motion.acceleration
            let (x, y, z) = ControllerMapping.acceleration(x: acceleration.x, y: acceleration.y, z: acceleration.z)
            LiSendControllerMotionEvent(UInt8(number), UInt8(LI_MOTION_TYPE_ACCEL), x, y, z)
        }
    }

    /// A game's DualSense trigger effect: `flags` says which triggers it programs (the other side's bytes are stale).
    func setTriggers(controller number: Int, flags: UInt8, left: AdaptiveTriggerEffect, right: AdaptiveTriggerEffect) {
        guard let dualSense = slot(number)?.controller.extendedGamepad as? GCDualSenseGamepad else { return }
        if flags & UInt8(DS_EFFECT_LEFT_TRIGGER) != 0 { left.apply(to: dualSense.leftTrigger) }
        if flags & UInt8(DS_EFFECT_RIGHT_TRIGGER) != 0 { right.apply(to: dualSense.rightTrigger) }
    }

    func setLight(controller number: Int, red: UInt8, green: UInt8, blue: UInt8) {
        slot(number)?.controller.light?.color = GCColor(red: Float(red) / 255, green: Float(green) / 255, blue: Float(blue) / 255)
    }

    // MARK: Controllers

    private func slot(_ number: Int) -> Slot? { slots.values.first { $0.index == number } }

    private func attachAll() {
        for controller in GCController.controllers() where slots[ObjectIdentifier(controller)] == nil {
            guard let pad = controller.extendedGamepad,
                  let index = (0..<16).first(where: { index in !slots.values.contains { $0.index == index } }) else { continue }
            let slot = Slot(index: index, controller: controller)
            slots[ObjectIdentifier(controller)] = slot
            controller.playerIndex = GCControllerPlayerIndex(rawValue: index) ?? .indexUnset
            pad.buttonHome?.preferredSystemGestureState = .disabled // let the PS/Xbox button reach the game
            for locality in [GCHapticsLocality.leftHandle, .rightHandle, .leftTrigger, .rightTrigger, .default]
            where controller.haptics?.supportedLocalities.contains(locality) == true {
                slot.motors[locality] = HapticMotor(controller: controller, locality: locality)
            }
            // The whole-pad handler, separate from the per-button handlers the menus use.
            pad.valueChangedHandler = { [weak self] pad, _ in
                MainActor.assumeIsolated { self?.send(slot, pad) }
            }
            sendArrival(slot, pad)
            sendBattery(slot)
            send(slot, pad)
        }
    }

    private func detachGone() {
        let connected = Set(GCController.controllers().map(ObjectIdentifier.init))
        for (id, slot) in slots where !connected.contains(id) {
            slots[id] = nil
            release(slot)
            // An empty event with the pad's bit cleared tells the host it's gone.
            LiSendMultiControllerEvent(Int16(slot.index), activeMask, 0, 0, 0, 0, 0, 0, 0)
        }
    }

    private func release(_ slot: Slot) {
        slot.motionTimers.values.forEach { $0.invalidate() }
        slot.motors.values.forEach { $0.stop() }
        if let motion = slot.controller.motion, motion.sensorsRequireManualActivation { motion.sensorsActive = false }
        slot.controller.extendedGamepad?.valueChangedHandler = nil
        if let dualSense = slot.controller.extendedGamepad as? GCDualSenseGamepad { // don't leave a game's resistance on
            dualSense.leftTrigger.setModeOff()
            dualSense.rightTrigger.setModeOff()
        }
        slot.controller.extendedGamepad?.buttonHome?.preferredSystemGestureState = .enabled
    }

    private func sendArrival(_ slot: Slot, _ pad: GCExtendedGamepad) {
        let isPlayStation = pad is GCDualSenseGamepad || pad is GCDualShockGamepad
        let type: Int32 = isPlayStation ? LI_CTYPE_PS
            : pad is GCXboxGamepad ? LI_CTYPE_XBOX
            : slot.controller.productCategory.localizedCaseInsensitiveContains("switch") ? LI_CTYPE_NINTENDO
            : LI_CTYPE_UNKNOWN
        var capabilities = LI_CCAP_ANALOG_TRIGGERS
        if slot.motors[.leftHandle] != nil || slot.motors[.default] != nil { capabilities |= LI_CCAP_RUMBLE }
        if slot.motors[.leftTrigger] != nil { capabilities |= LI_CCAP_TRIGGER_RUMBLE }
        if isPlayStation { capabilities |= LI_CCAP_TOUCHPAD }
        if slot.controller.motion != nil { capabilities |= LI_CCAP_ACCEL }
        if slot.controller.motion?.hasRotationRate == true { capabilities |= LI_CCAP_GYRO }
        if slot.controller.light != nil { capabilities |= LI_CCAP_RGB_LED }
        if slot.controller.battery != nil { capabilities |= LI_CCAP_BATTERY_STATE }

        var everything = PadSnapshot(a: true, b: true, x: true, y: true, up: true, down: true, left: true, right: true,
                                     leftShoulder: true, rightShoulder: true, leftStickClick: true, rightStickClick: true,
                                     menu: true, options: pad.buttonOptions != nil, home: pad.buttonHome != nil)
        everything.touchpadClick = isPlayStation
        if let xbox = pad as? GCXboxGamepad {
            everything.share = true
            everything.paddles = [xbox.paddleButton1, xbox.paddleButton2, xbox.paddleButton3, xbox.paddleButton4].map { $0 != nil }
        }
        LiSendControllerArrivalEvent(UInt8(slot.index), UInt16(bitPattern: activeMask), UInt8(type),
                                     UInt32(bitPattern: ControllerMapping.state(everything).buttons), UInt16(capabilities))
    }

    private func sendBattery(_ slot: Slot) {
        guard let battery = slot.controller.battery else { return }
        let state: Int32 = switch battery.batteryState {
        case .charging: LI_BATTERY_STATE_CHARGING
        case .discharging: LI_BATTERY_STATE_DISCHARGING
        case .full: LI_BATTERY_STATE_FULL
        default: LI_BATTERY_STATE_UNKNOWN
        }
        LiSendControllerBatteryEvent(UInt8(slot.index), UInt8(state), UInt8((battery.batteryLevel * 100).rounded()))
    }

    private func send(_ slot: Slot, _ pad: GCExtendedGamepad) {
        guard !isPaused else { return }
        var state = ControllerMapping.state(snapshot(pad))
        state.buttons = ButtonRemap.current.apply(state.buttons)
        if state != slot.last {
            slot.last = state
            LiSendMultiControllerEvent(Int16(slot.index), activeMask, state.buttons, state.leftTrigger, state.rightTrigger,
                                       state.leftX, state.leftY, state.rightX, state.rightY)
        }
        if let dualSense = pad as? GCDualSenseGamepad, LiGetHostFeatureFlags() & UInt32(LI_FF_CONTROLLER_TOUCH_EVENTS) != 0 {
            sendTouch(slot, finger: 0, dualSense.touchpadPrimary)
            sendTouch(slot, finger: 1, dualSense.touchpadSecondary)
        }
    }

    private func sendNeutral(_ slot: Slot) {
        slot.last = nil
        LiSendMultiControllerEvent(Int16(slot.index), activeMask, 0, 0, 0, 0, 0, 0, 0)
    }

    /// The DualSense reports a finger as a non-zero position and no finger as (0, 0), like moonlight-ios assumes.
    private func sendTouch(_ slot: Slot, finger: Int, _ touch: GCControllerDirectionPad) {
        let x = touch.xAxis.value, y = touch.yAxis.value
        let isTouching = x != 0 || y != 0
        let (nx, ny) = ControllerMapping.touchpadPoint(x: x, y: y)
        let event: Int32? = isTouching ? (slot.touching[finger] ? LI_TOUCH_EVENT_MOVE : LI_TOUCH_EVENT_DOWN)
            : (slot.touching[finger] ? LI_TOUCH_EVENT_UP : nil)
        slot.touching[finger] = isTouching
        if let event { LiSendControllerTouchEvent(UInt8(slot.index), UInt8(event), UInt32(finger), nx, ny, 1) }
    }

    private func snapshot(_ pad: GCExtendedGamepad) -> PadSnapshot {
        var snapshot = PadSnapshot(
            a: pad.buttonA.isPressed, b: pad.buttonB.isPressed, x: pad.buttonX.isPressed, y: pad.buttonY.isPressed,
            up: pad.dpad.up.isPressed, down: pad.dpad.down.isPressed, left: pad.dpad.left.isPressed, right: pad.dpad.right.isPressed,
            leftShoulder: pad.leftShoulder.isPressed, rightShoulder: pad.rightShoulder.isPressed,
            leftStickClick: pad.leftThumbstickButton?.isPressed ?? false, rightStickClick: pad.rightThumbstickButton?.isPressed ?? false,
            menu: pad.buttonMenu.isPressed, options: pad.buttonOptions?.isPressed ?? false, home: pad.buttonHome?.isPressed ?? false,
            leftTrigger: pad.leftTrigger.value, rightTrigger: pad.rightTrigger.value,
            leftStick: (pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value),
            rightStick: (pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value))
        if let dualSense = pad as? GCDualSenseGamepad { snapshot.touchpadClick = dualSense.touchpadButton.isPressed }
        if let dualShock = pad as? GCDualShockGamepad { snapshot.touchpadClick = dualShock.touchpadButton.isPressed }
        if let xbox = pad as? GCXboxGamepad {
            snapshot.share = xbox.buttonShare?.isPressed ?? false
            snapshot.paddles = [xbox.paddleButton1, xbox.paddleButton2, xbox.paddleButton3, xbox.paddleButton4].map { $0?.isPressed ?? false }
        }
        return snapshot
    }
}

/// One rumble motor: a CoreHaptics engine on one part of the controller playing an endless pattern whose
/// intensity follows the host (moonlight-ios's HapticContext).
private final class HapticMotor {
    private let engine: CHHapticEngine
    // The basic player, as moonlight-ios uses: a controller's haptic engine rejected the advanced one.
    private let player: any CHHapticPatternPlayer
    private var isRunning = false
    private var safetyStop: Task<Void, Never>?

    init?(controller: GCController, locality: GCHapticsLocality) {
        guard let engine = controller.haptics?.createEngine(withLocality: locality) else { return nil }
        do {
            try engine.start()
            // Intensity starts at 1 because the dynamic intensity is multiplied by it.
            let event = CHHapticEvent(eventType: .hapticContinuous,
                                      parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1)],
                                      relativeTime: 0, duration: TimeInterval(GCHapticDurationInfinite))
            player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
        } catch {
            return nil
        }
        self.engine = engine
    }

    /// 0 stops the motor; anything else sets its strength out of 65535 for at most 30 seconds.
    func set(_ amplitude: UInt16) {
        safetyStop?.cancel()
        if amplitude != 0 {
            // Like moonlight-qt (SDL rumble with a 30 s duration): a stop the host never sends can't buzz forever.
            // Vibepollo's virtual DualSense ignores rumble reports without the "compatible vibration" flag,
            // which is how Steam's test left it stuck on. Each new rumble message restarts the clock.
            safetyStop = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                if !Task.isCancelled { self?.set(0) }
            }
        }
        if amplitude == 0 {
            // Silence it first, so it goes quiet even if stopping the endless pattern doesn't take effect.
            let silent = CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0, relativeTime: 0)
            try? player.sendParameters([silent], atTime: CHHapticTimeImmediate)
            if isRunning { try? player.stop(atTime: CHHapticTimeImmediate) }
            isRunning = false
            return
        }
        let intensity = CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: Float(amplitude) / 65535, relativeTime: 0)
        try? player.sendParameters([intensity], atTime: CHHapticTimeImmediate)
        if !isRunning {
            do {
                try player.start(atTime: CHHapticTimeImmediate)
            } catch { // the engine stops when the app was in the background
                try? engine.start()
                try? player.start(atTime: CHHapticTimeImmediate)
            }
            isRunning = true
        }
    }

    func stop() {
        safetyStop?.cancel()
        try? player.stop(atTime: CHHapticTimeImmediate)
        engine.stop()
    }
}
