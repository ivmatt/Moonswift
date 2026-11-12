import SwiftUI

/// Stream settings, used from the next Launch or Resume. Touch uses the native controls; a controller moves
/// between rows with up/down, changes the focused row with left/right (A also steps it forward) and closes with B.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(GamepadInput.self) private var gamepad
    @AppStorage(SettingsKey.resolution) private var resolution = ResolutionOption.fullScreen
    @AppStorage(SettingsKey.fps) private var fps = 60
    @AppStorage(SettingsKey.codec) private var codec = CodecOption.automatic
    @AppStorage(SettingsKey.bitrate) private var bitrate = 0 // kbps; 0 = automatic
    @State private var focus = 0

    private enum Row { case resolution, fps, codec, automaticBitrate, bitrate }
    private var rows: [Row] { [.resolution, .fps, .codec, .automaticBitrate] + (bitrate == 0 ? [] : [.bitrate]) }

    private let frameRates = StreamSettings.frameRates(screenMaximum: ScreenInfo.maximumFramesPerSecond)
    private let codecs: [CodecOption] = ScreenInfo.hevcInHardware ? CodecOption.allCases : [.automatic, .h264]
    private var size: (width: Int, height: Int) {
        StreamSettings.size(for: resolution, nativePixels: ScreenInfo.nativePixels, safeAreaPixels: ScreenInfo.safeAreaPixels)
    }
    private var automaticBitrate: Int { StreamSettings.bitrate(width: size.width, height: size.height, fps: fps) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(.resolution) {
                        Picker("Resolution", selection: $resolution) {
                            ForEach(ResolutionOption.allCases, id: \.self) { Text($0.title) }
                        }
                    }
                    row(.fps) {
                        Picker("Frame Rate", selection: $fps) {
                            ForEach(frameRates, id: \.self) { Text("\($0) fps") }
                        }
                    }
                    row(.codec) {
                        Picker("Codec", selection: $codec) {
                            ForEach(codecs, id: \.self) { Text($0.title) }
                        }
                    }
                } header: {
                    Text("Video")
                } footer: {
                    Text("\(size.width)×\(size.height) at \(fps) fps"
                         + (codec == .automatic ? ", \(ScreenInfo.hevcInHardware ? "HEVC" : "H.264") on this device." : "."))
                }
                Section {
                    row(.automaticBitrate) {
                        Toggle("Automatic Bitrate", isOn: Binding(
                            get: { bitrate == 0 },
                            set: { bitrate = $0 ? 0 : automaticBitrate }))
                    }
                    if bitrate != 0 {
                        row(.bitrate) {
                            VStack(alignment: .leading) {
                                Text("\(bitrate / 1000) Mbps")
                                Slider(value: Binding(get: { Double(bitrate) }, set: { bitrate = Int($0) }),
                                       in: Double(StreamSettings.bitrateRange.lowerBound)...Double(StreamSettings.bitrateRange.upperBound),
                                       step: 1000)
                            }
                        }
                    }
                } header: {
                    Text("Bitrate")
                } footer: {
                    Text(bitrate == 0 ? "\(automaticBitrate / 1000) Mbps for this resolution and frame rate."
                                      : "Higher looks sharper but needs a faster network.")
                }
                Section {
                    Text("Changes apply the next time you launch or resume a game.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear {
                // A saved choice the device can't do (for example 120 fps restored on a 60 Hz screen) falls back.
                if !frameRates.contains(fps) { fps = 60 }
                if !codecs.contains(codec) { codec = .automatic }
            }
            .onGamepad { command in
                let current = rows[min(focus, rows.count - 1)]
                switch command {
                case .up, .down: focus = FocusMove.next(focus, count: rows.count, columns: 1, command)
                case .left: change(current, by: -1)
                case .right, .select: change(current, by: 1)
                case .back: dismiss()
                case .menu, .streamMenu: break
                }
            }
        }
    }

    private func row(_ row: Row, @ViewBuilder content: () -> some View) -> some View {
        let isFocused = gamepad.isActive && rows.firstIndex(of: row) == min(focus, rows.count - 1)
        return content()
            .listRowBackground(isFocused ? Color.accentColor.opacity(0.25) : Color(.secondarySystemGroupedBackground))
            .animation(.snappy(duration: 0.15), value: isFocused)
    }

    /// Steps a setting to its previous (-1) or next (+1) value, stopping at the ends.
    private func change(_ row: Row, by step: Int) {
        func stepped<T: Equatable>(_ value: T, in options: [T]) -> T {
            let index = options.firstIndex(of: value) ?? 0
            return options[min(max(index + step, 0), options.count - 1)]
        }
        switch row {
        case .resolution: resolution = stepped(resolution, in: ResolutionOption.allCases)
        case .fps: fps = stepped(fps, in: frameRates)
        case .codec: codec = stepped(codec, in: codecs)
        case .automaticBitrate: bitrate = bitrate == 0 ? automaticBitrate : 0
        case .bitrate:
            bitrate = min(max(bitrate + step * 1000, StreamSettings.bitrateRange.lowerBound), StreamSettings.bitrateRange.upperBound)
        }
    }
}
