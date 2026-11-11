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
        startTask = Task.detached {
            let info: ServerInfo
            do {
                info = try await host.serverInfo()
            } catch {
                liveStats.withLock { $0.state = .failed("Couldn't read the host's info: \(error.localizedDescription)") }
                return (-1, nil)
            }
            let strings = CStrings(address: hostAddress(host.address), appVersion: info.appVersion,
                                   gfeVersion: info.gfeVersion, rtspURL: launch.rtspURL)
            var config = Self.makeStreamConfiguration(launch: launch, width: width, height: height, fps: fps, bitrate: bitrate)
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
            liveStats.withLock { $0.state = .failed("\(name) failed (error \(code))") }
        }
        listener.connectionStarted = {
            liveStats.withLock { $0.state = .connected; $0.append("Connection started") }
        }
        listener.connectionTerminated = { code in
            liveStats.withLock { $0.state = .ended(code == 0 ? "The host ended the stream." : "Connection lost (error \(code)).") }
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
                                                    bitrate: Int) -> STREAM_CONFIGURATION {
        var config = STREAM_CONFIGURATION()
        LiInitializeStreamConfiguration(&config)
        config.width = Int32(width)
        config.height = Int32(height)
        config.fps = Int32(fps)
        config.bitrate = Int32(bitrate)
        config.packetSize = 1392
        config.streamingRemotely = STREAM_CFG_AUTO // the library decides from the host's address
        config.audioConfiguration = stereoAudioConfiguration
        // HEVC gives a better picture per bit; only offer it where the device decodes it in hardware.
        config.supportedVideoFormats = VIDEO_FORMAT_H264 | (VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) ? VIDEO_FORMAT_H265 : 0)
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

/// The stream size and bitrate to ask for.
nonisolated enum StreamSettings {
    /// The screen's own pixel size in landscape, so the picture fills it: rounded down to a multiple of 8
    /// (what video encoders work in) and capped at `maxLongSide`, keeping the aspect ratio.
    static func matchScreen(nativePixels: CGSize, maxLongSide: Int = 3840) -> (width: Int, height: Int) {
        var long = Double(max(nativePixels.width, nativePixels.height))
        var short = Double(min(nativePixels.width, nativePixels.height))
        if long > Double(maxLongSide) {
            short *= Double(maxLongSide) / long
            long = Double(maxLongSide)
        }
        return (Int(long) / 8 * 8, Int(short) / 8 * 8)
    }

    /// kbps: 20 Mbps for 1080p60, scaled by pixels per second, kept between 10 and 100 Mbps.
    static func bitrate(width: Int, height: Int, fps: Int) -> Int {
        let scale = Double(width * height * fps) / Double(1920 * 1080 * 60)
        return min(max(Int(20_000 * scale), 10_000), 100_000)
    }
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
