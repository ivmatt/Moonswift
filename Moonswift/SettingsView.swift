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
    /// As a tab: L1/R1 move to the neighbouring tab.
    var switchTab: ((Int) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented
    @State private var topInset: CGFloat = 0
    private var isTab: Bool { !isPresented && live == nil }
    @Environment(GamepadInput.self) private var gamepad
    @AppStorage(SettingsKey.resolution) private var resolution = ResolutionOption.fullScreen
    @AppStorage(SettingsKey.fps) private var fps = 60
    @AppStorage(SettingsKey.codec) private var codec = CodecOption.automatic
    @AppStorage(SettingsKey.coverShape) private var coverShape = CoverShape.tall
    @AppStorage(SettingsKey.bitrate) private var bitrate = 0 // kbps; 0 = automatic
    @AppStorage(SettingsKey.adaptiveBitrate) private var adaptive = false
    @AppStorage(SettingsKey.performanceOverlay) private var showsPerformance = false
    @AppStorage(SettingsKey.playAudioOnPC) private var playAudioOnPC = false
    @AppStorage(SettingsKey.hdr) private var hdr = false
    @State private var focus = 0
    @State private var liveBitrateNote: String?
    @State private var bitrateChange: Task<Void, Never>?
    @State private var isShowingAbout = false
    @State private var isShowingButtonMapping = false

    private enum Row { case reconnect, resolution, fps, codec, hdr, bitrateMode, bitrate, adaptive, overlay, pcAudio, buttonMapping, coverShape, about }
    private enum BitrateMode: String, CaseIterable { case automatic = "Automatic", custom = "Custom" }
    private var bitrateMode: BitrateMode {
        bitrate == 0 ? .automatic : .custom
    }
    private var rows: [Row] {
        (needsReconnect ? [.reconnect] : []) + [.resolution, .fps, .codec] + (showsHDR ? [.hdr] : []) + [.bitrateMode] + (bitrateMode == .custom ? [.bitrate] : []) + [.adaptive, .overlay, .pcAudio, .buttonMapping, .coverShape, .about]
    }
    private var videoFormats: Int32 {
        StreamSettings.videoFormats(for: codec, hevcInHardware: ScreenInfo.hevcInHardware, av1InHardware: ScreenInfo.av1InHardware,
                                    hdr: showsHDR && hdr)
    }
    /// HDR needs an HDR screen and HEVC, so it's hidden on other devices and when H.264 is chosen.
    private var showsHDR: Bool { ScreenInfo.supportsHDR && codec != .h264 }
    private var effectiveBitrate: Int { StreamSettings.effectiveBitrate(saved: bitrate, width: size.width, height: size.height, fps: fps) }
    private var needsReconnect: Bool {
        guard let target = live?.target else { return false }
        return StreamSettings.needsReconnect(running: (target.width, target.height, target.fps, target.videoFormats),
                                             wanted: (size.width, size.height, fps, videoFormats))
    }

    private let frameRates = StreamSettings.frameRates(screenMaximum: ScreenInfo.maximumFramesPerSecond)
    private let codecs: [CodecOption] = [.automatic, .h264] + (ScreenInfo.hevcInHardware ? [.hevc] : [])
        + (ScreenInfo.av1InHardware ? [.av1] : [])
    private var size: (width: Int, height: Int) {
        StreamSettings.size(for: resolution, nativePixels: ScreenInfo.nativePixels, safeAreaPixels: ScreenInfo.safeAreaPixels)
    }
    private var automaticBitrate: Int { StreamSettings.bitrate(width: size.width, height: size.height, fps: fps) }

    #if DEBUG
    @AppStorage(GamepadInput.debugControllerKey) private var debugController = ""
    @AppStorage(PCDirectory.debugOfflineKey) private var debugOffline = false
    @Environment(PCDirectory.self) private var directory
    #endif

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
                    if showsHDR {
                        row(.hdr) { Toggle("HDR", isOn: $hdr) }
                    }
                } header: {
                    Text("Video")
                } footer: {
                    Text("\(size.width)×\(size.height) at \(fps) fps"
                         + (codec == .automatic ? ", \(ScreenInfo.hevcInHardware ? "HEVC" : "H.264") on this device."
                            : codec == .av1 ? ". If the PC's graphics card can't encode AV1, it uses HEVC." : ".")
                         + (showsHDR && hdr ? " HDR streams in 10-bit when HDR is on in the PC's display settings." : ""))
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
                    row(.buttonMapping) {
                        Button("Button Mapping") { isShowingButtonMapping = true }.foregroundStyle(.primary)
                    }
                } header: {
                    Text("Controller")
                }
                if live == nil { // not while streaming
                    Section {
                        row(.coverShape) {
                            Picker("Cover Shape", selection: $coverShape) {
                                ForEach(CoverShape.allCases, id: \.self) { Text($0.rawValue) }
                            }
                        }
                    } header: {
                        Text("Library")
                    } footer: {
                        Text("The shape of game covers, to suit your art: 2:3 for Steam's, 3:4 for most PCs', or square.")
                    }
                }
                Section {
                    row(.about) { Button("About Moonswift") { isShowingAbout = true }.foregroundStyle(.primary) }
                }
                #if DEBUG
                if live == nil {
                    Section {
                        Picker("Controller", selection: $debugController) {
                            Text("Automatic").tag("")
                            Text("Connected").tag("YES")
                            Text("Disconnected").tag("NO")
                        }
                        Toggle("PCs Offline", isOn: $debugOffline)
                            .onChange(of: debugOffline) { if DemoMode.isOn { directory.setDemo(pcID: DemoMode.pcID, running: 1) } }
                    } header: {
                        Text("Developer")
                    } footer: {
                        Text("Debug builds only. Acts as if a controller were connected or not, and as if every PC were offline, whatever is, to check layouts on the simulator.")
                    }
                }
                #endif
                Section {
                    if live != nil {
                        Text(liveBitrateNote ?? "Bitrate changes apply to this stream right away.").foregroundStyle(.secondary)
                    } else {
                        Text("Changes apply the next time you launch or resume a game.").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(live == nil ? "Settings" : "Stream Settings")
            // As a tab, the title is TabTitle, placed like Home's; as a sheet (from a stream) it keeps its bar and Done.
            .toolbar(isTab ? .hidden : .automatic, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { // as a tab: the title, fixed and placed like every tab's
                if isTab {
                    TabTitle(text: "Settings", topInset: topInset).padding(.horizontal, 36).padding(.bottom, 4).background(Color(.systemGroupedBackground)) // the list's grey
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
            .navigationDestination(isPresented: $isShowingAbout) { AboutView() }
            .navigationDestination(isPresented: $isShowingButtonMapping) { ButtonMappingView() }
            .onChange(of: effectiveBitrate) { _, kbps in applyLive(kbps) }
            .toolbar {
                if isPresented { // a sheet (from a stream); as a tab there's nothing to close
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
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
                case .select where current == .buttonMapping: isShowingButtonMapping = true
                case .select where current == .reconnect:
                    dismiss()
                    live?.reconnect()
                case .left: change(current, by: -1)
                case .right, .select: change(current, by: 1)
                case .back: dismiss()
                case .previousTab: switchTab?(-1)
                case .nextTab: switchTab?(1)
                case .menu, .alternate, .streamMenu, .settings, .options: break
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
        case .hdr: hdr.toggle()
        case .coverShape: coverShape = stepped(coverShape, in: CoverShape.allCases)
        case .reconnect, .about, .buttonMapping: break
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
