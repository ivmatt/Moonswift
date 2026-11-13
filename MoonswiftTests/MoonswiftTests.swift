import CoreGraphics
import CoreMedia
import Foundation
import MoonlightCore
import Security
import Testing
@testable import Moonswift

struct ServerInfoTests {
    // Trimmed from what Vibepollo's nvhttp.cpp serverinfo() emits over HTTP.
    let sample = """
    <?xml version="1.0" encoding="utf-8"?>
    <root status_code="200">
        <hostname>GAMING-PC</hostname>
        <appversion>7.1.431.-1</appversion>
        <uniqueid>ABC123</uniqueid>
        <HttpsPort>47984</HttpsPort>
        <ExternalPort>47989</ExternalPort>
        <PairStatus>0</PairStatus>
    </root>
    """

    @Test func parsesHost() throws {
        let info = try ServerInfo(xml: Data(sample.utf8))
        #expect(info.hostname == "GAMING-PC")
        #expect(info.uniqueID == "ABC123")
        #expect(info.httpsPort == 47984)
        #expect(info.pairStatus == .unpaired)
    }

    @Test func missingPairStatusIsUnknown() throws {
        let xml = #"<root status_code="200"><hostname>PC</hostname></root>"#
        #expect(try ServerInfo(xml: Data(xml.utf8)).pairStatus == .unknown)
    }

    @Test func hostErrorUsesStatusMessage() {
        let xml = #"<root status_code="503" status_message="Busy"/>"#
        #expect(throws: ServerInfoError.hostError(code: 503, message: "Busy")) {
            try ServerInfo(xml: Data(xml.utf8))
        }
    }

    @Test func garbageIsMalformed() {
        #expect(throws: ServerInfoError.malformedResponse) {
            try ServerInfo(xml: Data("<html>not it".utf8))
        }
    }

    @Test func buildsURL() throws {
        #expect(try hostURL(for: " 10.0.4.20 ").absoluteString == "http://10.0.4.20:47989/serverinfo")
        #expect(try hostURL(for: "10.0.4.20:1234").absoluteString == "http://10.0.4.20:1234/serverinfo")
        #expect(try hostURL(for: "10.0.4.20:47989", path: "/pair", httpsPort: 47984,
                            query: [URLQueryItem(name: "phrase", value: "pairchallenge")]).absoluteString
                == "https://10.0.4.20:47984/pair?phrase=pairchallenge")
        #expect(throws: ServerInfoError.invalidAddress) { try hostURL(for: "10.0.4.20/x") }
        #expect(throws: ServerInfoError.invalidAddress) { try hostURL(for: "") }
    }
}

struct PairingCryptoTests {
    @Test func aesMatchesFIPS197Vector() throws {
        // FIPS-197 appendix C.1, AES-128.
        let key = try #require(Data(hex: "000102030405060708090A0B0C0D0E0F"))
        let plain = try #require(Data(hex: "00112233445566778899AABBCCDDEEFF"))
        let cipher = try aes128ECB(plain, key: key, encrypt: true)
        #expect(cipher.hex == "69C4E0D86A7B0430D8CDB78070B4C55A")
        #expect(try aes128ECB(cipher, key: key, encrypt: false) == plain)
        #expect(throws: PairingError.self) { try aes128ECB(Data(count: 15), key: key, encrypt: true) }
    }

    @Test func hexRoundTripsAndRejectsJunk() {
        #expect(Data([0x00, 0xAB, 0xFF]).hex == "00ABFF")
        #expect(Data(hex: "00abFF") == Data([0x00, 0xAB, 0xFF]))
        #expect(Data(hex: "ABC") == nil)
        #expect(Data(hex: "+1") == nil)
        #expect(Data(hex: "zz") == nil)
    }

    @Test func selfSignedCertificateIsValid() throws {
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary
        let key = try #require(SecKeyCreateRandomKey(attributes, nil))
        let der = try makeSelfSignedCertificate(privateKey: key)

        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        #expect(SecCertificateCopySubjectSummary(certificate) as String? == "NVIDIA GameStream Client")
        let certificateKey = try #require(SecCertificateCopyKey(certificate))
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        #expect(SecKeyCopyExternalRepresentation(certificateKey, nil) as Data? ==
                SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)

        // The extracted signature must verify over the to-be-signed part, as the host will check.
        let outer = try #require(DER.elements(der)?.first)
        let parts = try #require(DER.elements(outer.content))
        let signature = try #require(certificateSignature(fromDER: der))
        #expect(signature.count == 256)
        #expect(SecKeyVerifySignature(certificateKey, .rsaSignatureMessagePKCS1v15SHA256, parts[0].raw as CFData,
                                      signature as CFData, nil))

        #expect(MoonswiftDERFromPEM(pem(fromDER: der)) == der)
    }

    @Test func malformedDERIsRejected() {
        #expect(certificateSignature(fromDER: Data([0x30, 0x05, 0x01])) == nil)
        #expect(DER.elements(Data([0x30, 0x82, 0xFF])) == nil)
    }
}

