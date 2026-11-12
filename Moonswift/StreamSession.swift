import Foundation
import MoonlightCore
import Synchronization
import VideoToolbox

/// What the stream screen shows. moonlight-common-c's threads write it; the UI reads a copy.
nonisolated struct StreamStats: Sendable {
    enum State: Equatable, Sendable {
        case connecting, connected
        case failed(String)
        case ended(String)
    }

    var state = State.connecting
    var video: String? // e.g. "HEVC 2752×2064 @ 60"
    var videoFormat: Int32 = 0
    var fps = 60
    var videoFrames = 0
    var videoBytes = 0
    /// For adaptive bitrate: frames lost on the network (frame-number gaps) and the library's connection verdict.
    var lostFrames = 0
    var lastFrameNumber = 0
    var isPoor = false
    /// For the performance overlay: per-frame timings, summed (divide by `timedFrames`).
    var timedFrames = 0
    var hostLatencyTenthsMs = 0 // the PC's capture + encode time, when it reports it
    var hostLatencyFrames = 0
    var receiveMicroseconds = 0 // first to last packet of a frame
    var queueMicroseconds = 0 // fully received to handed to the decoder
    var log: [String] = []

    mutating func append(_ line: String) {
        log.append(line)
        if log.count > 300 { log.removeFirst(log.count - 300) } // bounded memory
    }
}

/// The library supports one connection at a time and its C callbacks carry no context pointer, so the
/// session's state lives in globals. The stats are guarded by a mutex because callbacks run on the library's threads.
nonisolated let liveStats = Mutex(StreamStats())
/// Set while a stream screen is up; the library's video callbacks reach it on the main thread.
var activeVideoRenderer: VideoRenderer?
/// Set while controllers are being streamed; receives the host's rumble, motion and light requests.
var activeControllers: ControllerStreamer?
nonisolated private let audioRenderer = AudioRenderer()

/// One streaming connection: starts moonlight-common-c after a successful /launch or /resume.
@Observable final class StreamSession {
    private(set) var stats = StreamStats()

    /// Its result keeps the C strings alive for as long as the library may read them.
    @ObservationIgnored private var startTask: Task<(result: Int32, strings: CStrings?), Never>?

    /// Connects in the background; video goes to `renderer`, audio to the speaker.
    func start(host: HostClient, target: StreamTarget, renderer: VideoRenderer) {
        guard startTask == nil else { return }
        liveStats.withLock { $0 = StreamStats() }
        activeVideoRenderer = renderer
        let launch = target.launch, width = target.width, height = target.height, fps = target.fps, bitrate = target.bitrate
        let videoFormats = target.videoFormats
        startTask = Task.detached {
            let info: ServerInfo
            do {
                info = try await host.serverInfo()
            } catch {
                liveStats.withLock { $0.state = .failed(error.localizedDescription) }
                return (-1, nil)
            }
            let strings = CStrings(address: hostAddress(host.address), appVersion: info.appVersion,
                                   gfeVersion: info.gfeVersion, rtspURL: launch.rtspURL)
            var config = Self.makeStreamConfiguration(launch: launch, width: width, height: height, fps: fps, bitrate: bitrate,
                                                      videoFormats: videoFormats)
            let result = Self.connect(strings: strings, codecModeSupport: info.codecModeSupport, config: &config)
            return (result, strings)
        }
    }

    /// Copies what the library's threads wrote, for the UI to show.
    func refresh() {
        stats = liveStats.withLock { $0 }
    }

    /// Disconnects; the game keeps running on the host, like Moonlight's "disconnect".
    func stop() async {
        guard let startTask else { return }
        self.startTask = nil
        await Task.detached {
            LiInterruptConnection() // in case LiStartConnection is still in progress
            let started = await startTask.value
            if started.result == 0 { LiStopConnection() } // blocks while the library's threads shut down
            withExtendedLifetime(started.strings) {} // freed only now that the library has stopped
            liveStats.withLock { if $0.state == .connected || $0.state == .connecting { $0.state = .ended("Disconnected") } }
        }.value
        activeVideoRenderer = nil
    }

