import Foundation
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
        #expect(try serverInfoURL(for: " 10.0.4.20 ").absoluteString == "http://10.0.4.20:47989/serverinfo")
        #expect(try serverInfoURL(for: "10.0.4.20:1234").absoluteString == "http://10.0.4.20:1234/serverinfo")
        #expect(throws: ServerInfoError.invalidAddress) { try serverInfoURL(for: "10.0.4.20/x") }
        #expect(throws: ServerInfoError.invalidAddress) { try serverInfoURL(for: "") }
    }
}
