import AVFoundation
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
    /// A typed width and height.
    case custom

    var title: String {
        switch self {
        case .fullScreen: "Full Screen"
        case .safeArea: "Safe Area"
        case .p720: "720p"
        case .p1080: "1080p"
        case .p4k: "4K"
        case .custom: "Custom"
        }
    }
}

enum CodecOption: String, CaseIterable {
    /// Automatic: HEVC where the device decodes it in hardware, otherwise H.264. AV1 is only offered on devices that
    /// decode it in hardware, and isn't part of Automatic.
    case automatic, h264, hevc, av1

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .av1: "AV1"
        }
    }
}

/// Where each setting is saved (UserDefaults, through @AppStorage).
/// Which edge the stream's Control Center comes out of.
nonisolated enum ControlCenterSide: String, CaseIterable { case right = "Right", left = "Left" }

nonisolated enum SettingsKey {
    static let controlCenterSide = "controlCenterSide"
    static let touchMode = "touchMode" // TouchMode
    static let coverShape = "coverShape"
    static let onlineArtwork = "onlineArtwork" // Bool, on by default: art from SteamGridDB, once its key is set
    static let artworkKeyVersion = "artworkKeyVersion" // Int, bumped as the SteamGridDB key changes: looks up again
    static let resolution = "resolution"
    static let customWidth = "customWidth" // Int pixels for the Custom resolution; missing until Custom is first picked
    static let customHeight = "customHeight"
    static let fps = "fps"
    static let codec = "codec"
    static let performanceOverlay = "performanceOverlay" // Bool: live stats in a corner of the stream
    static let adaptiveBitrate = "adaptiveBitrate" // Bool: the bitrate setting becomes a ceiling
    static let adaptiveBitrateDefault = true // its first-run value, read from more than one place
    static let dualSenseHaptics = "dualSenseHaptics" // Bool, on by default: take the host's waveform haptics
    static let phoneRumble = "phoneRumble" // Bool, on by default: the phone rumbles when the first player's pad can't
    static let bitrate = "bitrateKbps" // 0 = automatic, else kbps
    static let playAudioOnPC = "playAudioOnPC" // Bool: sound also plays from the PC's speakers
    static let hdr = "hdr" // Bool: ask for HDR (10-bit HEVC) on HDR screens
    static let buttonGuide = "buttonGuide" // ButtonGuideMode
    static let splashScreen = "splashScreen" // Bool, on by default: the game's art from Play until it's showing
    static let splashWait = "splashWait" // Int seconds the splash stays past the first picture; missing: 3
    static let splashEndsOnSound = "splashEndsOnSound" // Bool (beta): the splash goes once the game sounds, Splash Wait at most
    static let streamTutorialSeen = "streamTutorialSeen" // Bool: the first-stream guide has been dismissed
    static let fourFingerGestures = "fourFingerGestures" // Bool, off by default: four fingers get the six gestures too
    static let pictureInPicture = "pictureInPicture" // Bool, on by default: pinch or leaving the app floats the stream
}

