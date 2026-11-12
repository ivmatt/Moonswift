import AVFoundation
import MoonlightCore
import QuartzCore
import Synchronization
import UIKit

/// Decodes and shows the stream with VideoToolbox through AVSampleBufferDisplayLayer, like moonlight-ios.
/// A display link pulls one frame per screen refresh from moonlight-common-c (its "pull renderer" model).
final class VideoRenderer: NSObject {
    let layer = AVSampleBufferDisplayLayer()

    private var link: CADisplayLink?
    private var isHEVC = false
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []

    override init() {
        layer.videoGravity = .resizeAspect // fill the screen without stretching; black bars only if the aspect differs
        layer.backgroundColor = UIColor.black.cgColor
    }

    /// Called (on the main thread) when the library starts its video stream.
    func start(videoFormat: Int32, fps: Int) {
        isHEVC = videoFormat & VIDEO_FORMAT_MASK_H265 != 0
        format = nil
        parameterSets = []
        let link = CADisplayLink(target: self, selector: #selector(tick))
        let rate = Float(fps)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Called (on the main thread, from inside LiStopConnection) before the library frees its frame queue.
    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        var handle: VIDEO_FRAME_HANDLE?
        var unit: PDECODE_UNIT?
        while LiPollNextVideoFrame(&handle, &unit) {
            LiCompleteVideoFrame(handle, unit.map(decode) ?? DR_OK)
            // Keep one frame waiting to absorb network jitter (one frame of latency), unless the screen is
            // refreshing slower than the stream (Low Power Mode, heat), where waiting would only add delay.
            let refreshRate = 1 / (link.targetTimestamp - link.timestamp)
            if refreshRate >= Double(link.preferredFrameRateRange.preferred ?? 60) * 0.9, LiGetPendingVideoFrames() == 1 {
                break
            }
        }
    }

    /// One frame: parameter sets (SPS/PPS, plus VPS for HEVC) and picture data, all as Annex-B.
    /// Returns DR_OK, or DR_NEED_IDR to have the host send a fresh keyframe.
    private func decode(_ unit: PDECODE_UNIT) -> Int32 {
        var newParameterSets: [Data] = []
        var picture = Data()
        var entry = unit.pointee.bufferList
        while let current = entry {
            let bytes = Data(bytes: current.pointee.data, count: Int(current.pointee.length))
            if current.pointee.bufferType == BUFFER_TYPE_PICDATA {
                picture.append(bytes)
            } else {
                newParameterSets += AnnexB.nalUnits(bytes)
            }
            entry = current.pointee.next
        }
        let frameNumber = Int(unit.pointee.frameNumber)
        let hostLatency = Int(unit.pointee.frameHostProcessingLatency)
        let receive = Int(unit.pointee.enqueueTimeUs &- unit.pointee.receiveTimeUs)
        let queue = Int(LiGetMicroseconds() &- unit.pointee.enqueueTimeUs)
        liveStats.withLock { stats in
            stats.timedFrames += 1
            stats.receiveMicroseconds += receive
            stats.queueMicroseconds += queue
            if hostLatency > 0 {
                stats.hostLatencyTenthsMs += hostLatency
                stats.hostLatencyFrames += 1
            }
            stats.videoFrames += 1
            stats.videoBytes += Int(unit.pointee.fullLength)
            // A jump in frame numbers means frames the network lost for good (moonlight-ios counts drops the same way).
            if stats.lastFrameNumber > 0, frameNumber > stats.lastFrameNumber + 1 {
                stats.lostFrames += frameNumber - stats.lastFrameNumber - 1
            }
            stats.lastFrameNumber = frameNumber
        }

        if !newParameterSets.isEmpty, newParameterSets != parameterSets {
            guard let format = makeFormat(newParameterSets) else { return DR_NEED_IDR }
            self.format = format
            parameterSets = newParameterSets
        }
        // shortcut: enqueue/status/flush are deprecated in iOS 27 in favor of a render synchronizer's receiver, which
        // presents on a clock. Still work; move over once it's clear the new path keeps "display immediately" latency.
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { // e.g. after the app was in the background
            renderer.flush()
            return DR_NEED_IDR
        }
        guard let format, !picture.isEmpty, let sample = makeSample(AnnexB.lengthPrefixed(picture), format: format) else {
            return DR_NEED_IDR
        }
        renderer.enqueue(sample)
        return DR_OK
    }

    private func makeFormat(_ sets: [Data]) -> CMVideoFormatDescription? {
        let copies = sets.map { set in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: pointer, count: set.count)
            return UnsafePointer(pointer)
        }
        defer { copies.forEach { UnsafeMutablePointer(mutating: $0).deallocate() } }
        let sizes = sets.map(\.count)
        var format: CMFormatDescription?
        let status = isHEVC
            ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: nil, parameterSetCount: sets.count, parameterSetPointers: copies, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            : CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: nil, parameterSetCount: sets.count, parameterSetPointers: copies, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        return status == noErr ? format : nil
    }

    private func makeSample(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: data.count,
                                                 flags: 0, blockBufferOut: &block) == noErr, let block,
              data.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                   offsetIntoDestination: 0, dataLength: data.count) }) == noErr
        else { return nil }

        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample
        else { return nil }
        // No timestamps: show each frame as soon as it's decoded, which is what keeps latency low.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

/// H.264/HEVC "Annex-B" streams separate NAL units with 00 00 01 or 00 00 00 01 start codes. VideoToolbox
/// instead wants each NAL unit prefixed with its length.
nonisolated enum AnnexB {
    /// The NAL units in `data`, without their start codes.
    static func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var codes: [(begin: Int, payload: Int)] = []
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                let begin = index > 0 && bytes[index - 1] == 0 ? index - 1 : index // 4-byte start code
                codes.append((begin, index + 3))
                index += 3
            } else {
                index += 1
            }
        }
        return codes.indices.map { position in
            let end = position + 1 < codes.count ? codes[position + 1].begin : bytes.count
            return Data(bytes[codes[position].payload..<end])
        }
    }

    /// The same NAL units, each prefixed with a 4-byte big-endian length.
    static func lengthPrefixed(_ data: Data) -> Data {
        var output = Data(capacity: data.count + 16)
        for unit in nalUnits(data) {
            withUnsafeBytes(of: UInt32(unit.count).bigEndian) { output.append(contentsOf: $0) }
            output.append(unit)
        }
        return output
    }
}
