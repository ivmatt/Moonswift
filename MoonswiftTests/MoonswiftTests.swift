import CoreGraphics
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
        var config = StreamSession.makeStreamConfiguration(launch: launch, width: 1920, height: 1080, fps: 60, bitrate: 20_000)
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

private func MoonswiftDERFromPEM(_ pem: String) -> Data? { der(fromPEM: pem) }