/// The stream size, frame rate, codecs and bitrate to ask for. Pure functions, so they can be tested.
nonisolated enum StreamSettings {
    static let bitrateRange = 10_000...1_000_000 // kbps: 10 Mbps to 1 Gbps for the custom slider, in 10 Mbps steps
    static let bitrateStep = 10_000
    /// The most a host accepts for bitrate changes during a stream (Vibepollo: absolute_max_bitrate_kbps in nvhttp.cpp).
    // shortcut: assumes that cap; if another host allows more, read the applied value it returns instead.
    static let liveBitrateLimit = 500_000

    /// Pixel size for a resolution option, landscape. `safeAreaPixels` is the screen minus its cutout and
    /// home-indicator insets, in pixels. `custom` is the saved Custom size, fitted to `videoFormats`.
    static func size(for option: ResolutionOption, nativePixels: CGSize, safeAreaPixels: CGSize,
                     custom: (width: Int, height: Int), videoFormats: Int32) -> (width: Int, height: Int) {
        switch option {
        case .fullScreen: matchScreen(nativePixels: nativePixels)
        case .safeArea: matchScreen(nativePixels: safeAreaPixels)
        case .p720: (1280, 720)
        case .p1080: (1920, 1080)
        case .p4k: (3840, 2160)
        case .custom: custom.width > 0 && custom.height > 0
            ? customSize(width: custom.width, height: custom.height, videoFormats: videoFormats)
            : matchScreen(nativePixels: nativePixels)
        }
    }

    /// A typed size made safe to ask for: even, at least 256, and at most 4096 on H.264 or 8192 on HEVC and AV1.
    static func customSize(width: Int, height: Int, videoFormats: Int32) -> (width: Int, height: Int) {
        let largest = videoFormats & (VIDEO_FORMAT_H265 | VIDEO_FORMAT_AV1_MAIN8) != 0 ? 8192 : 4096
        func fit(_ side: Int) -> Int { min(max(side, 256), largest) / 2 * 2 }
        return (fit(width), fit(height))
    }

    /// The number typed into a Width or Height field; blank or invalid text keeps the saved one.
    static func side(typed: String, saved: Int) -> Int {
        Int(typed.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil } ?? saved
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
    /// HDR adds the 10-bit versions, which the PC picks when its display is in HDR (it falls back to 8-bit otherwise).
    /// AV1 keeps HEVC and H.264 as fallbacks for PCs whose GPU can't encode AV1, like moonlight-ios.
    static func videoFormats(for codec: CodecOption, hevcInHardware: Bool, av1InHardware: Bool = false, hdr: Bool = false) -> Int32 {
        let automatic = VIDEO_FORMAT_H264 | (hevcInHardware ? VIDEO_FORMAT_H265 : 0)
        let formats: Int32 = switch codec {
        case .automatic: automatic
        case .h264: VIDEO_FORMAT_H264
        case .hevc: VIDEO_FORMAT_H265
        case .av1: av1InHardware ? VIDEO_FORMAT_AV1_MAIN8 | automatic : automatic // a saved choice the device can't do
        }
        guard hdr else { return formats }
        return formats | (formats & VIDEO_FORMAT_H265 != 0 ? VIDEO_FORMAT_H265_MAIN10 : 0)
            | (formats & VIDEO_FORMAT_AV1_MAIN8 != 0 ? VIDEO_FORMAT_AV1_MAIN10 : 0)
    }

    /// kbps: 20 Mbps for 1080p60, scaled by pixels per second, kept between 10 and 100 Mbps.
    static func bitrate(width: Int, height: Int, fps: Int) -> Int {
        let scale = Double(width * height * fps) / Double(1920 * 1080 * 60)
        return min(max(Int(20_000 * scale), 10_000), 100_000)
    }

    /// Resolution, frame rate and codec are fixed when a stream starts (the PC sets up its display mode and encoder
    /// for them), so changing any of them needs a reconnect. Bitrate doesn't: Vibepollo can change it live.
    static func needsReconnect(running: (width: Int, height: Int, fps: Int, videoFormats: Int32),
                               wanted: (width: Int, height: Int, fps: Int, videoFormats: Int32)) -> Bool {
        running.width != wanted.width || running.height != wanted.height || running.fps != wanted.fps
            || running.videoFormats != wanted.videoFormats
    }

    /// The saved bitrate (0 = automatic) for this stream.
    static func effectiveBitrate(saved: Int, width: Int, height: Int, fps: Int) -> Int {
        switch saved {
        case 0: bitrate(width: width, height: height, fps: fps)
        // Older versions saved "Unlimited" as -1 or 2,000,000: both mean the highest setting now.
        case ..<0, (bitrateRange.upperBound + 1)...: bitrateRange.upperBound
        default: min(max(saved, bitrateRange.lowerBound), bitrateRange.upperBound)
        }
    }

    /// The custom slider is logarithmic (0...1 ↔ 10...1000 Mbps), so low bitrates aren't squeezed into a sliver.
    static func sliderPosition(kbps: Int) -> Double {
        log(Double(min(max(kbps, bitrateRange.lowerBound), bitrateRange.upperBound)) / Double(bitrateRange.lowerBound)) / log(100)
    }

    /// The bitrate at a slider position, snapped to 10 Mbps.
    static func kbps(sliderPosition position: Double) -> Int {
        let raw = Double(bitrateRange.lowerBound) * pow(100, min(max(position, 0), 1))
        return Int((raw / Double(bitrateStep)).rounded()) * bitrateStep
    }

    /// One controller step on the custom slider: 10 Mbps.
    static func steppedBitrate(_ kbps: Int, by direction: Int) -> Int {
        let snapped = Int((Double(kbps) / Double(bitrateStep)).rounded()) * bitrateStep
        return min(max(snapped + direction * bitrateStep, bitrateRange.lowerBound), bitrateRange.upperBound)
    }
}

/// The current screen's measurements, read when a stream is about to start.
enum ScreenInfo {
    private static var scene: UIWindowScene? { UIApplication.shared.connectedScenes.first as? UIWindowScene }

    static var nativePixels: CGSize { scene?.screen.nativeBounds.size ?? CGSize(width: 1920, height: 1080) }
    static var maximumFramesPerSecond: Int { scene?.screen.maximumFramesPerSecond ?? 60 }
    /// The first-run frame rate: 120 on a screen that shows it.
    static var defaultFPS: Int { maximumFramesPerSecond >= 120 ? 120 : 60 }
    static var hevcInHardware: Bool { VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) }
    static var av1InHardware: Bool { VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) }
    /// The screen can show HDR10 video (and HEVC is decoded in hardware, which HDR streams use).
    static var supportsHDR: Bool { AVPlayer.eligibleForHDRPlayback && hevcInHardware }

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
