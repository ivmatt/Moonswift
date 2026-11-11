import Foundation
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

private func MoonswiftDERFromPEM(_ pem: String) -> Data? { der(fromPEM: pem) }
