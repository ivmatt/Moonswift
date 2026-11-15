import AVFoundation
import Accelerate
import Synchronization

/// Plays the stream's audio: Apple's built-in Opus decoder (AVAudioConverter) turns each packet into PCM, which an
/// AVAudioEngine source node pulls from a small ring buffer. Stereo only: surround needs Opus multistream (libopus).
nonisolated final class AudioRenderer: @unchecked Sendable { // the library calls start/decode/stop one at a time
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var packet: AVAudioCompressedBuffer?
    private var pcm: AVAudioPCMBuffer?
    private var ring: SampleRing?
    private var channels = 2

    /// Sets up decoding and starts the output. Returns false if the format isn't supported.
    func start(sampleRate: Int, channels: Int, samplesPerFrame: Int) -> Bool {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback)
        try? session.setPreferredIOBufferDuration(0.005) // ask for ~5 ms hardware buffers: less delay
        try? session.setActive(true)

        var opusDescription = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(samplesPerFrame), mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &opusDescription),
              let decoded = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
                                          channels: AVAudioChannelCount(channels), interleaved: true),
              let output = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(channels)),
              let converter = AVAudioConverter(from: opus, to: decoded),
              let pcm = AVAudioPCMBuffer(pcmFormat: decoded, frameCapacity: AVAudioFrameCount(samplesPerFrame * 2))
        else { return false }

        // Keep at most 40 ms queued; anything beyond that is old audio that would only add delay.
        let ring = SampleRing(channels: channels, maxFrames: sampleRate * 40 / 1000)
        let engine = AVAudioEngine()
        let source = AVAudioSourceNode(format: output) { _, _, frameCount, bufferList in
            ring.render(frames: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(bufferList))
            return noErr
        }
        engine.attach(source)
        do {
            try engine.connectNode(source, to: engine.mainMixerNode, format: output) // iOS 27: throws instead of crashing
            try engine.start()
        } catch {
            return false
        }

        self.channels = channels
        self.converter = converter
        self.packet = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: 1500)
        self.pcm = pcm
        self.ring = ring
        self.engine = engine
        return true
    }

    /// Decodes one Opus packet (already decrypted by the library) into the ring buffer.
    func decode(_ data: UnsafeRawPointer, length: Int) {
        guard let converter, let packet, let pcm, let ring, length > 0, length <= Int(packet.maximumPacketSize) else { return }
        packet.data.copyMemory(from: data, byteCount: length)
        packet.byteLength = UInt32(length)
        packet.packetCount = 1
        packet.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                         mDataByteSize: UInt32(length))
        pcm.frameLength = 0
        let input = OneShotInput(packet)
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, inputStatus in input.next(inputStatus) }
        guard status != .error, let samples = pcm.floatChannelData?[0] else { return }
        let count = Int(pcm.frameLength) * channels
        ring.write(UnsafeBufferPointer(start: samples, count: count))
        // Louder than near-silence (about -34 dBFS): the game, or something on the host, is making sound.
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))
        if peak > 0.02 {
            let milliseconds = Int(pcm.frameLength) * 1000 / Int(pcm.format.sampleRate)
            liveStats.withLock { $0.loudMilliseconds += milliseconds }
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
        converter = nil
        packet = nil
        pcm = nil
        ring = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Hands the converter one packet, then says there's no more for now.
private nonisolated final class OneShotInput: @unchecked Sendable { // used synchronously inside convert()
    private var packet: AVAudioCompressedBuffer?
    init(_ packet: AVAudioCompressedBuffer) { self.packet = packet }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let packet else {
            status.pointee = .noDataNow
            return nil
        }
        self.packet = nil
        status.pointee = .haveData
        return packet
    }
}

/// Interleaved float samples passed from the decoding thread to the audio render thread.
nonisolated final class SampleRing: Sendable {
    private struct State {
        var buffer: [Float]
        var readIndex = 0
        var count = 0 // samples, not frames
        var scratch: [Float]
    }

    let channels: Int
    let maxFrames: Int
    private let state: Mutex<State>

    init(channels: Int, maxFrames: Int) {
        self.channels = channels
        self.maxFrames = maxFrames
        // Room for twice the limit, plus a render pass of scratch for de-interleaving.
        state = Mutex(State(buffer: Array(repeating: 0, count: maxFrames * channels * 2),
                            scratch: Array(repeating: 0, count: 8192 * channels)))
    }

    var queuedFrames: Int { state.withLock { $0.count / channels } }

    /// Appends whole frames. If more than `maxFrames` are queued, the oldest are dropped down to half that,
    /// so latency can't creep up when the network delivers a burst.
    func write(_ samples: UnsafeBufferPointer<Float>) {
        let channels = channels, maxFrames = maxFrames
        state.withLock { ring in
            let capacity = ring.buffer.count
            for sample in samples {
                if ring.count == capacity { // full: overwrite the oldest frame
                    ring.readIndex = (ring.readIndex + channels) % capacity
                    ring.count -= channels
                }
                ring.buffer[(ring.readIndex + ring.count) % capacity] = sample
                ring.count += 1
            }
            if ring.count > maxFrames * channels {
                let drop = ring.count - (maxFrames / 2) * channels
                ring.readIndex = (ring.readIndex + drop) % capacity
                ring.count -= drop
            }
        }
    }

    /// Takes up to `frames` frames, interleaved, and fills the rest with silence (an underrun).
    func read(frames: Int, into output: UnsafeMutableBufferPointer<Float>) {
        state.withLock { ring in Self.take(&ring, samples: frames * channels, into: output) }
    }

    /// The audio render callback: de-interleaves into the engine's per-channel buffers.
    func render(frames: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        let channels = channels
        state.withLock { ring in
            // Borrow the scratch array out of the state so both can be used at once (swapping doesn't allocate).
            var scratchArray: [Float] = []
            swap(&scratchArray, &ring.scratch)
            defer { swap(&scratchArray, &ring.scratch) }
            let frames = min(frames, scratchArray.count / channels)
            scratchArray.withUnsafeMutableBufferPointer { scratch in
                Self.take(&ring, samples: frames * channels, into: scratch)
                for (channel, buffer) in buffers.enumerated() where channel < channels {
                    guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for frame in 0..<frames { out[frame] = scratch[frame * channels + channel] }
                }
            }
        }
    }

    private static func take(_ ring: inout State, samples wanted: Int, into output: UnsafeMutableBufferPointer<Float>) {
        let capacity = ring.buffer.count
        let available = min(wanted, ring.count, output.count)
        for index in 0..<available { output[index] = ring.buffer[(ring.readIndex + index) % capacity] }
        for index in available..<min(wanted, output.count) { output[index] = 0 }
        ring.readIndex = (ring.readIndex + available) % capacity
        ring.count -= available
    }
}