    /// Blocks until the stream is up or has failed, like LiStartConnection itself. Returns its result (0 = success).
    private nonisolated static func connect(strings: CStrings, codecModeSupport: Int, config: inout STREAM_CONFIGURATION) -> Int32 {
        var server = SERVER_INFORMATION()
        LiInitializeServerInformation(&server)
        server.address = UnsafePointer(strings.address)
        server.serverInfoAppVersion = UnsafePointer(strings.appVersion)
        server.serverInfoGfeVersion = strings.gfeVersion.map { UnsafePointer($0) }
        server.rtspSessionUrl = strings.rtspURL.map { UnsafePointer($0) }
        server.serverCodecModeSupport = Int32(codecModeSupport)

        var listener = CONNECTION_LISTENER_CALLBACKS()
        LiInitializeConnectionCallbacks(&listener) // unset callbacks become no-ops inside the library
        listener.stageStarting = { stage in
            let name = String(cString: LiGetStageName(stage))
            liveStats.withLock { $0.append("Starting \(name)") }
        }
        listener.stageFailed = { stage, code in
            let name = String(cString: LiGetStageName(stage))
            reportFailure(StreamStats.State.failed, "Couldn't connect to the PC: \(name) didn't finish (error \(code)).",
                          ports: LiGetPortFlagsFromStage(stage))
        }
        listener.connectionStarted = {
            liveStats.withLock { $0.state = .connected; $0.append("Connection started") }
        }
        listener.connectionStatusUpdate = { status in
            liveStats.withLock { $0.isPoor = status == CONN_STATUS_POOR }
        }
        listener.connectionTerminated = { code in
            reportFailure(StreamStats.State.ended, terminationReason(code), ports: LiGetPortFlagsFromTerminationErrorCode(code))
        }
        // The host's requests for the controllers arrive on the library's threads; apply them on the main thread.
        listener.rumble = { number, low, high in
            DispatchQueue.main.async { MainActor.assumeIsolated { activeControllers?.rumble(controller: Int(number), low: low, high: high) } }
        }
        listener.rumbleTriggers = { number, left, right in
            DispatchQueue.main.async { MainActor.assumeIsolated { activeControllers?.rumbleTriggers(controller: Int(number), left: left, right: right) } }
        }
        listener.setMotionEventState = { number, type, rate in
            DispatchQueue.main.async { MainActor.assumeIsolated { activeControllers?.setMotion(controller: Int(number), type: type, rateHz: Int(rate)) } }
        }
        listener.setControllerLED = { number, red, green, blue in
            DispatchQueue.main.async { MainActor.assumeIsolated { activeControllers?.setLight(controller: Int(number), red: red, green: green, blue: blue) } }
        }
        MCInstallLogSink(&listener) { message in
            guard let message else { return }
            let line = String(cString: message).trimmingCharacters(in: .newlines)
            liveStats.withLock { $0.append(line) }
        }

        var video = DECODER_RENDERER_CALLBACKS()
        LiInitializeVideoCallbacks(&video)
        video.capabilities = CAPABILITY_PULL_RENDERER // the display link pulls frames; no extra decode thread
        video.setup = { format, width, height, fps, _, _ in
            liveStats.withLock {
                $0.video = "\(videoFormatName(format)) \(width)×\(height) @ \(fps)"
                $0.videoFormat = format
                $0.fps = Int(fps)
            }
            return 0
        }
        video.start = {
            let (format, fps) = liveStats.withLock { ($0.videoFormat, $0.fps) }
            DispatchQueue.main.async { MainActor.assumeIsolated { activeVideoRenderer?.start(videoFormat: format, fps: fps) } }
        }
        video.stop = {
            // Synchronously: after this returns the library frees the frame queue the display link polls.
            // Safe from deadlock because LiStopConnection is never called on the main thread (see stop()).
            DispatchQueue.main.sync { MainActor.assumeIsolated { activeVideoRenderer?.stop() } }
        }

        var audio = AUDIO_RENDERER_CALLBACKS()
        LiInitializeAudioCallbacks(&audio)
        audio.capabilities = CAPABILITY_DIRECT_SUBMIT // decoding is cheap; skip the library's extra audio queue
        audio.`init` = { _, opus, _, _ in
            guard let opus = opus?.pointee, opus.streams == 1 else { return -1 } // stereo only for now
            return audioRenderer.start(sampleRate: Int(opus.sampleRate), channels: Int(opus.channelCount),
                                       samplesPerFrame: Int(opus.samplesPerFrame)) ? 0 : -1
        }
        audio.cleanup = { audioRenderer.stop() }
        audio.decodeAndPlaySample = { data, length in
            guard let data else { return }
            audioRenderer.decode(data, length: Int(length))
        }

        return LiStartConnection(&server, &config, &listener, &video, &audio, nil, 0, nil, 0)
    }

