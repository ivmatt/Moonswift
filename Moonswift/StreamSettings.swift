import CoreGraphics
import MoonlightCore
import UIKit
import VideoToolbox

/// The stream resolution to ask the host for.
enum ResolutionOption: String, CaseIterable {
    /// The screen's native pixels; the picture may run under the camera cutout.
    case fullScreen
    /// Only the area clear of the camera cutout and home indicator, so nothing is hidden.
    case safeArea
    case p720, p1080, p4k

    var title: String {
        switch self {
        case .fullScreen: "Full Screen"
        case .safeArea: "Safe Area"
        case .p720: "720p"
        case .p1080: "1080p"
        case .p4k: "4K"
        }
    }
}

enum CodecOption: String, CaseIterable {
    /// HEVC where the device decodes it in hardware, otherwise H.264.
    case automatic, h264, hevc

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .h264: "H.264"
        case .hevc: "HEVC"
        }
    }
}

/// Where each setting is saved (UserDefaults, through @AppStorage).
enum SettingsKey {
    static let resolution = "resolution"
    static let fps = "fps"
    static let codec = "codec"
    static let bitrate = "bitrateKbps" // 0 = automatic, StreamSettings.unlimitedBitrate = unlimited
}

/// The stream size, frame rate, codecs and bitrate to ask for. Pure functions, so they can be tested.
nonisolated enum StreamSettings {
    static let bitrateRange = 1_000...1_000_000 // kbps: 1 Mbps to 1 Gbps for the custom slider
    /// "Unlimited": the protocol has no such value, so send the most that safely fits the host's encoder settings
    /// (Vibepollo: kbps × 1000 must fit a 32-bit field). The PC's own Maximum Bitrate setting then decides.
    static let unlimitedBitrate = 2_000_000

    /// Pixel size for a resolution option, landscape. `safeAreaPixels` is the screen minus its cutout and
    /// home-indicator insets, in pixels.
    static func size(for option: ResolutionOption, nativePixels: CGSize, safeAreaPixels: CGSize) -> (width: Int, height: Int) {
        switch option {
        case .fullScreen: matchScreen(nativePixels: nativePixels)
        case .safeArea: matchScreen(nativePixels: safeAreaPixels)
        case .p720: (1280, 720)
        case .p1080: (1920, 1080)
        case .p4k: (3840, 2160)
        }
    }

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

    /// Frame rates the screen can actually show (60 is always offered).
    static func frameRates(screenMaximum: Int) -> [Int] {
        [30, 60, 90, 120].filter { $0 <= max(screenMaximum, 60) }
    }

    /// The library's video format flags for a codec choice.
    static func videoFormats(for codec: CodecOption, hevcInHardware: Bool) -> Int32 {
        switch codec {
        case .automatic: VIDEO_FORMAT_H264 | (hevcInHardware ? VIDEO_FORMAT_H265 : 0)
        case .h264: VIDEO_FORMAT_H264
        case .hevc: VIDEO_FORMAT_H265
        }
    }

    /// kbps: 20 Mbps for 1080p60, scaled by pixels per second, kept between 10 and 100 Mbps.
    static func bitrate(width: Int, height: Int, fps: Int) -> Int {
        let scale = Double(width * height * fps) / Double(1920 * 1080 * 60)
        return min(max(Int(20_000 * scale), 10_000), 100_000)
    }

    /// The saved bitrate (0 = automatic) for this stream.
    static func effectiveBitrate(saved: Int, width: Int, height: Int, fps: Int) -> Int {
        switch saved {
        case 0: bitrate(width: width, height: height, fps: fps)
        case unlimitedBitrate: unlimitedBitrate
        default: min(max(saved, bitrateRange.lowerBound), bitrateRange.upperBound)
        }
    }

    /// The custom slider is logarithmic (0...1 ↔ 1...1000 Mbps), so low bitrates aren't squeezed into a sliver.
    static func sliderPosition(kbps: Int) -> Double {
        log(Double(min(max(kbps, bitrateRange.lowerBound), bitrateRange.upperBound)) / 1000) / log(1000)
    }

    static func kbps(sliderPosition position: Double) -> Int {
        Int((pow(1000, min(max(position, 0), 1))).rounded()) * 1000 // whole Mbps
    }

    /// One controller step on the custom slider: 1 Mbps up to 20, 5 up to 100, then 25.
    static func steppedBitrate(_ kbps: Int, by direction: Int) -> Int {
        let mbps = kbps / 1000
        // Going down, the step is chosen by the value below, so 100 → 95 and 20 → 19 (not 75 and 15).
        let reference = direction > 0 ? mbps : mbps - 1
        let step = reference < 20 ? 1 : reference < 100 ? 5 : 25
        return min(max((mbps + direction * step) * 1000, bitrateRange.lowerBound), bitrateRange.upperBound)
    }
}

/// The current screen's measurements, read when a stream is about to start.
enum ScreenInfo {
    private static var scene: UIWindowScene? { UIApplication.shared.connectedScenes.first as? UIWindowScene }

    static var nativePixels: CGSize { scene?.screen.nativeBounds.size ?? CGSize(width: 1920, height: 1080) }
    static var maximumFramesPerSecond: Int { scene?.screen.maximumFramesPerSecond ?? 60 }
    static var hevcInHardware: Bool { VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) }

    /// The screen minus its insets, in pixels. The cutout's inset is mirrored on both sides in landscape, so
    /// in portrait the long side loses top and bottom, and in landscape left and right.
    // shortcut: uses the current orientation's insets; a stream started in portrait estimates landscape's.
    static var safeAreaPixels: CGSize {
        guard let scene, let window = scene.keyWindow else { return nativePixels }
        let insets = window.safeAreaInsets, scale = scene.screen.nativeScale
        let bounds = window.bounds.size
        let isPortrait = bounds.height > bounds.width
        let long = max(bounds.width, bounds.height) - (isPortrait ? insets.top + insets.bottom : insets.left + insets.right)
        let short = min(bounds.width, bounds.height) - (isPortrait ? insets.left + insets.right : insets.top + insets.bottom)
        return CGSize(width: long * scale, height: short * scale)
    }
}
