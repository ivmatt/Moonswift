import GameController

/// DualSense adaptive triggers: the PC forwards the game's trigger effect as the controller's own 11 bytes (an effect
/// type and 10 parameters); this turns them into GameController's trigger modes.
// Ported from VoidLink's ControllerUtil.swift (adaptive trigger fixes by sirius128@github, 2026, GPL-3.0).
nonisolated struct AdaptiveTriggerEffect: Equatable {
    enum Mode: Equatable { case off, feedback, positionalFeedback, weapon, slopeFeedback, vibration, positionalVibration }

    var mode = Mode.off
    var startPosition: Float = 0, endPosition: Float = 0
    var startStrength: Float = 0, endStrength: Float = 0
    var frequency: Float = 0
    var positionalStrength = [Float](repeating: 0, count: 10)

    init(mode: Mode = .off) { self.mode = mode }

    /// `bytes` is the 10-byte parameter block for effect `type`.
    init(type: UInt8, bytes: [UInt8]) {
        guard bytes.count >= 10 else { return }
        switch type {
        case 0x01, 0x11: // simple feedback (0x11: strength 0...10)
            mode = .feedback
            startPosition = Self.byte(bytes[0])
            startStrength = type == 0x01 ? Self.byte(bytes[1]) : Self.clamp(Float(bytes[1]) / 10)
        case 0x02, 0x12: // simple weapon
            mode = .weapon
            setSpan(first: Int(bytes[0]), last: Int(bytes[1]), count: 256)
            startStrength = type == 0x02 ? Self.byte(bytes[2]) : Self.clamp(Float(bytes[2]) / 10)
        case 0x06: // simple vibration
            mode = .vibration
            frequency = Self.clamp(Float(bytes[0]) / 255)
            startStrength = Self.byte(bytes[1])
            startPosition = Self.byte(bytes[2])
        case 0x21: // feedback per zone
            self = Self.zoned(bytes, mode: .positionalFeedback)
        case 0x26: // vibration per zone
            self = Self.zoned(bytes, mode: .positionalVibration)
            frequency = Self.clamp(Float(bytes[8]) / 255)
        case 0x25: // weapon
            mode = .weapon
            setSpan(first: Self.firstZone(bytes), last: Self.lastZone(bytes), count: 10)
            startStrength = Float((bytes[2] & 7) + 1) / 8
        case 0x22: // slope feedback
            mode = .slopeFeedback
            setSpan(first: Self.firstZone(bytes), last: Self.lastZone(bytes), count: 10)
            startStrength = Float((bytes[2] & 7) + 1) / 8
            endStrength = Float(((bytes[2] >> 3) & 7) + 1) / 8
        case 0x23, 0x27: // bow, galloping: closest is a vibration
            mode = .vibration
            startPosition = Self.zone(Self.firstZone(bytes) ?? 0)
            startStrength = type == 0x23 ? 0.5 : Self.clamp(Float(max(bytes[2] & 7, (bytes[2] >> 3) & 7)) / 7)
            frequency = Self.clamp(Float(bytes[3]) / 255)
        default: // 0x00, 0x05 and unknown: off
            mode = .off
        }
        // An effect with no strength (or a vibration with no frequency) is off.
        let isVibration = mode == .vibration || mode == .positionalVibration
        if max(startStrength, endStrength) <= 0 || (isVibration && frequency <= 0) { mode = .off }
    }

    func apply(to trigger: GCDualSenseAdaptiveTrigger) {
        let s = positionalStrength
        switch mode {
        case .off:
            trigger.setModeOff()
        case .feedback:
            trigger.setModeFeedbackWithStartPosition(startPosition, resistiveStrength: startStrength)
        case .weapon:
            trigger.setModeWeaponWithStartPosition(startPosition, endPosition: endPosition, resistiveStrength: startStrength)
        case .vibration:
            trigger.setModeVibrationWithStartPosition(startPosition, amplitude: startStrength, frequency: frequency)
        case .positionalFeedback:
            trigger.setModeFeedback(resistiveStrengths: .init(values: (s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8], s[9])))
        case .positionalVibration:
            trigger.setModeVibration(amplitudes: .init(values: (s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8], s[9])),
                                     frequency: frequency)
        case .slopeFeedback:
            trigger.setModeSlopeFeedback(startPosition: startPosition, endPosition: endPosition,
                                         startStrength: startStrength, endStrength: endStrength)
        }
    }

    // MARK: Decoding helpers

    private static func clamp(_ value: Float) -> Float { max(0, min(1, value)) }
    private static func step(_ step: Int, count: Int) -> Float { clamp(Float(step) / Float(count - 1)) }
    private static func byte(_ value: UInt8) -> Float { step(Int(value), count: 256) }
    private static func zone(_ zone: Int) -> Float { step(zone, count: 10) }
    /// Effects from 0x21 up mark the active zones (10 positions along the pull) in the first two bytes.
    private static func zoneMask(_ bytes: [UInt8]) -> UInt16 { (UInt16(bytes[0]) | UInt16(bytes[1]) << 8) & 0x03FF }
    private static func firstZone(_ bytes: [UInt8]) -> Int? { let mask = zoneMask(bytes); return mask == 0 ? nil : mask.trailingZeroBitCount }
    private static func lastZone(_ bytes: [UInt8]) -> Int? { let mask = zoneMask(bytes); return mask == 0 ? nil : 15 - mask.leadingZeroBitCount }

    private mutating func setSpan(first: Int?, last: Int?, count: Int) {
        let start = max(0, min(first ?? 0, count - 2))
        let end = max(start + 1, min(last ?? start + 1, count - 1))
        startPosition = Self.step(start, count: count)
        endPosition = Self.step(end, count: count)
    }

    /// Per-zone strength, 3 bits each, packed after the zone mask.
    private static func zoned(_ bytes: [UInt8], mode: Mode) -> AdaptiveTriggerEffect {
        var effect = AdaptiveTriggerEffect(mode: mode)
        let mask = zoneMask(bytes)
        let packed = UInt32(bytes[2]) | UInt32(bytes[3]) << 8 | UInt32(bytes[4]) << 16 | UInt32(bytes[5]) << 24
        for zone in 0..<10 where mask & (1 << zone) != 0 {
            let strength = clamp(Float((packed >> (3 * zone)) & 7 + 1) / 8)
            effect.positionalStrength[zone] = strength
            effect.startStrength = max(effect.startStrength, strength)
        }
        effect.startPosition = Self.zone(firstZone(bytes) ?? 0)
        return effect
    }
}
