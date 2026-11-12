import SwiftUI

/// What Settings can do when opened from inside a running stream.
struct LiveStream {
    let target: StreamTarget
    /// Changes the running stream's bitrate; returns a line to show (what was applied, or why it wasn't).
    let setBitrate: (Int) async -> String
    /// Disconnects and resumes with the current settings (the game keeps running).
    let reconnect: () -> Void
}

/// Stream settings, used from the next Launch or Resume. Opened from a stream (`live`), bitrate applies right away
/// and other changes offer Apply & Reconnect. Touch uses the native controls; a controller moves between rows with
/// up/down, changes the focused row with left/right (A also steps it forward, or presses a button) and closes with B.
struct SettingsView: View {
    var live: LiveStream?

    @Environment(\.dismiss) private var dismiss
    @Environment(GamepadInput.self) private var gamepad
    @AppStorage(SettingsKey.resolution) private var resolution = ResolutionOption.fullScreen
    @AppStorage(SettingsKey.fps) private var fps = 60
    @AppStorage(SettingsKey.codec) private var codec = CodecOption.automatic
    @AppStorage(SettingsKey.bitrate) private var bitrate = 0 // kbps; 0 = automatic
    @AppStorage(SettingsKey.adaptiveBitrate) private var adaptive = false
    @AppStorage(SettingsKey.performanceOverlay) private var showsPerformance = false
    @AppStorage(SettingsKey.playAudioOnPC) private var playAudioOnPC = false
    @State private var focus = 0
    @State private var liveBitrateNote: String?
    @State private var bitrateChange: Task<Void, Never>?
    @State private var isShowingAbout = false

    private enum Row { case reconnect, resolution, fps, codec, bitrateMode, bitrate, adaptive, overlay, pcAudio, about }
    private enum BitrateMode: String, CaseIterable { case automatic = "Automatic", custom = "Custom" }
    private var bitrateMode: BitrateMode {
        bitrate == 0 ? .automatic : .custom
    }
    private var rows: [Row] {
        (needsReconnect ? [.reconnect] : []) + [.resolution, .fps, .codec, .bitrateMode] + (bitrateMode == .custom ? [.bitrate] : []) + [.adaptive, .overlay, .pcAudio, .about]
    }
    private var videoFormats: Int32 { StreamSettings.videoFormats(for: codec, hevcInHardware: ScreenInfo.hevcInHardware) }
    private var effectiveBitrate: Int { StreamSettings.effectiveBitrate(saved: bitrate, width: size.width, height: size.height, fps: fps) }
    private var needsReconnect: Bool {
        guard let target = live?.target else { return false }
        return StreamSettings.needsReconnect(running: (target.width, target.height, target.fps, target.videoFormats),
                                             wanted: (size.width, size.height, fps, videoFormats))
    }

    private let frameRates = StreamSettings.frameRates(screenMaximum: ScreenInfo.maximumFramesPerSecond)
    private let codecs: [CodecOption] = ScreenInfo.hevcInHardware ? CodecOption.allCases : [.automatic, .h264]
    private var size: (width: Int, height: Int) {
        StreamSettings.size(for: resolution, nativePixels: ScreenInfo.nativePixels, safeAreaPixels: ScreenInfo.safeAreaPixels)
    }
    private var automaticBitrate: Int { StreamSettings.bitrate(width: size.width, height: size.height, fps: fps) }

    var body: some View {
        NavigationStack {
            List {
                if needsReconnect, let live {
                    Section {
                        row(.reconnect) {
                            Button("Apply & Reconnect") {
                                dismiss()
                                live.reconnect()
                            }
                        }
                    } footer: {
                        Text("Resolution, frame rate and codec are set when a stream starts. Reconnecting takes a few seconds; the game keeps running.")
                    }
                }
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
                    row(.adaptive) {
                        Toggle("Adaptive Bitrate", isOn: $adaptive)
                    }
                } header: {
                    Text("Bitrate")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        switch bitrateMode {
                        case .automatic: Text("\(automaticBitrate / 1000) Mbps for this resolution and frame rate.")
                        case .custom: Text("Higher looks sharper but needs a faster network. The streaming software on your PC may also cap it.")
                        }
                        if adaptive {
                            Text("Adaptive lowers the bitrate when the network struggles and raises it back, never above this setting "
                                 + "(and at most 500 Mbps, the usual limit for changes during a stream). It needs a PC that supports bitrate changes while streaming.")
                        }
                    }
                }
                Section {
                    row(.overlay) {
                        Toggle("Performance Overlay", isOn: $showsPerformance)
                    }
                } footer: {
                    Text("Live frame rate, bitrate, delay and packet loss in a corner of the stream.")
                }
                Section {
                    row(.pcAudio) {
                        Toggle("Play Sound on PC", isOn: $playAudioOnPC)
                    }
                } header: {
                    Text("Audio")
                } footer: {
                    Text("Sound always plays on this device; this also plays it from the PC's speakers. Applies the next time a stream starts.")
                }
                Section {
                    row(.about) { Button("About Moonswift") { isShowingAbout = true }.foregroundStyle(.primary) }
                }
                Section {
                    if live != nil {
                        Text(liveBitrateNote ?? "Bitrate changes apply to this stream right away.").foregroundStyle(.secondary)
                    } else {
                        Text("Changes apply the next time you launch or resume a game.").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(live == nil ? "Settings" : "Stream Settings")
            .navigationDestination(isPresented: $isShowingAbout) { AboutView() }
            .onChange(of: effectiveBitrate) { _, kbps in applyLive(kbps) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear {
                // A saved choice the device can't do (for example 120 fps restored on a 60 Hz screen) falls back.
                if !frameRates.contains(fps) { fps = 60 }
                if !codecs.contains(codec) { codec = .automatic }
                // "Unlimited" from older versions (-1, or above the range) becomes the highest custom setting.
                if bitrate < 0 || bitrate > StreamSettings.bitrateRange.upperBound { bitrate = StreamSettings.bitrateRange.upperBound }
            }
            .onGamepad { command in
                let current = rows[min(focus, rows.count - 1)]
                switch command {
                case .up, .down: focus = FocusMove.next(focus, count: rows.count, columns: 1, command)
                case .select where current == .about: isShowingAbout = true
                case .select where current == .reconnect:
                    dismiss()
                    live?.reconnect()
                case .left: change(current, by: -1)
                case .right, .select: change(current, by: 1)
                case .back: dismiss()
                case .menu, .streamMenu, .settings, .options, .previousTab, .nextTab: break
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
        case .custom: if bitrateMode != .custom { bitrate = StreamSettings.steppedBitrate(automaticBitrate, by: 0) } // snapped to 10
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
        case .adaptive: adaptive.toggle()
        case .overlay: showsPerformance.toggle()
        case .pcAudio: playAudioOnPC.toggle()
        case .reconnect, .about: break
        }
    }

    /// In a stream, sends a new bitrate once the slider or controller has rested for a moment.
    private func applyLive(_ kbps: Int) {
        guard let live else { return }
        bitrateChange?.cancel()
        liveBitrateNote = "Applying…"
        bitrateChange = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            liveBitrateNote = await live.setBitrate(kbps)
        }
    }
}