struct AppListTests {
    @Test func parsesApps() throws {
        // Shape of Vibepollo's nvhttp.cpp applist().
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <root status_code="200">
            <App><IsHdrSupported>1</IsHdrSupported><AppTitle>Desktop</AppTitle><UUID>A-1</UUID><IDX>0</IDX><ID>881448767</ID><ArtVersion>v1</ArtVersion></App>
            <App><IsHdrSupported>1</IsHdrSupported><AppTitle>Hades &amp; Co</AppTitle><UUID>B-2</UUID><IDX>1</IDX><ID>12</ID><ArtVersion></ArtVersion></App>
        </root>
        """
        let apps = try HostClient.parseAppList(Data(xml.utf8))
        #expect(apps.map(\.title) == ["Desktop", "Hades & Co"])
        #expect(apps[0].id == 881448767)
        #expect(apps[0].uuid == "A-1")
        #expect(apps[0].artVersion == "v1")
        #expect(apps[1].artVersion == "")
    }

    @Test func emptyListAndBadEntries() throws {
        #expect(try HostClient.parseAppList(Data(#"<root status_code="200"></root>"#.utf8)).isEmpty)
        let noID = #"<root status_code="200"><App><AppTitle>X</AppTitle></App></root>"#
        #expect(try HostClient.parseAppList(Data(noID.utf8)).isEmpty)
    }

    @Test func serverInfoReportsRunningGame() throws {
        let xml = #"<root status_code="200"><hostname>PC</hostname><currentgame>12</currentgame></root>"#
        #expect(try ServerInfo(xml: Data(xml.utf8)).currentGame == 12)
        #expect(try ServerInfo(xml: Data(#"<root status_code="200"><hostname>PC</hostname></root>"#.utf8)).currentGame == 0)
    }

    @Test func launchQueryHasWhatVibepolloRequires() throws {
        let app = try #require(HostApp(fields: ["ID": "12", "AppTitle": "Hades", "UUID": "B-2"]))
        let items = HostClient.launchQuery(app: app, width: 2752, height: 2064, fps: 60,
                                           rikey: Data(repeating: 0xAB, count: 16), rikeyID: -5)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(query["appid"] == "12")
        #expect(query["appuuid"] == "B-2")
        #expect(query["mode"] == "2752x2064x60")
        #expect(query["rikey"] == String(repeating: "AB", count: 16))
        #expect(query["rikeyid"] == "-5")
        #expect(query["localAudioPlayMode"] == "0")
        let withPCAudio = HostClient.launchQuery(app: app, width: 1, height: 1, fps: 60, rikey: Data(count: 16), rikeyID: 0, playAudioOnPC: true)
        #expect(withPCAudio.first { $0.name == "localAudioPlayMode" }?.value == "1")
        #expect(query["hdrMode"] == nil)
        let withHDR = HostClient.launchQuery(app: app, width: 1, height: 1, fps: 60, rikey: Data(count: 16), rikeyID: 0, hdr: true)
        #expect(withHDR.first { $0.name == "hdrMode" }?.value == "1")
        #expect(withHDR.first { $0.name == "clientHdrCapMetaDataId" }?.value == "NV_STATIC_METADATA_TYPE_1")
    }
}

struct ControllerNavigationTests {
    // 7 items, 3 columns:
    //   0 1 2
    //   3 4 5
    //   6
    @Test func gridMovesWithinBounds() {
        func move(_ from: Int, _ command: GamepadCommand) -> Int { FocusMove.next(from, count: 7, columns: 3, command) }
        #expect(move(0, .right) == 1)
        #expect(move(2, .right) == 2) // right edge
        #expect(move(3, .left) == 3) // left edge doesn't wrap to the row above
        #expect(move(4, .up) == 1)
        #expect(move(1, .up) == 1) // top edge
        #expect(move(1, .down) == 4)
        #expect(move(5, .down) == 6) // partial last row: land on its last item
        #expect(move(6, .down) == 6)
        #expect(move(6, .right) == 6)
        #expect(move(6, .up) == 3)
    }

    @Test func listAndEmptyCases() {
        #expect(FocusMove.next(0, count: 3, columns: 1, .down) == 1)
        #expect(FocusMove.next(2, count: 3, columns: 1, .down) == 2)
        #expect(FocusMove.next(0, count: 3, columns: 1, .right) == 0)
        #expect(FocusMove.next(5, count: 0, columns: 4, .down) == 0)
        #expect(FocusMove.next(9, count: 3, columns: 1, .up) == 1) // stale index is clamped first
    }

    @Test func stickNeedsToPassThresholdAndHasHysteresis() {
        var stick = HeldDirection()
        #expect(stick.update(x: 0.4, y: 0) == nil) // inside the dead zone
        #expect(stick.update(x: 0.6, y: 0) == .right)
        #expect(stick.update(x: 0.35, y: 0) == .right) // still held: release is below 0.3
        #expect(stick.update(x: 0.2, y: 0) == nil)
        #expect(stick.update(x: 0, y: -0.9) == .down)
        #expect(stick.update(x: 0.9, y: -0.2) == .right) // down released, right engaged
        #expect(stick.update(x: -0.1, y: 0.8) == .up)
    }
}

struct StreamSetupTests {
    @Test func libraryLaunchParametersParse() {
        let items = HostClient.libraryLaunchQuery("&corever=1&foo=a=b&flag")
        #expect(items.map(\.name) == ["corever", "foo", "flag"])
        #expect(items.map(\.value) == ["1", "a=b", nil])
        #expect(HostClient.libraryLaunchQuery("").isEmpty)
    }

    @Test func libraryAsksForACoreVersion() {
        // Proves the C library is linked and callable from Swift.
        let raw = String(cString: LiGetLaunchUrlQueryParameters())
        #expect(HostClient.libraryLaunchQuery(raw).contains { $0.name == "corever" })
    }

    @Test func streamConfigurationCarriesTheLaunchKeys() {
        let key = Data((1...16).map { UInt8($0) })
        let launch = LaunchSession(rtspURL: "rtspenc://10.0.4.20:48010", riKey: key, riKeyID: 0x0102_0304)
        var config = StreamSession.makeStreamConfiguration(launch: launch, width: 1920, height: 1080, fps: 60, bitrate: 20_000,
                                                            videoFormats: VIDEO_FORMAT_H264)
        #expect(config.width == 1920 && config.height == 1080 && config.fps == 60 && config.bitrate == 20_000)
        #expect(withUnsafeBytes(of: &config.remoteInputAesKey) { Data($0) } == key)
        // rikeyid big-endian in the first 4 bytes, the rest zero (moonlight-ios Connection.m).
        #expect(withUnsafeBytes(of: &config.remoteInputAesIv) { Data($0) } == Data([1, 2, 3, 4] + Array(repeating: 0, count: 12)))
        #expect(config.audioConfiguration == 0x0003_02CA) // AUDIO_CONFIGURATION_STEREO
    }

    @Test func serverInfoReadsStreamingFields() throws {
        let xml = #"<root status_code="200"><hostname>PC</hostname><appversion>7.1.431.-1</appversion><ServerCodecModeSupport>3843</ServerCodecModeSupport></root>"#
        let info = try ServerInfo(xml: Data(xml.utf8))
        #expect(info.appVersion == "7.1.431.-1")
        #expect(info.codecModeSupport == 3843)
        #expect(info.gfeVersion == nil)
        #expect(hostAddress(" 10.0.4.20:47989 ") == "10.0.4.20")
    }
}

struct StreamMediaTests {
    @Test func annexBSplitsOnThreeAndFourByteStartCodes() {
        let stream = Data([0, 0, 0, 1, 0x67, 0xAA, 0, 0, 1, 0x68, 0xBB, 0xCC, 0, 0, 0, 1, 0x65])
        #expect(AnnexB.nalUnits(stream) == [Data([0x67, 0xAA]), Data([0x68, 0xBB, 0xCC]), Data([0x65])])
        #expect(AnnexB.nalUnits(Data([0x12, 0x34])).isEmpty)
    }

    @Test func annexBBecomesLengthPrefixed() {
        let stream = Data([0, 0, 1, 0x67, 0xAA, 0, 0, 0, 1, 0x65])
        #expect(AnnexB.lengthPrefixed(stream) == Data([0, 0, 0, 2, 0x67, 0xAA, 0, 0, 0, 1, 0x65]))
    }

    @Test func matchScreenIsLandscapeRoundedAndCapped() {
        let ipad = StreamSettings.matchScreen(nativePixels: CGSize(width: 2064, height: 2752))
        #expect(ipad.width == 2752 && ipad.height == 2064)
        let odd = StreamSettings.matchScreen(nativePixels: CGSize(width: 1179, height: 2556))
        #expect(odd.width == 2552 && odd.height == 1176) // multiples of 8
        let big = StreamSettings.matchScreen(nativePixels: CGSize(width: 6000, height: 4000))
        #expect(big.width == 3840 && big.height == 2560) // capped, aspect kept
    }

    @Test func bitrateScalesWithPixelsAndIsClamped() {
        #expect(StreamSettings.bitrate(width: 1920, height: 1080, fps: 60) == 20_000)
        #expect(StreamSettings.bitrate(width: 3840, height: 2160, fps: 60) == 80_000)
        #expect(StreamSettings.bitrate(width: 640, height: 360, fps: 30) == 10_000)
    }

    @Test func ringBufferDropsOldAudioAndPadsUnderruns() {
        let ring = SampleRing(channels: 2, maxFrames: 4)
        var samples: [Float] = (1...10).map(Float.init) // 5 stereo frames: over the 4-frame limit
        samples.withUnsafeBufferPointer { ring.write($0) }
        #expect(ring.queuedFrames == 2) // dropped down to half the limit, keeping the newest
        var out = [Float](repeating: -1, count: 6)
        out.withUnsafeMutableBufferPointer { ring.read(frames: 3, into: $0) }
        #expect(out == [7, 8, 9, 10, 0, 0]) // newest frames, then silence
        samples = [1, 2]
        samples.withUnsafeBufferPointer { ring.write($0) }
        #expect(ring.queuedFrames == 1)
    }
}

struct InputTests {
    @Test func padSnapshotMapsToLibraryFlags() {
        var pad = PadSnapshot(a: true, up: true, menu: true)
        pad.touchpadClick = true
        pad.paddles = [false, true]
        pad.leftTrigger = 1
        pad.leftStick = (1, -1)
        let state = ControllerMapping.state(pad)
        #expect(state.buttons == A_FLAG | UP_FLAG | PLAY_FLAG | TOUCHPAD_FLAG | PADDLE2_FLAG)
        #expect(state.leftTrigger == 255 && state.rightTrigger == 0)
        #expect(state.leftX == 32767 && state.leftY == -32767)
        #expect(ControllerMapping.axis(2) == 32767) // clamped
    }

    @Test func motionUnitsMatchTheLibrary() {
        let (ax, ay, az) = ControllerMapping.acceleration(x: 0, y: -1, z: 0) // resting: gravity along -y in g
        #expect(ax == 0 && abs(ay - 9.80665) < 0.0001 && az == 0)
        let (gx, gy, gz) = ControllerMapping.rotation(x: .pi, y: .pi / 2, z: 0)
        #expect(abs(gx - 180) < 0.001 && gy == 0 && abs(gz + 90) < 0.001) // y and z swap, y negated
        let corner = ControllerMapping.touchpadPoint(x: -1, y: 1) // top-left of the touchpad
        #expect(corner.0 == 0 && corner.1 == 0)
    }

    @Test func trackpadTapsClick() {
        var pad = TrackpadGestures()
        pad.began(1, at: CGPoint(x: 100, y: 100), time: 0)
        #expect(pad.ended(1, time: 0.1) == [.click(BUTTON_LEFT)])
        pad.began(1, at: CGPoint(x: 100, y: 100), time: 1)
        pad.began(2, at: CGPoint(x: 150, y: 100), time: 1.02)
        #expect(pad.ended(1, time: 1.1).isEmpty)
        #expect(pad.ended(2, time: 1.12) == [.click(BUTTON_RIGHT)])
        pad.began(1, at: .zero, time: 2)
        #expect(pad.ended(1, time: 2.5).isEmpty) // held too long to be a tap
    }

    @Test func trackpadMovesAndScrolls() {
        var pad = TrackpadGestures()
        pad.cursorScale = 2
        pad.began(1, at: CGPoint(x: 0, y: 0), time: 0)
        #expect(pad.moved(1, to: CGPoint(x: 5, y: -3)) == [.move(dx: 10, dy: -6)])
        #expect(pad.moved(1, to: CGPoint(x: 5.2, y: -3)).isEmpty) // fraction carried over...
        #expect(pad.moved(1, to: CGPoint(x: 5.6, y: -3)) == [.move(dx: 1, dy: 0)]) // ...until it adds up
        _ = pad.moved(1, to: CGPoint(x: 20, y: -3)) // past the 10 pt tap tolerance
        #expect(pad.ended(1, time: 0.1).isEmpty) // moved: not a tap

        pad.scrollScale = 3
        pad.began(1, at: CGPoint(x: 0, y: 0), time: 1)
        pad.began(2, at: CGPoint(x: 50, y: 0), time: 1)
        #expect(pad.moved(1, to: CGPoint(x: 0, y: 20)) == [.scroll(30)]) // half of 20 * 3: each finger counts half
        #expect(pad.moved(2, to: CGPoint(x: 50, y: 20)) == [.scroll(30)])
        #expect(pad.ended(1, time: 1.1).isEmpty && pad.ended(2, time: 1.1).isEmpty) // a scroll isn't a right-click
    }

    @Test func touchesMapIntoTheVideoArea() {
        // A 16:9 stream on a 4:3 screen sits in a letterbox.
        let video = VideoGeometry.videoRect(stream: CGSize(width: 1920, height: 1080), in: CGRect(x: 0, y: 0, width: 1200, height: 900))
        #expect(video == CGRect(x: 0, y: 112.5, width: 1200, height: 675))
        #expect(VideoGeometry.normalized(CGPoint(x: 600, y: 450), in: video) == CGPoint(x: 0.5, y: 0.5))
        #expect(VideoGeometry.normalized(CGPoint(x: -10, y: 0), in: video) == CGPoint(x: 0, y: 0)) // bars clamp to the edge
    }

    @Test func keyboardMapsToWindowsKeys() {
        #expect(KeyMap.key(hidUsage: 0x04) == KeyMap.Key(virtualKey: 0x41, extended: false)) // A
        #expect(KeyMap.key(hidUsage: 0x27) == KeyMap.Key(virtualKey: 0x30, extended: false)) // 0
        #expect(KeyMap.key(hidUsage: 0x3A) == KeyMap.Key(virtualKey: 0x70, extended: false)) // F1
        #expect(KeyMap.key(hidUsage: 0x28) == KeyMap.Key(virtualKey: 0x0D, extended: false)) // Enter
        #expect(KeyMap.key(hidUsage: 0x58) == KeyMap.Key(virtualKey: 0x0D, extended: true)) // Numpad Enter
        #expect(KeyMap.key(hidUsage: 0x50) == KeyMap.Key(virtualKey: 0x25, extended: true)) // Left arrow
        #expect(KeyMap.modifier(hidUsage: 0xE5) == Int8(MODIFIER_SHIFT))
        #expect(KeyMap.key(hidUsage: 0x00) == nil)
    }
}

struct StreamSettingsTests {
    @Test func resolutionOptionsGiveLandscapeSizes() {
        let native = CGSize(width: 1206, height: 2622), safe = CGSize(width: 2445, height: 1143)
        func size(_ option: ResolutionOption) -> (Int, Int) {
            let s = StreamSettings.size(for: option, nativePixels: native, safeAreaPixels: safe)
            return (s.width, s.height)
        }
        #expect(size(.fullScreen) == (2616, 1200)) // landscape, multiples of 8
        #expect(size(.safeArea) == (2440, 1136))
        #expect(size(.p720) == (1280, 720) && size(.p1080) == (1920, 1080) && size(.p4k) == (3840, 2160))
    }

    @Test func frameRatesFollowTheScreen() {
        #expect(StreamSettings.frameRates(screenMaximum: 60) == [30, 60])
        #expect(StreamSettings.frameRates(screenMaximum: 120) == [30, 60, 90, 120])
        #expect(StreamSettings.frameRates(screenMaximum: 0) == [30, 60]) // unknown: 60 is always offered
    }

    @Test func codecChoiceSetsTheLibraryFlags() {
        #expect(StreamSettings.videoFormats(for: .automatic, hevcInHardware: true) == VIDEO_FORMAT_H264 | VIDEO_FORMAT_H265)
        #expect(StreamSettings.videoFormats(for: .automatic, hevcInHardware: false) == VIDEO_FORMAT_H264)
        #expect(StreamSettings.videoFormats(for: .h264, hevcInHardware: true) == VIDEO_FORMAT_H264)
        #expect(StreamSettings.videoFormats(for: .hevc, hevcInHardware: true) == VIDEO_FORMAT_H265)
        #expect(StreamSettings.videoFormats(for: .automatic, hevcInHardware: true, hdr: true) == VIDEO_FORMAT_H264 | VIDEO_FORMAT_H265 | VIDEO_FORMAT_H265_MAIN10)
        #expect(StreamSettings.videoFormats(for: .h264, hevcInHardware: true, hdr: true) == VIDEO_FORMAT_H264) // HDR needs HEVC
        #expect(StreamSettings.videoFormats(for: .automatic, hevcInHardware: false, hdr: true) == VIDEO_FORMAT_H264)
        #expect(StreamSettings.videoFormats(for: .av1, hevcInHardware: true, av1InHardware: true)
                == VIDEO_FORMAT_AV1_MAIN8 | VIDEO_FORMAT_H265 | VIDEO_FORMAT_H264) // HEVC and H.264 as fallbacks
        #expect(StreamSettings.videoFormats(for: .av1, hevcInHardware: true, av1InHardware: true, hdr: true)
                == VIDEO_FORMAT_AV1_MAIN8 | VIDEO_FORMAT_AV1_MAIN10 | VIDEO_FORMAT_H265 | VIDEO_FORMAT_H265_MAIN10 | VIDEO_FORMAT_H264)
        #expect(StreamSettings.videoFormats(for: .av1, hevcInHardware: true, av1InHardware: false)
                == VIDEO_FORMAT_H265 | VIDEO_FORMAT_H264) // no AV1 decoder: Automatic
    }

    @Test func savedBitrateOverridesAutomaticWithinRange() {
        #expect(StreamSettings.effectiveBitrate(saved: 0, width: 1920, height: 1080, fps: 60) == 20_000)
        #expect(StreamSettings.effectiveBitrate(saved: 450_000, width: 1920, height: 1080, fps: 60) == 450_000)
        #expect(StreamSettings.effectiveBitrate(saved: 1_000, width: 1920, height: 1080, fps: 60) == 10_000) // range floor
        #expect(StreamSettings.effectiveBitrate(saved: -1, width: 1920, height: 1080, fps: 60) == 1_000_000) // old "Unlimited"
        #expect(StreamSettings.effectiveBitrate(saved: 2_000_000, width: 1920, height: 1080, fps: 60) == 1_000_000) // older "Unlimited"
    }

    @Test func endedStreamsExplainThemselves() {
        #expect(terminationReason(ML_ERROR_NO_VIDEO_TRAFFIC) == "The host sent no video. A lower bitrate may help.")
        #expect(terminationReason(-999) == "Connection lost (error -999).")
    }

    @Test func bitrateSliderIsLogarithmicInTenMbpsSteps() {
        #expect(StreamSettings.kbps(sliderPosition: 0) == 10_000)
        #expect(StreamSettings.kbps(sliderPosition: 1) == 1_000_000)
        #expect(StreamSettings.kbps(sliderPosition: 0.5) == 100_000) // the middle is 100 Mbps, not 500
        #expect(StreamSettings.kbps(sliderPosition: 0.3) % 10_000 == 0)
        #expect(StreamSettings.kbps(sliderPosition: StreamSettings.sliderPosition(kbps: 50_000)) == 50_000) // round trip
    }

    @Test func onlyStartupSettingsNeedAReconnect() {
        let running = (width: 2664, height: 1872, fps: 60, videoFormats: VIDEO_FORMAT_H265)
        #expect(!StreamSettings.needsReconnect(running: running, wanted: running)) // e.g. only the bitrate changed
        #expect(StreamSettings.needsReconnect(running: running, wanted: (2664, 1872, 120, VIDEO_FORMAT_H265)))
        #expect(StreamSettings.needsReconnect(running: running, wanted: (1920, 1080, 60, VIDEO_FORMAT_H265)))
        #expect(StreamSettings.needsReconnect(running: running, wanted: (2664, 1872, 60, VIDEO_FORMAT_H264)))
    }

    @Test func controllerStepsAreTenMbps() {
        #expect(StreamSettings.steppedBitrate(50_000, by: 1) == 60_000)
        #expect(StreamSettings.steppedBitrate(50_000, by: -1) == 40_000)
        #expect(StreamSettings.steppedBitrate(54_000, by: 1) == 60_000) // snaps from an automatic value
        #expect(StreamSettings.steppedBitrate(10_000, by: -1) == 10_000) // stays in range
        #expect(StreamSettings.steppedBitrate(1_000_000, by: 1) == 1_000_000)
    }
}

struct RemoteAccessTests {
    @Test func plainHTTPOnlyGoesToHomeNetworkHosts() {
        for host in ["10.0.4.20", "192.168.1.5", "172.20.0.1", "169.254.83.107", "127.0.0.1", "100.101.102.103",
                     "fe80::1%en0", "[fd4c:2e47::1]", "::1", "gaming-pc.local", "gaming-pc"] {
            #expect(isHomeNetworkHost(host), "\(host) should count as home network")
        }
        for host in ["216.240.36.174", "172.32.0.1", "100.128.0.1", "8.8.8.8", "2001:4860::8888", "example.com", ""] {
            #expect(!isHomeNetworkHost(host), "\(host) should not count as home network")
        }
    }

    @Test func plainHTTPToAPublicAddressIsRefusedBeforeSending() async {
        await #expect(throws: ServerInfoError.insecureBlocked) {
            try await hostData(URL(string: "http://203.0.113.7:47989/serverinfo")!, timeout: 1)
        }
    }

    @Test func localAddressIsTriedBeforeRemote() {
        #expect(candidateAddresses(local: "10.0.4.20", remote: "203.0.113.7") == ["10.0.4.20", "203.0.113.7"])
        #expect(candidateAddresses(local: "10.0.4.20", remote: nil) == ["10.0.4.20"])
        #expect(candidateAddresses(local: "10.0.4.20", remote: "  ") == ["10.0.4.20"])
        #expect(candidateAddresses(local: "10.0.4.20", remote: "10.0.4.20:47989") == ["10.0.4.20"]) // same host
    }

    @Test func stunResultFormatsAsDottedIPv4() {
        let bytes: [UInt8] = [203, 0, 113, 7] // network order: first byte first
        let value = bytes.withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(ipv4String(networkOrder: value) == "203.0.113.7")
    }
}

struct AdaptiveBitrateTests {
    private let calm = NetworkSample(packets: 1000, rttMs: 20)

    @Test func lossCutsQuicklyButWaitsBetweenCuts() {
        var abr = BitrateController(ceiling: 80_000)
        var loss = calm
        loss.lostFrames = 3
        #expect(abr.update(loss, now: 0) == 56_000) // 70%
        #expect(abr.reason == "lowered for packet loss")
        #expect(abr.update(loss, now: 1) == nil) // within 2 s: let the cut take effect
        #expect(abr.update(loss, now: 2) == 39_000)
    }

    @Test func neverGoesBelowTheFloor() {
        var abr = BitrateController(ceiling: 6_000)
        var loss = calm
        loss.fecFailed = 1
        #expect(abr.update(loss, now: 0) == 5_000)
        #expect(abr.update(loss, now: 5) == nil) // already at the floor
    }

    @Test func sustainedDelayCutsButASpikeDoesNot() {
        var abr = BitrateController(ceiling: 50_000)
        _ = abr.update(calm, now: 0) // baseline 20 ms
        var slow = calm
        slow.rttMs = 90
        #expect(abr.update(slow, now: 1) == nil) // one second of high delay: wait
        #expect(abr.update(calm, now: 2) == nil) // it recovered
        #expect(abr.update(slow, now: 3) == nil)
        #expect(abr.update(slow, now: 4) == 35_000) // two in a row
        #expect(abr.reason == "lowered for rising delay")
    }

    @Test func calmNetworkClimbsBackToTheCeilingAndStops() {
        var abr = BitrateController(ceiling: 30_000, start: 20_000)
        var now: TimeInterval = 0
        var results: [Int] = []
        while now < 100 {
            if let changed = abr.update(calm, now: now) { results.append(changed) }
            now += 1
        }
        #expect(results == [22_000, 24_200, 26_620, 29_282, 30_000]) // +10% (at least 2 Mbps) every 10 calm seconds
        #expect(abr.reason == "at your setting")
    }

    @Test func noClimbingSoonAfterACut() {
        var abr = BitrateController(ceiling: 50_000)
        var loss = calm
        loss.lostFrames = 1
        _ = abr.update(loss, now: 0) // 35 Mbps
        var changes: [Int] = []
        for second in 1..<30 { if let changed = abr.update(calm, now: TimeInterval(second)) { changes.append(changed) } }
        #expect(changes.isEmpty) // calm, but within 30 s of the cut
        #expect(abr.update(calm, now: 30) == 38_500)
    }

    @Test func repairedLossHoldsWithoutCutting() {
        var abr = BitrateController(ceiling: 40_000, start: 30_000)
        var repairing = calm
        repairing.fecRecovered = 80 // 8% of packets
        for second in 0..<20 { #expect(abr.update(repairing, now: TimeInterval(second)) == nil) }
    }

    @Test func aLowerSettingCapsTheTarget() {
        var abr = BitrateController(ceiling: 80_000)
        #expect(abr.setCeiling(40_000) == 40_000)
        #expect(abr.setCeiling(60_000) == nil) // raising the ceiling doesn't jump; it climbs
        #expect(abr.target == 40_000)
    }
}

struct PerformanceTests {
    @Test func windowTurnsCountersIntoRates() {
        let old = StreamCounters(frames: 100, bytes: 0, lostFrames: 2, packets: 1000, fecRecovered: 10, fecFailed: 0,
                                 timedFrames: 100, receiveMicroseconds: 0, queueMicroseconds: 0,
                                 hostLatencyTenthsMs: 0, hostLatencyFrames: 0)
        let new = StreamCounters(frames: 160, bytes: 5_000_000, lostFrames: 5, packets: 3000, fecRecovered: 30, fecFailed: 1,
                                 timedFrames: 160, receiveMicroseconds: 120_000, queueMicroseconds: 60_000,
                                 hostLatencyTenthsMs: 1_200, hostLatencyFrames: 30)
        let window = PerformanceWindow(from: old, to: new, seconds: 1)
        #expect(window.fps == 60)
        #expect(window.mbps == 40)
        #expect(window.lostFrames == 3 && abs(window.lossPercent - 300.0 / 63) < 0.001) // 3 of 63 sent
        #expect(window.repairedPercent == 1) // 20 of 2000 packets
        #expect(window.receiveMs == 2 && window.queueMs == 1) // per frame
        #expect(window.hostMs == 4) // 1200 tenths over 30 frames
        let sample = window.sample(rttMs: 25, isPoor: false)
        #expect(sample.lostFrames == 3 && sample.fecFailed == 1 && sample.rttMs == 25)
    }

    @Test func overlayShowsWhatItKnows() {
        let quiet = PerformanceWindow(from: StreamCounters(), to: StreamCounters(), seconds: 1)
        let readout = PerformanceOverlay.Readout(window: quiet, targetFPS: 60, video: "HEVC 1920×1080 @ 60", rtt: nil, isRemote: true)
        #expect(readout.video == "HEVC 1920×1080 @ 60" && readout.isRemote)
        #expect(readout.rttText == "–")
        #expect(readout.latencyText == "host – · net – · queue – ms") // no frames: no averages
        #expect(readout.lossText == "0 lost (0.0%) · 0.0% repaired")
        #expect(readout.lossHealth == .good)
        let local = PerformanceOverlay.Readout(window: quiet, targetFPS: 120, video: nil, rtt: (3, 1), isRemote: false)
        #expect(local.video == "Waiting for video…")
        #expect(local.rttText == "3 ± 1 ms" && local.rttHealth == .good)
        #expect(PerformanceOverlay.Readout.health(fps: 119, target: 120) == .good)
        #expect(PerformanceOverlay.Readout.health(fps: 90, target: 120) == .warning)
        #expect(PerformanceOverlay.Readout.health(fps: 30, target: 120) == .bad)
    }
}

private func MoonswiftDERFromPEM(_ pem: String) -> Data? { der(fromPEM: pem) }

struct ErrorMessageTests {
    @Test func networkErrorsSayWhatToCheck() {
        #expect(ServerInfoError.unreachable(.timedOut).localizedDescription.contains("asleep"))
        #expect(ServerInfoError.hostError(code: 401, message: "x").localizedDescription.contains("pair again"))
        #expect(ServerInfoError.certificateChanged.localizedDescription.contains("pair again"))
    }

    @Test func portAdviceBlamesTheRightSide() {
        let udp = UInt32(ML_PORT_FLAG_UDP_47998 | ML_PORT_FLAG_UDP_47999)
        #expect(portNames(udp) == "UDP 47998, UDP 47999")
        #expect(portAdvice(ports: udp, testResult: UInt32(ML_PORT_FLAG_UDP_47998))?.hasPrefix("The network this device is on blocks UDP 47998.") == true)
        #expect(portAdvice(ports: udp, testResult: 0)?.contains("host's side is blocking UDP 47998, UDP 47999") == true)
        #expect(portAdvice(ports: udp, testResult: ML_TEST_RESULT_INCONCLUSIVE) == nil)
        #expect(portAdvice(ports: 0, testResult: 0) == nil)
    }
}

struct OnScreenKeyboardTests {
    @Test func charactersMapToTheirKeys() {
        #expect(KeyMap.hidUsage(for: "c") == 0x06)
        #expect(KeyMap.hidUsage(for: "C") == 0x06)
        #expect(KeyMap.hidUsage(for: "1") == 0x1E)
        #expect(KeyMap.hidUsage(for: "0") == 0x27)
        #expect(KeyMap.hidUsage(for: "é") == nil)
        #expect(KeyMap.key(hidUsage: KeyMap.hidUsage(for: "c")!)?.virtualKey == 0x43) // VK_C
    }
}

struct GameLibraryTests {
    @Test func savesPerPC() throws {
        let defaults = try #require(UserDefaults(suiteName: "GameLibraryTests"))
        defaults.removePersistentDomain(forName: "GameLibraryTests")
        let history = GameHistory(favorites: ["U2"], lastPlayed: ["U1": Date(timeIntervalSince1970: 5)])
        history.save(hostID: "pc", to: defaults)
        #expect(GameHistory.load(hostID: "pc", from: defaults) == history)
        #expect(GameHistory.load(hostID: "other", from: defaults) == GameHistory())
    }
}

struct HDRMetadataTests {
    @Test func boxesAreBigEndianInCoreMediaOrder() {
        // red, green, blue (x, y), white (x, y), max/min display luminance, max content / frame-average light, full frame
        var v: [UInt16] = [34000, 16000, 13250, 34500, 7500, 3000, 15635, 16450, 1000, 50, 0, 0, 0]
        let volume = HDRMetadata.masteringDisplay(v)
        #expect(volume?.count == 24)
        #expect(volume?.prefix(2) == Data([0x33, 0xC2])) // green x (13250) first, big-endian
        #expect(volume?.suffix(8) == Data([0x00, 0x98, 0x96, 0x80, 0x00, 0x00, 0x00, 0x32])) // 1000 nits ×10000, then 50
        #expect(HDRMetadata.contentLightLevel(v) == nil) // the PC didn't report content levels
        v[10] = 800
        v[11] = 400
        #expect(HDRMetadata.contentLightLevel(v) == Data([0x03, 0x20, 0x01, 0x90]))
        #expect(HDRMetadata.masteringDisplay(HDRMetadata.fields(SS_HDR_METADATA())) == nil) // no data: no box
        #expect(MemoryLayout<SS_HDR_METADATA>.size == 26) // 13 UInt16s, as fields(_:) reads it
    }

    @Test func labelSaysHDROnlyWhileOn() {
        var stats = StreamStats()
        stats.video = "HEVC 10-bit 2752×2064 @ 60"
        #expect(stats.videoLabel == "HEVC 10-bit 2752×2064 @ 60")
        stats.isHDR = true
        #expect(stats.videoLabel == "HEVC 10-bit HDR 2752×2064 @ 60")
    }
}

/// Real AV1 from SVT-AV1 (a temporal delimiter, then the sequence header OBU, then the start of the frame), with the
/// av1C box FFmpeg wrote for the same stream as the reference.
struct AV1Tests {
    static let sdrStream = "12000a0e0200000561e7f66357cc81010082328b101400a3a024d9257a4568207cbfabd8c2ba2b66"
    static let hdrStream = "12000a0e0200000561e7f66357ce8488048232bd101400a3a024dd44674337fc87bd729a6f9a99a7"

    @Test func sdrMatchesFFmpeg() throws {
        let stream = try #require(Data(hex: Self.sdrStream))
        let header = try #require(AV1SequenceHeader.find(in: stream))
        #expect(header.codecConfiguration == Data(hex: "81000c000a0e0200000561e7f66357cc81010082"))
        #expect((header.width, header.height) == (320, 180))
        #expect(header.bitDepth == 8)
        #expect((header.colorPrimaries, header.transferCharacteristics, header.matrixCoefficients) == (2, 2, 1)) // as ffprobe reads it
        #expect(header.formatDescription() != nil) // Core Media accepts it
    }

    @Test func hdrMatchesFFmpeg() throws {
        let stream = try #require(Data(hex: Self.hdrStream))
        let header = try #require(AV1SequenceHeader.find(in: stream))
        #expect(header.codecConfiguration == Data(hex: "81004c000a0e0200000561e7f66357ce84880482"))
        #expect(header.bitDepth == 10)
        #expect((header.colorPrimaries, header.transferCharacteristics, header.matrixCoefficients) == (9, 16, 9)) // BT.2020, PQ
        let extensions = header.formatExtensions()
        #expect(extensions[kCMFormatDescriptionExtension_TransferFunction] as? String
                == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
    }

    @Test func noSequenceHeaderOrTruncated() throws {
        #expect(AV1SequenceHeader.find(in: Data([0x12, 0x00])) == nil) // only a temporal delimiter
        let truncated = try #require(Data(hex: "12000a0e0200000561"))
        #expect(AV1SequenceHeader.find(in: truncated) == nil) // cut short
    }
}

struct PowerActionTests {
    @Test func sleepNeedsVersionSupportAndPermission() throws {
        let base = ["hostname": "PC", "PowerActionVersion": "1", "SleepSupported": "1"]
        #expect(try ServerInfo(fields: base.merging(["SleepAllowed": "1"]) { $1 }).canSleep)
        #expect(try !ServerInfo(fields: base.merging(["SleepAllowed": "0"]) { $1 }).canSleep) // not granted on the PC
        #expect(try !ServerInfo(fields: ["hostname": "PC"]).canSleep) // other hosts
    }
}

struct StreamGestureTests {
    let fingers = [CGPoint(x: 100, y: 300), CGPoint(x: 160, y: 290), CGPoint(x: 220, y: 300)]
    func moved(_ dx: CGFloat, _ dy: CGFloat) -> [CGPoint] { fingers.map { CGPoint(x: $0.x + dx, y: $0.y + dy) } }

    @Test func swipesFollowTheDominantDirection() {
        #expect(StreamGesture.classify(start: fingers, end: moved(10, -120)) == .swipeUp)
        #expect(StreamGesture.classify(start: fingers, end: moved(-5, 90)) == .swipeDown)
        #expect(StreamGesture.classify(start: fingers, end: moved(-150, 20)) == .swipeLeft)
        #expect(StreamGesture.classify(start: fingers, end: moved(150, -20)) == .swipeRight)
    }

    @Test func pinchNeedsARealSqueezeAndSmallMovesDoNothing() {
        let four = fingers + [CGPoint(x: 190, y: 360)]
        let squeezed = four.map { CGPoint(x: 167 + ($0.x - 167) * 0.3, y: 312 + ($0.y - 312) * 0.3) }
        #expect(StreamGesture.classify(start: four, end: squeezed) == .pinch)
        #expect(StreamGesture.classify(start: Array(four.prefix(3)), end: Array(squeezed.prefix(3))) == nil) // three fingers: no
        let slight = fingers.map { CGPoint(x: 160 + ($0.x - 160) * 0.8, y: $0.y) }
        #expect(StreamGesture.classify(start: fingers, end: slight) == nil) // resting fingers drifting together
        #expect(StreamGesture.classify(start: fingers, end: moved(20, 30)) == nil) // too short to be a swipe
        #expect(StreamGesture.classify(start: Array(fingers.prefix(2)), end: Array(fingers.prefix(2))) == nil)
    }
}

struct LaunchRequestTests {
    @Test func linksRoundTripAndMatchGames() throws {
        let link = try #require(URL(string: "moonswift://stream?pc=Desktop&game=Black%20Flag"))
        let request = try #require(LaunchRequest(url: link))
        #expect(request == LaunchRequest(pc: "Desktop", game: "Black Flag"))
        #expect(request.url.flatMap(LaunchRequest.init(url:)) == request)
        let noGame = try #require(URL(string: "moonswift://stream?pc=Desktop"))
        let otherScheme = try #require(URL(string: "https://stream?pc=a&game=b"))
        #expect(LaunchRequest(url: noGame) == nil)
        #expect(LaunchRequest(url: otherScheme) == nil)
        #expect(request.matches(pcID: "ABC", name: "desktop"))

        let apps = [("1", "Assassin's Creed Black Flag Resynced", "U1"), ("2", "Black Flag", "U2"), ("3", "Hades", "U3")]
            .compactMap { HostApp(fields: ["ID": $0.0, "AppTitle": $0.1, "UUID": $0.2]) }
        #expect(request.game(in: apps)?.id == 2) // the exact title wins over a longer one containing it
        #expect(LaunchRequest(pc: "x", game: "U3").game(in: apps)?.id == 3) // by UUID
        #expect(LaunchRequest(pc: "x", game: "resynced").game(in: apps)?.id == 1) // part of a title
        #expect(LaunchRequest(pc: "x", game: "Celeste").game(in: apps) == nil)
    }
}

struct ButtonMappingTests {
    @Test func nintendoSwapsFaceButtonsAndLeavesTheRest() {
        let pressed = A_FLAG | UP_FLAG
        #expect(ButtonRemap.nintendo.apply(pressed) == B_FLAG | UP_FLAG)
        #expect(ButtonRemap.nintendo.apply(A_FLAG | B_FLAG) == A_FLAG | B_FLAG) // both held: still both
        #expect(ButtonRemap.nintendo.apply(Y_FLAG) == X_FLAG)
        #expect(ButtonRemap.standard.apply(pressed) == pressed)
        #expect(ButtonRemap.nintendo.target(.a) == .b && ButtonRemap.nintendo.target(.menu) == .menu)
    }

    @Test func customMappingAndMenus() {
        let remap = ButtonRemap(targets: [.view: .home]) // View acts as the Home/PS button
        #expect(remap.apply(BACK_FLAG) == SPECIAL_FLAG)
        #expect(remap.apply(SPECIAL_FLAG) == SPECIAL_FLAG) // Home itself still works
        #expect(GamepadInput.command(for: ButtonRemap.nintendo.target(.b)) == .select) // B confirms in Nintendo layout
    }
}

struct AdaptiveTriggerTests {
    @Test func decodesTheCommonEffects() {
        let off = AdaptiveTriggerEffect(type: 0x05, bytes: Array(repeating: 0, count: 10))
        #expect(off.mode == .off)
        // Weapon (0x25): zones 2...6 active, strength bits 7 → full strength.
        let weapon = AdaptiveTriggerEffect(type: 0x25, bytes: [0x44, 0x00, 0x07, 0, 0, 0, 0, 0, 0, 0])
        #expect(weapon.mode == .weapon)
        #expect(abs(weapon.startPosition - 2 / 9) < 0.001 && abs(weapon.endPosition - 6 / 9) < 0.001)
        #expect(weapon.startStrength == 1)
        // Feedback per zone (0x21): zone 0 at strength 3 (bits 010 → (2+1)/8).
        let zoned = AdaptiveTriggerEffect(type: 0x21, bytes: [0x01, 0x00, 0x02, 0, 0, 0, 0, 0, 0, 0])
        #expect(zoned.mode == .positionalFeedback && zoned.positionalStrength[0] == 3 / 8)
        // A vibration with no frequency does nothing.
        #expect(AdaptiveTriggerEffect(type: 0x06, bytes: [0, 200, 0, 0, 0, 0, 0, 0, 0, 0]).mode == .off)
        #expect(AdaptiveTriggerEffect(type: 0x21, bytes: [1, 2]).mode == .off) // too short
    }
}

struct SessionControlTests {
    @Test func controlsAreRecognisedByUUIDNotTitle() {
        let resume = HostApp(fields: ["ID": "9", "AppTitle": "Resume", "UUID": "9a1c5a25-58fe-40e0-b9aa-7d3f00000001"])
        let monitor = HostApp(fields: ["ID": "8", "AppTitle": "Remote Monitor", "UUID": "9A1C5A25-58FE-40E0-B9AA-7D3F00000005"])
        let game = HostApp(fields: ["ID": "3", "AppTitle": "Resume", "UUID": "ABC"]) // a game that happens to be called Resume
        #expect(resume?.sessionControl == .join && resume?.sessionControl?.isContextual == true)
        #expect(monitor?.sessionControl == .monitor && monitor?.sessionControl?.isContextual == false)
        #expect(game?.sessionControl == nil)
    }
}

struct GameCustomizationTests {
    @Test func artFileNamesSurviveAnyTitle() {
        for id in ["hades ii", "half-life 2: episode one", "a/b+c?", "ポケモン", "????>>>"] { // "?>" encodes to "/" and "+"
            let key = GameCatalog.fileKey(gameID: id)
            #expect(!key.contains("/") && !key.contains("."))
            #expect(GameCatalog.gameID(fromFileKey: key) == id)
        }
    }
}

struct PinchProgressTests {
    @Test func fourFingersClosingReportTheirSpread() {
        let start = [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0), CGPoint(x: 0, y: 200), CGPoint(x: 200, y: 200)]
        let half = start.map { CGPoint(x: 50 + $0.x / 2, y: 50 + $0.y / 2) }
        #expect(abs((StreamGesture.pinchProgress(start: start, now: half) ?? 0) - 0.5) < 0.001)
        #expect(StreamGesture.pinchProgress(start: Array(start.prefix(3)), now: Array(half.prefix(3))) == nil) // three: a swipe
        #expect(StreamGesture.classify(start: start, end: half) == .pinch)
    }

    @Test func fourFingersNeverSwipe() {
        let start = [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0), CGPoint(x: 0, y: 200), CGPoint(x: 200, y: 200)]
        let down = start.map { CGPoint(x: $0.x, y: $0.y + 150) } // a pinch that drifted down, not closed enough
        #expect(StreamGesture.classify(start: start, end: down) == nil)
        let three = Array(start.prefix(3))
        #expect(StreamGesture.classify(start: three, end: three.map { CGPoint(x: $0.x, y: $0.y + 150) }) == .swipeDown)
        let natural = start.map { CGPoint(x: 30 + $0.x * 0.65, y: 30 + $0.y * 0.65) } // closed to 0.65: a trackpad pinch
        #expect(StreamGesture.classify(start: start, end: natural) == .pinch)
    }
}

struct CoverSlotTests {
    @MainActor @Test func eachShapeHasItsOwnSlotAndTheFirstCoverStaysTwoByThree() {
        let slots = CoverShape.allCases.map { GameCatalog.Artwork.cover($0) }
        #expect(Set(slots).count == CoverShape.allCases.count)
        #expect(!slots.contains(.hero))
        #expect(GameCatalog.Artwork.cover(.tall).rawValue == "cover") // covers saved before shapes existed
    }
}

struct PCStatusLineTests {
    private func line(_ status: HostStatus?, notResponding: Bool = false, fetching: Bool = false, failed: Bool = false,
                      saved: Bool = true, ago: Int? = 5) -> PCStatusLine {
        .make(status: status, isNotResponding: notResponding, isFetching: fetching, fetchFailed: failed,
              hasSavedGames: saved, checkedAgo: ago)
    }

    @Test func eachStateReadsAndRanksAsItShould() {
        #expect(line(nil).health == .checking)
        #expect(line(.offline) == .init(text: "Offline · showing saved games", health: .offline))
        #expect(line(.offline, saved: false).text == "Offline")
        #expect(line(.online(paired: false)).health == .problem)
        #expect(line(.online(paired: true)) == .init(text: "Up to date · checked 5s ago", health: .fine))
        #expect(line(.online(paired: true), ago: 1).text == "Up to date · checked just now")
        #expect(line(.online(paired: true), ago: 125).text == "Up to date · checked 2m ago")
        #expect(line(.online(paired: true), ago: nil).text == "Up to date")
        #expect(line(.online(paired: true), fetching: true).text == "Getting games…")
        #expect(line(.online(paired: true), failed: true).health == .problem)
    }

    @Test func oneMissedAnswerDoesntChangeTheButton() {
        let missed = line(.online(paired: true), notResponding: true)
        #expect(missed.health == .fine && missed.isWaiting && missed.text == "Not responding…")
    }

    @Test func theButtonShowsTheWorstPC() {
        #expect([PCStatusLine.Health.fine, .offline, .problem, .checking].max() == .offline)
        #expect([PCStatusLine.Health.fine, .checking].max() == .checking)
    }
}

struct LibraryColumnsTests {
    @Test func columnsAreEvenSoTheFoldFallsBetweenThem() {
        #expect(GamesView.columns(forWidth: 867) == 6) // Duo, open
        #expect(GamesView.columns(forWidth: 594) == 4) // Duo, closed
        #expect(GamesView.columns(forWidth: 200) == 2) // never fewer than two
        for width in stride(from: 200, through: 1400, by: 37) { #expect(GamesView.columns(forWidth: CGFloat(width)) % 2 == 0) }
    }
}

struct FoldAvoidanceTests {
    let screen = CGSize(width: 800, height: 600)

    @Test func aFoldAcrossLiftsContentAboveIt() {
        let avoid = FoldAvoidance(fold: CGRect(x: 0, y: 288, width: 800, height: 24), in: screen)
        #expect(avoid.lift == 312 && avoid.maxWidth == nil)
    }

    @Test func aFoldDownKeepsContentToItsLeft() {
        let avoid = FoldAvoidance(fold: CGRect(x: 388, y: 0, width: 24, height: 600), in: screen)
        #expect(avoid.lift == 0 && avoid.maxWidth == 388)
    }

    @Test func noFoldChangesNothing() {
        let avoid = FoldAvoidance(fold: nil, in: screen)
        #expect(avoid.lift == 0 && avoid.maxWidth == nil)
    }
}
