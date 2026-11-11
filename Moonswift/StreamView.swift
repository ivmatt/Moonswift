import SwiftUI

/// What the library screen hands over after a successful Launch or Resume.
struct StreamTarget: Hashable {
    let title: String
    let launch: LaunchSession
    let width: Int
    let height: Int
    let fps: Int
}

/// Debug screen for a live connection: each connection stage, the frame and packet counters, and the library's log.
/// Nothing is decoded yet. Leaving the screen (Back or B) disconnects; the game keeps running on the PC.
struct StreamView: View {
    let client: HostClient
    let target: StreamTarget

    @Environment(\.dismiss) private var dismiss
    @State private var session = StreamSession()
    @State private var rates = "–" // frames/s and Mbps over the last refresh

    private var stats: StreamStats { session.stats }

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Status") { status }
                LabeledContent("Video", value: stats.video ?? "Waiting for the host…")
                LabeledContent("Video frames", value: stats.videoFrames.formatted())
                LabeledContent("Audio packets", value: stats.audioPackets.formatted())
                LabeledContent("Rate", value: rates)
            }
            Section("Stages") {
                ForEach(stats.stages) { stage in
                    switch stage.status {
                    case .running: Label(stage.name, systemImage: "circle.dotted")
                    case .done: Label(stage.name, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed(let code): Label("\(stage.name) (error \(code))", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    }
                }
            }
            Section("Log, newest first") {
                ForEach(Array(stats.log.suffix(60).enumerated().reversed()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        .navigationTitle(target.title)
        .task { await run() }
        .onDisappear { session.stop() }
        .onGamepad { command in
            if command == .back { dismiss() }
        }
    }

    @ViewBuilder private var status: some View {
        switch stats.state {
        case .connecting: Text("Connecting…").foregroundStyle(.secondary)
        case .connected: Text("\(Image(systemName: "circle.fill")) Connected").foregroundStyle(.green)
        case .failed(let message): Text(message).foregroundStyle(.red)
        case .ended(let message): Text(message).foregroundStyle(.orange)
        }
    }

    private func run() async {
        session.start(host: client, launch: target.launch, width: target.width, height: target.height, fps: target.fps)
        var previous = (frames: 0, bytes: 0, time: ContinuousClock.now)
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            session.refresh()
            let now = ContinuousClock.now
            let seconds = (now - previous.time) / .seconds(1)
            let fps = Double(stats.videoFrames - previous.frames) / seconds
            let mbps = Double(stats.videoBytes - previous.bytes) * 8 / seconds / 1_000_000
            rates = "\(fps.formatted(.number.precision(.fractionLength(0)))) fps, \(mbps.formatted(.number.precision(.fractionLength(1)))) Mbps"
            previous = (stats.videoFrames, stats.videoBytes, now)
        }
    }
}
