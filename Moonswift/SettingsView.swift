import SwiftUI

/// What Settings can do when opened from inside a running stream.
struct LiveStream {
    let target: StreamTarget
    /// Changes the running stream's bitrate; returns a line to show (what was applied, or why it wasn't).
    let setBitrate: (Int) async -> String
    /// Disconnects and resumes with the current settings (the game keeps running).
    let reconnect: () -> Void
}

/// Settings, a sheet over any tab (its toolbar gear, or the controller's Menu button) or over a stream. Stream
/// settings apply from the next Launch or Resume; opened from a stream (`live`), bitrate applies right away and other
/// changes offer Apply & Reconnect. Touch uses the native controls. A controller moves between rows with up/down; A
/// shows a setting's choices to pick from (or flips a switch, or opens a page), left/right move the bitrate slider,
/// and B or Menu closes.
struct SettingsView: View {
    var live: LiveStream?

    @Environment(\.dismiss) private var dismiss
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
    @AppStorage(SettingsKey.buttonGuide) private var buttonGuide = ButtonGuideMode.automatic
    @State private var focus = 0
    @State private var liveBitrateNote: String?
    @State private var bitrateChange: Task<Void, Never>?
    @State private var isShowingAbout = false
    @State private var isShowingButtonMapping = false
    /// A setting's choices, for the controller, beside its row.
    @State private var choice: ChoiceMenuSpec?
    @State private var rowFrames = RowFrames()

