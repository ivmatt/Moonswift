import Foundation
import MoonlightCore
import Synchronization

/// What the stream screen shows. moonlight-common-c's threads write it; the UI reads a copy.
nonisolated struct StreamStats: Sendable {
    enum State: Equatable, Sendable {
        case connecting, connected
        case failed(String)
        case ended(String)
    }

    struct Stage: Identifiable, Sendable {
        enum Status: Sendable { case running, done, failed(code: Int32) }
        let id: Int32
        let name: String
        var status: Status
    }

    var state = State.connecting
    var stages: [Stage] = []
    var video: String? // e.g. "H.264 2752×2064 @ 60"
    var videoFrames = 0
    var videoBytes = 0
    var audioPackets = 0
    var log: [String] = []

    mutating func append(_ line: String) {
        log.append(line)
        if log.count > 300 { log.removeFirst(log.count - 300) } // keep the screen and memory bounded
    }
}

/// The library supports one connection at a time and its C callbacks carry no context pointer, so the
/// session's state lives in one global, guarded by a mutex because callbacks run on the library's threads.
nonisolated private let current = Mutex(StreamStats())

/// One streaming connection: starts moonlight-common-c after a successful /launch or /resume.
@Observable final class StreamSession {
    private(set) var stats = StreamStats()

    /// Its result keeps the C strings alive for as long as the library may read them.
    @ObservationIgnored private var startTask: Task<(result: Int32, strings: CStrings?), Never>?

    /// Connects in the background. Video frames and audio packets are only counted for now.
    func start(host: HostClient, launch: LaunchSession, width: Int, height: Int, fps: Int) {
        guard startTask == nil else { return }
        current.withLock { $0 = StreamStats() }
        let host = host
        startTask = Task.detached {
            let info: ServerInfo
            do {
                info = try await host.serverInfo()
            } catch {
                current.withLock { $0.state = .failed("Couldn't read the host's info: \(error.localizedDescription)") }
                return (-1, nil)
            }
            let strings = CStrings(address: hostAddress(host.address), appVersion: info.appVersion,
                                   gfeVersion: info.gfeVersion, rtspURL: launch.rtspURL)
            let result = Self.connect(strings: strings, codecModeSupport: info.codecModeSupport, launch: launch,
                                      width: width, height: height, fps: fps)
            return (result, strings)
        }
    }

    /// Copies what the library's threads wrote, for the UI to show.
    func refresh() {
        stats = current.withLock { $0 }
    }

    /// Disconnects; the game keeps running on the host, like Moonlight's "disconnect".
    func stop() {
        guard let startTask else { return }
        self.startTask = nil
        Task.detached {
            LiInterruptConnection() // in case LiStartConnection is still in progress
            let started = await startTask.value
            if started.result == 0 { LiStopConnection() } // blocks while the library's threads shut down
            withExtendedLifetime(started.strings) {} // freed only now that the library has stopped
            current.withLock { if $0.state == .connected || $0.state == .connecting { $0.state = .ended("Disconnected") } }
        }
    }

    /// Blocks until the stream is up or has failed, like LiStartConnection itself. Returns its result (0 = success).
    private nonisolated static func connect(strings: CStrings, codecModeSupport: Int, launch: LaunchSession,
                                            width: Int, height: Int, fps: Int) -> Int32 {
        var server = SERVER_INFORMATION()
        LiInitializeServerInformation(&server)
        server.address = UnsafePointer(strings.address)
        server.serverInfoAppVersion = UnsafePointer(strings.appVersion)
        server.serverInfoGfeVersion = strings.gfeVersion.map { UnsafePointer($0) }
        server.rtspSessionUrl = strings.rtspURL.map { UnsafePointer($0) }
        server.serverCodecModeSupport = Int32(codecModeSupport)

        var config = makeStreamConfiguration(launch: launch, width: width, height: height, fps: fps)

        var listener = CONNECTION_LISTENER_CALLBACKS()
        LiInitializeConnectionCallbacks(&listener) // unset callbacks become no-ops inside the library
        listener.stageStarting = { stage in
            let name = String(cString: LiGetStageName(stage))
            current.withLock {
                $0.stages.append(.init(id: stage, name: name, status: .running))
                $0.append("Starting \(name)")
            }
        }
        listener.stageComplete = { stage in
            current.withLock {
                if let index = $0.stages.lastIndex(where: { $0.id == stage }) { $0.stages[index].status = .done }
            }
        }
        listener.stageFailed = { stage, code in
            let name = String(cString: LiGetStageName(stage))
            current.withLock {
                if let index = $0.stages.lastIndex(where: { $0.id == stage }) { $0.stages[index].status = .failed(code: code) }
                $0.state = .failed("\(name) failed (error \(code))")
            }
        }
        listener.connectionStarted = {
            current.withLock { $0.state = .connected; $0.append("Connection started") }
        }
        listener.connectionTerminated = { code in
            current.withLock { $0.state = .ended(code == 0 ? "The host ended the stream" : "Connection lost (error \(code))") }
        }
        MCInstallLogSink(&listener) { message in
            guard let message else { return }
            let line = String(cString: message).trimmingCharacters(in: .newlines)
            current.withLock { $0.append(line) }
        }

        var video = DECODER_RENDERER_CALLBACKS()
        LiInitializeVideoCallbacks(&video)
        video.setup = { format, width, height, fps, _, _ in
            current.withLock { $0.video = "\(videoFormatName(format)) \(width)×\(height) @ \(fps)" }
            return 0
        }
        video.submitDecodeUnit = { unit in
            let bytes = Int(unit?.pointee.fullLength ?? 0)
            current.withLock { $0.videoFrames += 1; $0.videoBytes += bytes }
            return DR_OK // shortcut: frames are counted, not decoded, until the video stage
        }

        var audio = AUDIO_RENDERER_CALLBACKS()
        LiInitializeAudioCallbacks(&audio)
        audio.`init` = { _, _, _, _ in 0 }
        audio.decodeAndPlaySample = { _, _ in
            current.withLock { $0.audioPackets += 1 } // shortcut: counted, not played, until the audio stage
        }

        return LiStartConnection(&server, &config, &listener, &video, &audio, nil, 0, nil, 0)
    }

    /// The stream settings, mirroring moonlight-ios's Connection.m.
    nonisolated static func makeStreamConfiguration(launch: LaunchSession, width: Int, height: Int, fps: Int) -> STREAM_CONFIGURATION {
        var config = STREAM_CONFIGURATION()
        LiInitializeStreamConfiguration(&config)
        config.width = Int32(width)
        config.height = Int32(height)
        config.fps = Int32(fps)
        config.bitrate = 20_000 // kbps; shortcut: fixed until there's a settings screen
        config.packetSize = 1392
        config.streamingRemotely = STREAM_CFG_AUTO // the library decides from the host's address
        config.audioConfiguration = stereoAudioConfiguration
        config.supportedVideoFormats = VIDEO_FORMAT_H264
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

nonisolated private func videoFormatName(_ format: Int32) -> String {
    switch format {
    case VIDEO_FORMAT_H264: "H.264"
    default: String(format: "format 0x%X", format)
    }
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
