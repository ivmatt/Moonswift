import Foundation

/// One second of network health, from moonlight-common-c's statistics.
nonisolated struct NetworkSample {
    /// Frames the network lost for good (gaps in frame numbers).
    var lostFrames = 0
    /// Packets lost beyond what error correction could rebuild.
    var fecFailed = 0
    /// Packets lost but rebuilt by error correction: fine, but a sign the link is near its limit.
    var fecRecovered = 0
    /// Video packets received, to turn the counts above into a rate.
    var packets = 0
    /// Round-trip time to the PC, if known.
    var rttMs: Int?
    /// The library's own "poor connection" verdict.
    var isPoor = false
}

/// Adaptive bitrate: lowers the stream's bitrate quickly at the first sign of trouble and raises it slowly while the
/// network is calm, never above `ceiling` (your setting). The usual pattern for real-time video (and TCP): a softer
/// picture beats a frozen one. Pure logic, one `update` per second, so the rules are testable without a network.
nonisolated struct BitrateController {
    static let floor = 5_000 // kbps
    static let decreaseFactor = 0.7
    static let minSecondsBetweenDecreases: TimeInterval = 2
    static let calmSecondsBeforeIncrease = 10
    static let pauseAfterDecrease: TimeInterval = 30

    private(set) var ceiling: Int
    private(set) var target: Int
    private(set) var reason = "at your setting"

    private var baselineRTT: Int?
    private var highRTTSeconds = 0
    private var calmSeconds = 0
    private var lastDecrease: TimeInterval = -.infinity

    init(ceiling: Int, start: Int? = nil) {
        self.ceiling = max(ceiling, Self.floor)
        target = min(max(start ?? ceiling, Self.floor), self.ceiling)
    }

    /// The setting changed mid-stream: the new ceiling caps the current target too.
    mutating func setCeiling(_ kbps: Int) -> Int? {
        ceiling = max(kbps, Self.floor)
        guard target > ceiling else { return nil }
        target = ceiling
        reason = "at your setting"
        return target
    }

    /// Returns a new bitrate (kbps) when it should change, nil otherwise.
    mutating func update(_ sample: NetworkSample, now: TimeInterval) -> Int? {
        // Delay well above the best seen this stream means queues are filling: congestion before any loss.
        if let rtt = sample.rttMs {
            baselineRTT = min(baselineRTT ?? rtt, rtt)
            let baseline = baselineRTT ?? rtt
            highRTTSeconds = rtt > baseline + max(20, baseline / 2) ? highRTTSeconds + 1 : 0
        }

        let trouble: String? =
            sample.lostFrames > 0 || sample.fecFailed > 0 ? "packet loss"
            : sample.isPoor ? "a poor connection"
            : highRTTSeconds >= 2 ? "rising delay" // two seconds in a row, so one spike doesn't count
            : nil
        if let trouble {
            calmSeconds = 0
            guard now - lastDecrease >= Self.minSecondsBetweenDecreases else { return nil } // let the last cut take effect
            let lowered = max(Self.floor, Int(Double(target) * Self.decreaseFactor) / 1000 * 1000)
            guard lowered < target else { return nil }
            target = lowered
            lastDecrease = now
            highRTTSeconds = 0
            reason = "lowered for \(trouble)"
            return target
        }

        // Loss being repaired on more than 5% of packets: don't push further, but don't cut either.
        if sample.packets > 0, Double(sample.fecRecovered) / Double(sample.packets) > 0.05 {
            calmSeconds = 0
            return nil
        }

        calmSeconds += 1
        guard calmSeconds >= Self.calmSecondsBeforeIncrease, now - lastDecrease >= Self.pauseAfterDecrease,
              target < ceiling else { return nil }
        calmSeconds = 0
        target = min(ceiling, target + max(2_000, target / 10))
        reason = target == ceiling ? "at your setting" : "raising"
        return target
    }
}

/// The counters read once a second; two of them make a `PerformanceWindow`.
nonisolated struct StreamCounters {
    var frames = 0, bytes = 0, lostFrames = 0
    var packets = 0, fecRecovered = 0, fecFailed = 0
    var timedFrames = 0, receiveMicroseconds = 0, queueMicroseconds = 0
    var hostLatencyTenthsMs = 0, hostLatencyFrames = 0
}

/// One second of the stream, for the performance overlay and adaptive bitrate.
nonisolated struct PerformanceWindow {
    let fps: Double
    let mbps: Double
    let lostFrames: Int
    /// Frames lost out of all frames the PC sent this second.
    let lossPercent: Double
    /// Packets that needed error correction, out of all packets.
    let repairedPercent: Double
    let fecFailed: Int, fecRecovered: Int, packets: Int
    /// Average milliseconds per frame, nil when there was nothing to average.
    let hostMs: Double?, receiveMs: Double?, queueMs: Double?

    init(from old: StreamCounters, to new: StreamCounters, seconds: Double) {
        let seconds = max(seconds, 0.001)
        let frames = new.frames - old.frames
        fps = Double(frames) / seconds
        mbps = Double(new.bytes - old.bytes) * 8 / seconds / 1_000_000
        lostFrames = new.lostFrames - old.lostFrames
        lossPercent = frames + lostFrames > 0 ? Double(lostFrames) * 100 / Double(frames + lostFrames) : 0
        packets = new.packets - old.packets
        fecRecovered = new.fecRecovered - old.fecRecovered
        fecFailed = new.fecFailed - old.fecFailed
        repairedPercent = packets > 0 ? Double(fecRecovered) * 100 / Double(packets) : 0
        let timed = new.timedFrames - old.timedFrames
        receiveMs = timed > 0 ? Double(new.receiveMicroseconds - old.receiveMicroseconds) / Double(timed) / 1000 : nil
        queueMs = timed > 0 ? Double(new.queueMicroseconds - old.queueMicroseconds) / Double(timed) / 1000 : nil
        let hosted = new.hostLatencyFrames - old.hostLatencyFrames
        hostMs = hosted > 0 ? Double(new.hostLatencyTenthsMs - old.hostLatencyTenthsMs) / Double(hosted) / 10 : nil
    }

    func sample(rttMs: Int?, isPoor: Bool) -> NetworkSample {
        NetworkSample(lostFrames: lostFrames, fecFailed: fecFailed, fecRecovered: fecRecovered, packets: packets,
                      rttMs: rttMs, isPoor: isPoor)
    }
}