    private enum Row: Hashable { case reconnect, resolution, fps, codec, hdr, bitrateMode, bitrate, adaptive, overlay, pcAudio, buttonMapping, buttonGuide, coverShape, about }
    private enum BitrateMode: String, CaseIterable { case automatic = "Automatic", custom = "Custom" }
    private var bitrateMode: BitrateMode {
        bitrate == 0 ? .automatic : .custom
    }
    /// Must match the on-screen order, or up/down feel inverted.
    private var rows: [Row] {
        (needsReconnect ? [.reconnect] : []) + [.resolution, .fps, .codec] + (showsHDR ? [.hdr] : [])
            + [.bitrateMode] + (bitrateMode == .custom ? [.bitrate] : []) + [.adaptive, .pcAudio, .overlay, .buttonGuide, .buttonMapping]
            + (live == nil ? [.coverShape] : []) + [.about]
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
    @AppStorage(PCDirectory.debugOfflineKey) private var debugOffline = false
    @Environment(PCDirectory.self) private var directory
    #endif

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
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
                        choiceRow(.resolution, "Resolution", $resolution, ResolutionOption.allCases, name: \.title)
                    }
                    row(.fps) {
                        choiceRow(.fps, "Frame Rate", $fps, frameRates) { "\($0) fps" }
                    }
                    row(.codec) {
                        choiceRow(.codec, "Codec", $codec, codecs, name: \.title)
                    }
                    if showsHDR {
                        row(.hdr) { Toggle("HDR", isOn: $hdr) }
                    }
                } header: {
                    Text("Picture")
                } footer: {
                    Text("\(size.width)×\(size.height) at \(fps) fps"
                         + (codec == .automatic ? ", \(ScreenInfo.hevcInHardware ? "HEVC" : "H.264") on this device."
                            : codec == .av1 ? ". If the host's graphics card can't encode AV1, it uses HEVC." : ".")
                         + (showsHDR && hdr ? " HDR streams in 10-bit when HDR is on in the host's display settings." : ""))
                }
                Section {
                    row(.bitrateMode) {
                        choiceRow(.bitrateMode, "Bitrate", Binding(get: { bitrateMode }, set: { setMode($0) }), BitrateMode.allCases, name: \.rawValue)
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
                    Text("Quality")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        switch bitrateMode {
                        case .automatic: Text("\(automaticBitrate / 1000) Mbps for this resolution and frame rate.")
                        case .custom: Text("Higher looks sharper but needs a faster network. The streaming software on your host may also cap it.")
                        }
                        if adaptive {
                            Text("Adaptive lowers the bitrate when the network struggles and raises it back, never above this setting "
                                 + "(and at most 500 Mbps, the usual limit for changes during a stream). It needs a host that supports bitrate changes while streaming.")
                        }
                    }
                }
                Section {
                    row(.pcAudio) {
                        Toggle("Play Sound on Host", isOn: $playAudioOnPC)
                    }
                    row(.overlay) {
                        Toggle("Performance Overlay", isOn: $showsPerformance)
                    }
                } header: {
                    Text("While Streaming")
                } footer: {
                    Text("Sound always plays on this device; Play Sound on Host also plays it from the host's speakers, from the next "
                         + "stream. The overlay shows live frame rate, bitrate, delay and packet loss in a corner of the stream.")
                }
                Section {
                    row(.buttonGuide) {
                        choiceRow(.buttonGuide, "Button Guide", $buttonGuide, ButtonGuideMode.allCases, name: \.rawValue)
                    }
                    row(.buttonMapping) {
                        Button("Button Mapping") { isShowingButtonMapping = true }.foregroundStyle(.primary)
                    }
                } header: {
                    Text("Controller")
                } footer: {
                    Text("The strip of controller buttons along the bottom. Automatic shows it while a controller is connected.")
                }
                if live == nil { // not while streaming
                    Section {
                        row(.coverShape) {
                            choiceRow(.coverShape, "Cover Shape", $coverShape, CoverShape.allCases, name: \.rawValue)
                        }
                    } header: {
                        Text("Library")
                    } footer: {
                        Text("The shape of game covers, to suit your art: 2:3 for Steam's, 3:4 for most hosts', or square.")
                    }
                }
                Section {
                    row(.about) { Button("About Moonswift") { isShowingAbout = true }.foregroundStyle(.primary) }
                }
                #if DEBUG
                if live == nil {
                    Section {
                        Toggle("Hosts Offline", isOn: $debugOffline)
                            .onChange(of: debugOffline) { if DemoMode.isOn { directory.setDemo(pcID: DemoMode.pcID, running: 1) } }
                    } header: {
                        Text("Developer")
                    } footer: {
                        Text("Debug builds only. Acts as if every host were offline, whatever is, to check layouts on the simulator.")
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
            // The focused row stays in view as the controller moves down the list.
            // The focused row in the middle, so its whole section shows, title and notes too (a list won't scroll to a
            // section's notes by themselves); at the top and bottom the list just stops.
            .onChange(of: focus) { if rows.indices.contains(focus) { withAnimation { scroller.scrollTo(rows[focus], anchor: .center) } } }
            }
            .navigationTitle(live == nil ? "Settings" : "Stream Settings")
            .navigationBarTitleDisplayMode(.inline)
            .buttonGuide([([.a], "Select"), ([.b], "Close")], reportsLayout: false)
            .choiceMenu($choice)
            .navigationDestination(isPresented: $isShowingAbout) { AboutView() }
            .navigationDestination(isPresented: $isShowingButtonMapping) { ButtonMappingView() }
            .onChange(of: effectiveBitrate) { _, kbps in applyLive(kbps) }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
                case .select: select(current)
                case .left where current == .bitrate: bitrate = StreamSettings.steppedBitrate(bitrate, by: -1)
                case .right where current == .bitrate: bitrate = StreamSettings.steppedBitrate(bitrate, by: 1)
                case .back, .settings: dismiss() // B, or Menu again: Menu opened it
                case .left, .right, .menu, .alternate, .streamMenu, .options, .previousTab, .nextTab: break
                }
            }
        }
    }

    private func choiceRow<T: Hashable>(_ row: Row, _ title: String, _ selection: Binding<T>, _ options: [T],
                                        name: @escaping (T) -> String) -> some View {
        ChoiceRow(title: title, value: name(selection.wrappedValue), isValueHidden: choice?.source == AnyHashable(row)) {
            Picker(title, selection: selection) { ForEach(options, id: \.self) { Text(name($0)) } }.pickerStyle(.inline)
        }
    }

    private func row(_ row: Row, @ViewBuilder content: () -> some View) -> some View {
        let isFocused = gamepad.isActive && rows.firstIndex(of: row) == min(focus, rows.count - 1)
        return content()
            .recordsFrame(row, in: rowFrames)
            .focusedRowBackground(isFocused)
            .id(row) // outermost: under the row background a list doesn't find it, and the list didn't scroll to the focus
    }

    /// Custom starts from the automatic value, so switching to it doesn't jump somewhere unexpected.
    private func setMode(_ mode: BitrateMode) {
        switch mode {
        case .automatic: bitrate = 0
        case .custom: if bitrateMode != .custom { bitrate = StreamSettings.steppedBitrate(automaticBitrate, by: 0) } // snapped to 10
        }
    }

    /// The controller's A on a row: a setting's choices to pick from, a switch flipped, or a page or button pressed.
    private func select(_ row: Row) {
        func choices<T: Equatable>(_ title: String, _ options: [T], current: T, name: (T) -> String, set: @escaping (T) -> Void) {
            let spec = ChoiceMenuSpec(source: row, options: options.map(name), selected: options.firstIndex(of: current) ?? 0,
                                      anchor: rowFrames.frames[row] ?? .zero) { set(options[$0]) }
            withAnimation(.easeOut(duration: 0.12)) { choice = spec } // the value fades as the menu grows
        }
        switch row {
        case .resolution: choices("Resolution", ResolutionOption.allCases, current: resolution, name: \.title) { resolution = $0 }
        case .fps: choices("Frame Rate", frameRates, current: fps, name: { "\($0) fps" }) { fps = $0 }
        case .codec: choices("Codec", codecs, current: codec, name: \.title) { codec = $0 }
        case .bitrateMode: choices("Bitrate", BitrateMode.allCases, current: bitrateMode, name: \.rawValue) { setMode($0) }
        case .buttonGuide: choices("Button Guide", ButtonGuideMode.allCases, current: buttonGuide, name: \.rawValue) { buttonGuide = $0 }
        case .coverShape: choices("Cover Shape", CoverShape.allCases, current: coverShape, name: \.rawValue) { coverShape = $0 }
        case .hdr: hdr.toggle()
        case .adaptive: adaptive.toggle()
        case .overlay: showsPerformance.toggle()
        case .pcAudio: playAudioOnPC.toggle()
        case .bitrate: break // left/right move the slider
        case .buttonMapping: isShowingButtonMapping = true
        case .about: isShowingAbout = true
        case .reconnect:
            dismiss()
            live?.reconnect()
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
