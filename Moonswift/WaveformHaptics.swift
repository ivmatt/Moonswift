import Foundation

/// One 5 ms piece of a host's DualSense waveform haptics, reduced to what iOS can play: for each grip, a strength and a
/// sharpness. The host sends the samples a game wrote to a wired DualSense's actuators (48 kHz, 16-bit, left and right
/// interleaved, little-endian); iOS can't play samples on a controller, only intensity and sharpness, so each piece
/// becomes how loud it is and how fast it wobbles.
nonisolated struct WaveformFrame: Equatable, Sendable {
    struct Side: Equatable, Sendable {
        /// 0 (still) ... 1.
        var strength: Float
        /// 0 (a soft, low rumble) ... 1 (a crisp, high buzz).
        var sharpness: Float
    }

    var left: Side
    var right: Side

    /// Settings › Controller › DualSense Haptics, on unless turned off.
    static var isOn: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.dualSenseHaptics) as? Bool ?? true
    }

    static let sampleRate: Float = 48_000
    /// Quieter than this (out of 1) is felt as nothing, and noise shouldn't hum.
    static let floor: Float = 0.02
    /// RMS of the actuator signal to strength: haptic tracks rarely sit near full scale, so a little gain.
    static let gain: Float = 1.6
    /// The band the actuators are felt in, for sharpness: at or below `lowHz` soft, at or above `highHz` crisp.
    static let lowHz: Float = 30, highHz: Float = 320

    /// nil when `pcm` isn't whole stereo 16-bit frames.
    init?(pcm: UnsafeRawBufferPointer) {
        let frames = pcm.count / 4
        guard frames > 0, pcm.count == frames * 4 else { return nil }
        func side(_ channel: Int) -> Side {
            var sumOfSquares: Float = 0, crossings = 0, previous: Int16 = 0, first = 0, last = 0
            for frame in 0..<frames {
                let sample = Int16(littleEndian: pcm.loadUnaligned(fromByteOffset: frame * 4 + channel * 2, as: Int16.self))
                let value = Float(sample) / 32_768
                sumOfSquares += value * value
                if frame > 0, (sample < 0) != (previous < 0) {
                    if crossings == 0 { first = frame }
                    last = frame
                    crossings += 1
                }
                previous = sample
            }
            let rms = (sumOfSquares / Float(frames)).squareRoot()
            let strength = min(rms * Self.gain, 1)
            guard strength >= Self.floor else { return Side(strength: 0, sharpness: 0.5) }
            // A tone crosses zero twice a cycle. 5 ms holds few cycles, so time them between the first and last crossing
            // when there are two or more; with fewer, the whole piece is all there is (a low tone).
            let hertz = crossings >= 2 ? Float(crossings - 1) / 2 / (Float(last - first) / Self.sampleRate)
                                       : Float(crossings) / 2 / (Float(frames) / Self.sampleRate)
            let sharpness = min(max((hertz - Self.lowHz) / (Self.highHz - Self.lowHz), 0), 1)
            return Side(strength: strength, sharpness: sharpness)
        }
        left = side(0)
        right = side(1)
    }
}
