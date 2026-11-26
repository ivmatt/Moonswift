import SwiftUI

/// Live stream statistics as a small heads-up display, in the style of Apple's Metal Performance HUD: a dark panel
/// with a big frame rate, a frame rate graph and colour-coded rows. Drag it to any corner; tap it to shrink it to one
/// line. Updated once a second.
struct PerformanceOverlay: View {
    /// One second's figures.
    nonisolated struct Readout {
        let video: String
        let connection: String? // "Local" or "Remote", once known
        let fps: Double
        let targetFPS: Int
        let mbps: Double
        let rtt: (ms: Int, variance: Int)?
        let lostFrames: Int
        let lossPercent: Double
        let repairedPercent: Double
        let fecFailed: Int
        let hostMs: Double?, networkMs: Double?, queueMs: Double?

        init(window: PerformanceWindow, targetFPS: Int, video: String?, rtt: (ms: Int, variance: Int)?, connection: String?) {
            self.video = video ?? "Waiting for video…"
            self.connection = connection
            fps = window.fps
            self.targetFPS = targetFPS
            mbps = window.mbps
            self.rtt = rtt
            lostFrames = window.lostFrames
            lossPercent = window.lossPercent
            repairedPercent = window.repairedPercent
            fecFailed = window.fecFailed
            hostMs = window.hostMs
            networkMs = window.receiveMs
            queueMs = window.queueMs
        }

        /// Good, so-so or bad, for colour.
        enum Health { case good, warning, bad }

        /// A still screen sends fewer frames than the target (the PC only sends frames when something changes), so a
        /// low rate is a hint, not proof of trouble.
        var fpsHealth: Health { Self.health(fps: fps, target: targetFPS) }
        static func health(fps: Double, target: Int) -> Health {
            fps >= Double(target) * 0.95 ? .good : fps >= Double(target) * 0.6 ? .warning : .bad
        }
        var rttHealth: Health { (rtt?.ms ?? 0) < 40 ? .good : (rtt?.ms ?? 0) < 80 ? .warning : .bad }
        var lossHealth: Health { lostFrames == 0 && fecFailed == 0 ? (repairedPercent < 5 ? .good : .warning) : .bad }

        var rttText: String { rtt.map { "\($0.ms) ± \($0.variance) ms" } ?? "–" }
        var lossText: String {
            String(format: "%d lost (%.1f%%) · %.1f%% repaired", lostFrames, lossPercent, repairedPercent)
                + (fecFailed > 0 ? " · \(fecFailed) unrepairable" : "")
        }
        var latencyText: String {
            func ms(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "–" }
            return "host \(ms(hostMs)) · net \(ms(networkMs)) · queue \(ms(queueMs)) ms"
        }
    }

    enum Corner: String {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var alignment: Alignment {
            switch self {
            case .topLeading: .topLeading
            case .topTrailing: .topTrailing
            case .bottomLeading: .bottomLeading
            case .bottomTrailing: .bottomTrailing
            }
        }
    }

    let readout: Readout
    let adaptiveNote: String?
    /// Frame rates of the last minute, oldest first.
    let history: [Double]

    @AppStorage(SettingsKey.hudCorner) private var corner = SettingsDefault.hudCorner
    @AppStorage(SettingsKey.hudCompact) private var isCompact = SettingsDefault.hudCompact
    @State private var drag = CGSize.zero

    var body: some View {
        GeometryReader { geometry in
            panel
                .offset(drag)
                .gesture(DragGesture(minimumDistance: 8, coordinateSpace: .named("hud"))
                    .onChanged { drag = $0.translation }
                    .onEnded { value in
                        // Snap to the corner nearest where it was let go.
                        let right = value.location.x > geometry.size.width / 2
                        let bottom = value.location.y > geometry.size.height / 2
                        withAnimation(.snappy) {
                            corner = bottom ? (right ? .bottomTrailing : .bottomLeading) : (right ? .topTrailing : .topLeading)
                            drag = .zero
                        }
                    })
                .onTapGesture { withAnimation(.snappy) { isCompact.toggle() } }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
        }
        .coordinateSpace(.named("hud"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Performance")
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isCompact {
                HStack(spacing: 10) {
                    fpsLabel(size: 15)
                    Text(String(format: "%.0f Mbps", readout.mbps)).foregroundStyle(Self.cyan)
                    Text(readout.rtt.map { "\($0.ms) ms" } ?? "– ms").foregroundStyle(color(readout.rttHealth))
                }
            } else {
                Text(readout.video + (readout.connection.map { " · \($0)" } ?? ""))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    fpsLabel(size: 26)
                    Text("/ \(readout.targetFPS)").foregroundStyle(.white.opacity(0.5))
                }
                FrameRateGraph(history: history, target: readout.targetFPS)
                    .frame(height: 30)
                row("Bitrate", String(format: "%.1f Mbps", readout.mbps), Self.cyan)
                if let adaptiveNote {
                    row("Adaptive", adaptiveNote.replacingOccurrences(of: "Adaptive: ", with: ""), Self.cyan.opacity(0.8))
                }
                row("RTT", readout.rttText, color(readout.rttHealth))
                row("Latency", readout.latencyText, .white)
                row("Network", readout.lossText, color(readout.lossHealth))
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(.white)
        .padding(isCompact ? 8 : 10)
        .frame(width: isCompact ? nil : 300, alignment: .leading)
        .background(.black.opacity(0.7), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12)))
    }

    private func fpsLabel(size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(String(format: "%.0f", readout.fps)).font(.system(size: size, weight: .bold, design: .monospaced))
            Text("FPS").font(.system(size: max(size * 0.45, 9), weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(color(readout.fpsHealth))
    }

    private func row(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.white.opacity(0.5)).frame(width: 58, alignment: .leading)
            Text(value).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    static let green = Color(red: 0.35, green: 0.9, blue: 0.45)
    static let yellow = Color(red: 1, green: 0.8, blue: 0.25)
    static let red = Color(red: 1, green: 0.38, blue: 0.35)
    static let cyan = Color(red: 0.4, green: 0.82, blue: 1)

    static func color(_ health: Readout.Health) -> Color {
        switch health {
        case .good: green
        case .warning: yellow
        case .bad: red
        }
    }

    private func color(_ health: Readout.Health) -> Color { Self.color(health) }
}

/// One bar per second of the last minute, its height the frame rate against the target, coloured like the number.
private struct FrameRateGraph: View {
    let history: [Double]
    let target: Int

    var body: some View {
        Canvas { context, size in
            let slots = 60
            let width = size.width / CGFloat(slots)
            let shown = Array(history.suffix(slots))
            context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 0.5)), with: .color(.white.opacity(0.25))) // the target
            for (index, fps) in shown.enumerated() {
                let height = max(1, size.height * min(fps / Double(max(target, 1)), 1))
                let x = CGFloat(slots - shown.count + index) * width
                let tint = PerformanceOverlay.color(PerformanceOverlay.Readout.health(fps: fps, target: target))
                context.fill(Path(CGRect(x: x, y: size.height - height, width: max(width - 1, 1), height: height)), with: .color(tint))
            }
        }
        .background(.white.opacity(0.05))
    }
}
