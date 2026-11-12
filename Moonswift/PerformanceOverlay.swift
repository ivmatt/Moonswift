import SwiftUI

/// Live stream statistics in a corner of the stream, for testing and tuning. Updated once a second; touches pass
/// through to the game.
struct PerformanceOverlay: View {
    /// One second's figures, already formatted.
    nonisolated struct Readout {
        let lines: [String]

        init(window: PerformanceWindow, targetFPS: Int, video: String?, rtt: (ms: Int, variance: Int)?, isRemote: Bool) {
            func ms(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "–" }
            lines = [
                (video ?? "Waiting for video…") + (isRemote ? " · Remote" : " · Local"),
                // A still screen sends fewer frames than the target: the PC only sends frames when something changes.
                String(format: "%.0f / %d fps · %.1f Mbps", window.fps, targetFPS, window.mbps),
                (rtt.map { "RTT \($0.ms) ± \($0.variance) ms" } ?? "RTT –")
                    + String(format: " · Lost %d frame%@ (%.1f%%)", window.lostFrames, window.lostFrames == 1 ? "" : "s", window.lossPercent),
                String(format: "Repaired %.1f%% of packets", window.repairedPercent)
                    + (window.fecFailed > 0 ? " · \(window.fecFailed) unrepairable" : ""),
                "Host \(ms(window.hostMs)) · Network \(ms(window.receiveMs)) · Queue \(ms(window.queueMs)) ms",
            ]
        }
    }

    let readout: Readout
    let adaptiveNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(readout.lines + (adaptiveNote.map { [$0] } ?? []), id: \.self) { Text($0) }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.55), in: .rect(cornerRadius: 8))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Performance")
    }
}