    /// The stream settings, mirroring moonlight-ios's Connection.m.
    nonisolated static func makeStreamConfiguration(launch: LaunchSession, width: Int, height: Int, fps: Int,
                                                    bitrate: Int, videoFormats: Int32) -> STREAM_CONFIGURATION {
        var config = STREAM_CONFIGURATION()
        LiInitializeStreamConfiguration(&config)
        config.width = Int32(width)
        config.height = Int32(height)
        config.fps = Int32(fps)
        config.bitrate = Int32(bitrate)
        config.packetSize = 1392
        config.streamingRemotely = STREAM_CFG_AUTO // the library decides from the host's address
        config.audioConfiguration = stereoAudioConfiguration
        config.supportedVideoFormats = videoFormats // from the codec setting (StreamSettings.videoFormats)
        config.encryptionFlags = Int32(bitPattern: 0xFFFF_FFFF) // ENCFLG_ALL: encrypt whatever the host supports
        // The input key is the launch's rikey; the IV is rikeyid, big-endian, in the first 4 bytes.
        withUnsafeMutableBytes(of: &config.remoteInputAesKey) { $0.copyBytes(from: launch.riKey.prefix(16)) }
        withUnsafeMutableBytes(of: &config.remoteInputAesIv) { iv in
            iv.initializeMemory(as: UInt8.self, repeating: 0)
            withUnsafeBytes(of: launch.riKeyID.bigEndian) { iv.copyMemory(from: $0) }
        }
        return config
    }

    /// AUDIO_CONFIGURATION_STEREO, a function-like macro Swift can't import: channel mask 0x3, 2 channels, 0xCA marker.
    nonisolated static let stereoAudioConfiguration: Int32 = (0x3 << 16) | (2 << 8) | 0xCA
}

/// Why a stream ended, in plain words, from the library's ML_ERROR_* code.
nonisolated func terminationReason(_ code: Int32) -> String {
    switch code {
    case ML_ERROR_GRACEFUL_TERMINATION: "The PC ended the stream."
    case ML_ERROR_NO_VIDEO_TRAFFIC: "The PC sent no video. A lower bitrate may help."
    case ML_ERROR_NO_VIDEO_FRAME: "Video arrived but couldn't be shown. A lower bitrate may help."
    case ML_ERROR_UNEXPECTED_EARLY_TERMINATION: "The PC ended the stream unexpectedly. The game may have closed."
    case ML_ERROR_PROTECTED_CONTENT: "The PC can't stream protected content (DRM video)."
    default: "Connection lost (error \(code))."
    }
}

/// Sets the failure message. When the failure involved network ports, tests them against Moonlight's test server
/// (like moonlight-ios) and adds who is blocking them: this network, or the PC's side.
nonisolated private func reportFailure(_ state: @escaping @Sendable (String) -> StreamStats.State, _ message: String, ports: UInt32) {
    guard ports != 0 else { return liveStats.withLock { $0.state = state(message) } }
    let checking = state(message + "\n\nChecking your network…")
    liveStats.withLock { $0.state = checking }
    Task.detached { // the test takes a few seconds; never on the library's thread
        let result = LiTestClientConnectivity("ios.conntest.moonlight-stream.org", 443, ports)
        let advice = portAdvice(ports: ports, testResult: result)
        liveStats.withLock { if $0.state == checking { $0.state = state(advice.map { message + "\n\n" + $0 } ?? message) } }
    }
}

/// What a port test found, in words; nil when it couldn't tell.
nonisolated func portAdvice(ports: UInt32, testResult: UInt32) -> String? {
    guard ports != 0, testResult != ML_TEST_RESULT_INCONCLUSIVE else { return nil }
    if testResult != 0 {
        return "The network this device is on blocks \(portNames(testResult)). Try another network, or turn off a VPN."
    }
    return "This network lets those ports through, so the PC's side is blocking \(portNames(ports)). "
        + "Check the PC's firewall and, away from home, the router's port forwarding."
}

/// e.g. "UDP 47998, UDP 47999".
nonisolated func portNames(_ flags: UInt32) -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    LiStringifyPortFlags(flags, ", ", &buffer, Int32(buffer.count))
    return String(cString: buffer)
}

nonisolated private func videoFormatName(_ format: Int32) -> String {
    if format & VIDEO_FORMAT_MASK_H265 != 0 { return "HEVC" }
    if format & VIDEO_FORMAT_MASK_H264 != 0 { return "H.264" }
    return String(format: "format 0x%X", format)
}

/// C copies of the strings SERVER_INFORMATION points at, freed only after the connection has stopped.
nonisolated final class CStrings: @unchecked Sendable { // immutable after init
    let address: UnsafeMutablePointer<CChar>
    let appVersion: UnsafeMutablePointer<CChar>
    let gfeVersion: UnsafeMutablePointer<CChar>?
    let rtspURL: UnsafeMutablePointer<CChar>?

    init(address: String, appVersion: String, gfeVersion: String?, rtspURL: String?) {
        self.address = strdup(address)
        self.appVersion = strdup(appVersion)
        self.gfeVersion = gfeVersion.map { strdup($0) }
        self.rtspURL = rtspURL.map { strdup($0) }
    }

    deinit {
        for pointer in [address, appVersion, gfeVersion, rtspURL] { free(pointer) }
    }
}
