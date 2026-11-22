import SwiftUI

/// What Settings can do when opened from inside a running stream.
struct LiveStream {
    let target: StreamTarget
    /// Changes the running stream's bitrate; returns a line to show (what was applied, or why it wasn't).
    let setBitrate: (Int) async -> String
    /// Disconnects and resumes with the current settings (the game keeps running).
    let reconnect: () -> Void
}

/// Settings, a sheet over any tab (its toolbar gear, or the controller's Menu button) or over a stream. Two pages,
/// Stream and Interface, switched at the top (or LB/RB); from a stream only Stream shows. Stream settings apply from the next Launch or Resume; opened from a stream (`live`), bitrate applies right away and other
/// changes offer Apply & Reconnect. Touch uses the native controls. A controller moves between rows with up/down; A
/// shows a setting's choices to pick from (or flips a switch, or opens a page), left/right move the bitrate slider,
/// and B or Menu closes.
struct SettingsView: View {
    var live: LiveStream?

    @Environment(\.dismiss) private var dismiss
    @Environment(GamepadInput.self) private var gamepad
    @AppStorage(SettingsKey.resolution) private var resolution = ResolutionOption.fullScreen
    @AppStorage(SettingsKey.fps) private var fps = ScreenInfo.defaultFPS
    @AppStorage(SettingsKey.codec) private var codec = CodecOption.automatic
    @AppStorage(SettingsKey.coverShape) private var coverShape = CoverShape.tall
    @AppStorage(SettingsKey.onlineArtwork) private var findsArtwork = true
    @AppStorage(SettingsKey.artworkKeyVersion) private var artworkKeyVersion = 0
    /// SteamGridDB's key as typed; saved to the Keychain when the field is left or submitted.
    @State private var artworkKey = SteamGridDB.savedKey ?? ""
    @FocusState private var isKeyFocused: Bool
    @AppStorage(SettingsKey.bitrate) private var bitrate = 0 // kbps; 0 = automatic
    @AppStorage(SettingsKey.adaptiveBitrate) private var adaptive = SettingsKey.adaptiveBitrateDefault
    @AppStorage(SettingsKey.performanceOverlay) private var showsPerformance = false
    @AppStorage(SettingsKey.playAudioOnPC) private var playAudioOnPC = false
    @AppStorage(SettingsKey.touchMode) private var touchMode = TouchMode.automatic
    @AppStorage(SettingsKey.hdr) private var hdr = ScreenInfo.supportsHDR
    @AppStorage(SettingsKey.buttonGuide) private var buttonGuide = ButtonGuideMode.automatic
    @AppStorage(SettingsKey.pictureInPicture) private var allowsPictureInPicture = true
    @AppStorage(SettingsKey.splashScreen) private var showsSplash = true
    @AppStorage(SettingsKey.splashWait) private var splashWait = LaunchSplash.defaultWait
    @AppStorage(SettingsKey.splashEndsOnSound) private var splashEndsOnSound = false
    @AppStorage(SettingsKey.dualSenseHaptics) private var dualSenseHaptics = true
    @AppStorage(SettingsKey.phoneRumble) private var phoneRumble = true
    @AppStorage(SettingsKey.controlCenterSide) private var controlCenterSide = ControlCenterSide.right
    @State private var focus = 0
    @State private var liveBitrateNote: String?
    @State private var bitrateChange: Task<Void, Never>?
    @State private var isShowingAbout = false
    @State private var isShowingButtonMapping = false
    @State private var isShowingGestures = false
    /// A setting's choices, for the controller, beside its row.
    @State private var choice: ChoiceMenuSpec?
    @State private var rowFrames = RowFrames()

