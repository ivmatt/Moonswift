import SwiftUI

/// Stream settings, used from the next Launch or Resume. Touch uses the native controls; a controller moves
/// between rows with up/down, changes the focused row with left/right (A also steps it forward) and closes with B.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(GamepadInput.self) private var gamepad
    @AppStorage(SettingsKey.resolution) private var resolution = ResolutionOption.fullScreen
    @AppStorage(SettingsKey.fps) private var fps = 60
    @AppStorage(SettingsKey.codec) private var codec = CodecOption.automatic
    @AppStorage(SettingsKey.bitrate) private var bitrate = 0 // kbps; 0 = automatic, unlimitedBitrate = unlimited
    @State private var focus = 0

    private enum Row { case resolution, fps, codec, bitrateMode, bitrate }
    private enum BitrateMode: String, CaseIterable { case automatic = "Automatic", custom = "Custom", unlimited = "Unlimited" }
    private var bitrateMode: BitrateMode {
        bitrate == 0 ? .automatic : bitrate == StreamSettings.unlimitedBitrate ? .unlimited : .custom
    }
    private var rows: [Row] { [.resolution, .fps, .codec, .bitrateMode] + (bitrateMode == .custom ? [.bitrate] : []) }

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
                    row(.bitrateMode) {
                        Picker("Bitrate", selection: Binding(get: { bitrateMode }, set: { setMode($0) })) {
                            ForEach(BitrateMode.allCases, id: \.self) { Text($0.rawValue) }
                        }
                    }
                    if bitrateMode == .custom {
                        row(.bitrate) {
                            VStack(alignment: .leading) {
                                Text("\(bitrate / 1000) Mbps")
                                Slider(value: Binding(get: { StreamSettings.sliderPosition(kbps: bitrate) },
                                                      set: { bitrate = StreamSettings.kbps(sliderPosition: $0) }))
                            }
                        }
                    }
                } header: {
                    Text("Bitrate")
                } footer: {
                    switch bitrateMode {
                    case .automatic: Text("\(automaticBitrate / 1000) Mbps for this resolution and frame rate.")
                    case .custom: Text("Higher looks sharper but needs a faster network.")
                    case .unlimited: Text("As high as the PC allows: its Maximum Bitrate setting in Vibepollo is the limit.")
                    }
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

    /// Custom starts from the automatic value, so switching to it doesn't jump somewhere unexpected.
    private func setMode(_ mode: BitrateMode) {
        switch mode {
        case .automatic: bitrate = 0
        case .custom: if bitrateMode != .custom { bitrate = automaticBitrate }
        case .unlimited: bitrate = StreamSettings.unlimitedBitrate
        }
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
        case .bitrateMode: setMode(stepped(bitrateMode, in: BitrateMode.allCases))
        case .bitrate: bitrate = StreamSettings.steppedBitrate(bitrate, by: step)
        }
    }
}
