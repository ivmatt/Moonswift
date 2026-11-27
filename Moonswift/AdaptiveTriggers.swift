import GameController

/// DualSense adaptive triggers. The PC forwards the game's trigger effect unchanged: one type byte and 10 parameter
/// bytes in the controller's own format. `init(type:bytes:)` decodes that into one of GameController's trigger modes
/// (pure logic, unit-tested); `apply(to:)` sets it on a real trigger.
///
/// The byte format follows Nielk1's TriggerEffectGenerator (MIT, © 2021-2022 John "Nielk1" Klein):
/// https://gist.github.com/Nielk1/6d54cc2c00d2201ccb8c2720ad7538db
/// Its parameter offsets are one higher than here because it counts the type byte as offset 0.
nonisolated struct AdaptiveTriggerEffect: Equatable {
    enum Mode: Equatable { case off, feedback, positionalFeedback, weapon, vibration, positionalVibration }

    var mode = Mode.off
    /// Trigger travel, 0 (released) to 1 (fully pressed).
    var startPosition: Float = 0, endPosition: Float = 0
    /// Resistance (feedback, weapon) or amplitude (vibration), 0 to 1.
    var startStrength: Float = 0
    /// Vibration frequency as GameController takes it: 0 to 1 of the byte's 255 Hz range.
    var frequency: Float = 0
    /// The positional modes' strength or amplitude for each of the 10 zones, from released to pressed.
    var positionalStrength = [Float](repeating: 0, count: 10)

    init(mode: Mode = .off) { self.mode = mode }

    init(type: UInt8, bytes: [UInt8]) {
        guard bytes.count >= 10 else { return } // malformed: leave the trigger off
        let raw = { (index: Int) in Float(bytes[index]) / 255 }
        switch type {
        case 0x21: // Feedback: resistance in the active zones (also how slopes and per-zone feedback arrive)
            self = Self.zoned(bytes, mode: .feedback, positional: .positionalFeedback)
        case 0x26: // Vibration: amplitude in the active zones, frequency in Hz
            self = Self.zoned(bytes, mode: .vibration, positional: .positionalVibration, frequency: raw(8))
        case 0x25, 0x22: // Weapon; Bow is a weapon whose snap-back force GameController can't express
            self = Self.weapon(mask: bytes, strength: Float(bytes[2] & 7 + 1) / 8)
        case 0x27: // Machine: two alternating amplitudes (0-7) at a frequency; play the stronger one
            let amplitude = Float(max(bytes[2] & 7, bytes[2] >> 3 & 7)) / 7
            self = Self.vibration(mask: bytes, amplitude: amplitude, frequency: raw(3))
        case 0x23: // Galloping: a rhythm of two "feet" at a frequency; play a full-strength vibration
            self = Self.vibration(mask: bytes, amplitude: 1, frequency: raw(3))
        // Older firmware effects with raw parameters. Their ranges aren't documented; bytes are read as 0-255.
        case 0x01: self = Self.make(.feedback, start: raw(0), strength: raw(1))
        case 0x11: self = Self.make(.feedback, start: raw(0), strength: Float(min(bytes[1], 10)) / 10)
        case 0x02: self = Self.make(.weapon, start: raw(0), end: raw(1), strength: raw(2))
        case 0x12: self = Self.make(.weapon, start: raw(0), end: raw(1), strength: Float(min(bytes[2], 10)) / 10)
        case 0x06: self = Self.make(.vibration, start: raw(2), strength: raw(1), frequency: raw(0))
        default: return // 0x05 Off, and anything unknown
        }
    }

    func apply(to trigger: GCDualSenseAdaptiveTrigger) {
        let z = positionalStrength
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
            trigger.setModeFeedback(resistiveStrengths: .init(values: (z[0], z[1], z[2], z[3], z[4], z[5], z[6], z[7], z[8], z[9])))
        case .positionalVibration:
            trigger.setModeVibration(amplitudes: .init(values: (z[0], z[1], z[2], z[3], z[4], z[5], z[6], z[7], z[8], z[9])),
                                     frequency: frequency)
        }
    }

    // MARK: Decoding

    /// Zones 0-9 as bits of bytes 0-1.
    private static func zones(_ bytes: [UInt8]) -> [Int] {
        let mask = Int(bytes[0]) | Int(bytes[1]) << 8
        return (0..<10).filter { mask & 1 << $0 != 0 }
    }

    /// A zone's position along the trigger's travel.
    private static func position(_ zone: Int) -> Float { Float(zone) / 9 }

    /// Feedback or vibration with a 3-bit level (stored as level - 1, so 1-8) per active zone, packed little-endian
    /// into bytes 2-5. One level from the first active zone to the end uses the simple mode; anything else is positional.
    private static func zoned(_ bytes: [UInt8], mode: Mode, positional: Mode, frequency: Float = 1) -> Self {
        let packed = (2...5).reduce(UInt32(0)) { $0 | UInt32(bytes[$1]) << (8 * ($1 - 2)) }
        var levels = [Float](repeating: 0, count: 10)
        for zone in zones(bytes) { levels[zone] = Float(packed >> (3 * zone) & 7 + 1) / 8 }
        guard let first = levels.firstIndex(where: { $0 > 0 }), frequency > 0 else { return Self() }
        var effect = make(mode, start: position(first), strength: levels[first], frequency: frequency)
        if levels[first...].contains(where: { $0 != levels[first] }) {
            effect.mode = positional
            effect.positionalStrength = levels
        }
        return effect
    }

    /// Resistance between the lowest and highest zone bits of bytes 0-1.
    private static func weapon(mask bytes: [UInt8], strength: Float) -> Self {
        let zones = zones(bytes)
        guard let start = zones.first, let end = zones.last, end > start else { return Self() }
        return make(.weapon, start: position(start), end: position(end), strength: strength)
    }

    /// Vibration from the lowest zone bit of bytes 0-1.
    private static func vibration(mask bytes: [UInt8], amplitude: Float, frequency: Float) -> Self {
        guard let start = zones(bytes).first else { return Self() }
        return make(.vibration, start: position(start), strength: amplitude, frequency: frequency)
    }

    /// No strength, or a vibration with no frequency, means no effect.
    private static func make(_ mode: Mode, start: Float, end: Float = 0, strength: Float, frequency: Float = 0) -> Self {
        guard strength > 0, mode != .vibration || frequency > 0 else { return Self() }
        var effect = Self(mode: mode)
        effect.startPosition = start
        effect.endPosition = end
        effect.startStrength = strength
        effect.frequency = mode == .vibration ? frequency : 0
        return effect
    }
}