    private enum Row: Hashable { case reconnect, resolution, fps, codec, hdr, bitrateMode, bitrate, adaptive, overlay, pcAudio, touch, splash, splashWait, splashSound, pictureInPicture, gestures, controlCenterSide, buttonMapping, dualSenseHaptics, phoneRumble, buttonGuide, coverShape, onlineArtwork, artworkKey, about }
    /// Stream: what a stream is sent with. Interface: how the app looks and works. From a stream, only Stream.
    private enum Page: String, CaseIterable { case stream = "Stream", interface = "Interface" }
    @State private var page = Self.rememberedPage
    /// The page last shown, for a while after Settings closes (Interface needn't be picked again each time).
    private static var rememberedPage: Page {
        let defaults = UserDefaults.standard
        guard let page = defaults.string(forKey: "settingsPage").flatMap(Page.init(rawValue:)),
              Date.now.timeIntervalSince1970 - defaults.double(forKey: "settingsPageAt") < 10 * 60 else { return .stream }
        return page
    }
    private func rememberPage() {
        guard live == nil else { return } // from a stream only Stream shows: that's no choice to remember
        UserDefaults.standard.set(page.rawValue, forKey: "settingsPage")
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: "settingsPageAt")
    }
    private enum BitrateMode: String, CaseIterable { case automatic = "Automatic", custom = "Custom" }
    private var bitrateMode: BitrateMode {
        bitrate == 0 ? .automatic : .custom
    }
    /// Must match the on-screen order, or up/down feel inverted.
    private var rows: [Row] {
        guard page == .stream else { return [.splash] + (showsSplash ? [.splashWait, .splashSound] : []) + [.pictureInPicture, .controlCenterSide, .gestures] + (ButtonGuideMode.isAvailable ? [.buttonGuide] : []) + [.buttonMapping, .dualSenseHaptics] + (PhoneRumble.isAvailable ? [.phoneRumble] : []) + (live == nil ? [.coverShape, .onlineArtwork] + (findsArtwork ? [.artworkKey] : []) : []) + [.about] }
        return (needsReconnect ? [.reconnect] : []) + [.resolution, .fps, .codec] + (showsHDR ? [.hdr] : [])
            + [.bitrateMode] + (bitrateMode == .custom ? [.bitrate] : []) + [.adaptive, .pcAudio, .touch, .overlay]
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

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
            List {
                if page == .stream {
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
                    row(.touch) {
                        choiceRow(.touch, "Touch", $touchMode, TouchMode.allCases, name: \.title)
                    }
                    row(.overlay) {
                        Toggle("Performance Overlay", isOn: $showsPerformance)
                    }
                } header: {
                    Text("While Streaming")
                } footer: {
                    Text("Sound always plays on this device; Play Sound on Host also plays it from the host's speakers, from the next "
                         + "stream. Touch: Automatic is the on-screen controller, or the touchscreen while a real controller is "
                         + "connected; Touchscreen sends your fingers as touches, Trackpad moves the pointer, and Controller "
                         + "puts a game controller on screen (hidden while a real one is connected). The overlay shows live "
                         + "frame rate, bitrate, delay and packet loss in a corner of the stream.")
                }
                Section {} footer: { // a note under the list, not a row that looks tappable
                    if live != nil {
                        Text(liveBitrateNote ?? "Bitrate changes apply to this stream right away.")
                    } else {
                        Text("Changes apply the next time you launch or resume a game.")
                    }
                }
                } else {
                Section {
                    row(.splash) {
                        Toggle("Splash Screen", isOn: $showsSplash)
                    }
                    if showsSplash {
                        row(.splashWait) {
                            choiceRow(.splashWait, "Splash Wait", $splashWait, LaunchSplash.waitChoices, name: Self.seconds)
                        }
                        row(.splashSound) { Toggle("End on Game Sound (Beta)", isOn: $splashEndsOnSound) }
                    }
                } header: {
                    Text("Launching")
                } footer: {
                    Text("Splash Screen shows the game's art from Play until the game is on screen. Splash Wait keeps it up "
                         + "that long past the first picture, so the host's desktop and launchers don't flash by; a game's "
                         + "Edit page can set its own, and resuming skips it. End on Game Sound lifts it as soon as the game "
                         + "makes sound, with Splash Wait the longest it stays; a launcher's or the desktop's sounds can end it early.")
                }
                Section {
                    row(.pictureInPicture) {
                        Toggle("Picture in Picture", isOn: $allowsPictureInPicture)
                    }
                    row(.controlCenterSide) {
                        choiceRow(.controlCenterSide, "Control Center", $controlCenterSide, ControlCenterSide.allCases, name: \.rawValue)
                    }
                    row(.gestures) {
                        Button("Gestures") { isShowingGestures = true }.foregroundStyle(.primary)
                    }
                } header: {
                    Text("While Streaming")
                } footer: {
                    Text("Picture in Picture: leaving the app floats the game in a small window over other apps; off, leaving "
                         + "the app pauses the stream until you come back. Control Center: the side it comes out of; on the left, "
                         + "its swipe goes right. Applies from the next stream.")
                }
                Section {
                    if ButtonGuideMode.isAvailable {
                        row(.buttonGuide) {
                            choiceRow(.buttonGuide, "Button Guide", $buttonGuide, ButtonGuideMode.allCases, name: \.rawValue)
                        }
                    }
                    row(.buttonMapping) {
                        Button("Button Mapping") { isShowingButtonMapping = true }.foregroundStyle(.primary)
                    }
                    row(.dualSenseHaptics) { Toggle("DualSense Haptics", isOn: $dualSenseHaptics) }
                    if PhoneRumble.isAvailable {
                        row(.phoneRumble) { Toggle("Phone Rumble", isOn: $phoneRumble) }
                    }
                } header: {
                    Text("Controller")
                } footer: {
                    Text((ButtonGuideMode.isAvailable ? "Button Guide: the strip of controller buttons along the bottom; "
                          + "Automatic shows it while a controller is connected. " : "")
                         + "DualSense Haptics plays the fine vibration games send a DualSense on hosts that pass it on "
                         + "(Vibepollo); off, those games don't vibrate. Applies from the next stream."
                         + (PhoneRumble.isAvailable ? " Phone Rumble plays game rumble on this phone when the first "
                            + "player's controller has no motor, including the on-screen controller." : ""))
                }
                if live == nil { // not while streaming
                    Section {
                        row(.coverShape) {
                            choiceRow(.coverShape, "Cover Shape", $coverShape, CoverShape.allCases, name: \.rawValue)
                        }
                        row(.onlineArtwork) { Toggle("Online Artwork", isOn: $findsArtwork) }
                        if findsArtwork {
                            row(.artworkKey) {
                                SecureField("SteamGridDB API Key", text: $artworkKey)
                                    .focused($isKeyFocused)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .onSubmit(saveArtworkKey)
                            }
                        }
                    } header: {
                        Text("Library")
                    } footer: {
                        Text("The shape of game covers, to suit your art: 2:3 for Steam's, 3:4 for most hosts', or square. Online "
                             + "Artwork finds covers and hero pictures on SteamGridDB, sending it your games' names; get a free API "
                             + "key from your profile on steamgriddb.com. Pictures you add yourself always show first.")
                    }
                    .onChange(of: isKeyFocused) { if !isKeyFocused { saveArtworkKey() } }
                    .onDisappear(perform: saveArtworkKey)
                }
                Section {
                    row(.about) { Button("About Moonswift") { isShowingAbout = true }.foregroundStyle(.primary) }
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
            .toolbar {
                if live == nil {
                    ToolbarItem(placement: .principal) {
                        Picker("Settings", selection: $page) { ForEach(Page.allCases, id: \.self) { Text($0.rawValue) } }
                            .pickerStyle(.segmented)
                            .frame(width: 260) // room around each word; a segmented picker ignores its labels' padding
                    }
                }
            }
            .onChange(of: page) { focus = 0; rememberPage() }
            .onAppear { if live != nil { page = .stream } }
            .onDisappear(perform: rememberPage) // ten minutes from closing, not from picking
            .buttonGuide(live == nil ? [([.a], "Select"), ([.l1, .r1], "Stream / Interface"), ([.b], "Close")] : [([.a], "Select"), ([.b], "Close")],
                         reportsLayout: false)
            .choiceMenu($choice)
            .navigationDestination(isPresented: $isShowingAbout) { AboutView() }
            .navigationDestination(isPresented: $isShowingButtonMapping) { ButtonMappingView() }
            .navigationDestination(isPresented: $isShowingGestures) { GesturesView() }
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
                case .previousTab where live == nil: page = .stream
                case .nextTab where live == nil: page = .interface
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

    /// A changed key goes to the Keychain, and the library is looked up again with it.
    private func saveArtworkKey() {
        guard artworkKey.trimmingCharacters(in: .whitespacesAndNewlines) != (SteamGridDB.savedKey ?? "") else { return }
        SteamGridDB.save(key: artworkKey)
        artworkKeyVersion += 1
    }

    static func seconds(_ n: Int) -> String { n == 0 ? "None" : "\(n) s" }

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
        case .touch: choices("Touch", TouchMode.allCases, current: touchMode, name: \.title) { touchMode = $0 }
        case .pictureInPicture: allowsPictureInPicture.toggle()
        case .gestures: isShowingGestures = true
        case .controlCenterSide:
            choices("Control Center", ControlCenterSide.allCases, current: controlCenterSide, name: \.rawValue) { controlCenterSide = $0 }
        case .splash: showsSplash.toggle()
        case .splashSound: splashEndsOnSound.toggle()
        case .splashWait: choices("Splash Wait", LaunchSplash.waitChoices, current: splashWait, name: Self.seconds) { splashWait = $0 }
        case .bitrate: break // left/right move the slider
        case .buttonMapping: isShowingButtonMapping = true
        case .dualSenseHaptics: dualSenseHaptics.toggle()
        case .phoneRumble: phoneRumble.toggle()
        case .about: isShowingAbout = true
        case .onlineArtwork: findsArtwork.toggle()
        case .artworkKey: isKeyFocused = true
        case .reconnect:
            dismiss()
            live?.reconnect()
        }
    }

    /// In a stream, sends a new bitrate once the slider or controller has rested for a moment.
    private func applyLive(_ kbps: Int) {
        guard let live else { return }
        bitrateChange = applyLiveBitrate(kbps, replacing: bitrateChange, send: live.setBitrate) { liveBitrateNote = $0 }
    }
}

/// A live bitrate change from a slider (Stream Settings, or the control panel's Quick Settings): "Applying…" at once,
/// then sent once the slider or controller has rested for 600 ms (each move starts the wait again), and what the host
/// said shown instead.
func applyLiveBitrate(_ kbps: Int, replacing pending: Task<Void, Never>?, send: @escaping (Int) async -> String,
                                 note: @escaping (String) -> Void) -> Task<Void, Never> {
    pending?.cancel()
    note("Applying…")
    return Task {
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        note(await send(kbps))
    }
}
