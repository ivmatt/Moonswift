import CommonCrypto
import CryptoKit
import Foundation
import Security

nonisolated enum PairingError: LocalizedError {
    case declined
    case alreadyInProgress
    case wrongPIN
    case badServerCertificate
    case malformedReply

    var errorDescription: String? {
        switch self {
        case .declined: "Your host declined pairing."
        case .alreadyInProgress: "Your host is already pairing with another device. Try again in a moment."
        case .wrongPIN: "That PIN didn't match. Try again with the new one."
        case .badServerCertificate: "Couldn't verify your host. Try again."
        case .malformedReply: "Pairing didn't go through. Try again."
        }
    }
}

/// The GameStream PIN pairing handshake, step for step as moonlight-ios's PairManager does it.
/// Both sides prove they know the PIN without sending it, and swap certificates.
nonisolated enum Pairing {
    struct Paired {
        let info: ServerInfo
        let serverCert: Data // DER, pinned from now on
    }

    // shortcut: fixed like moonlight-ios; Vibepollo identifies clients by certificate, not this value.
    static let uniqueID = "0123456789ABCDEF"
    private static let deviceName = "Moonswift"

    static func generatePIN() -> String {
        String(format: "%04d", Int.random(in: 0...9999))
    }

    /// Runs off the main actor: first use generates a 2048-bit RSA key, which takes a moment.
    @concurrent static func pair(address: String, pin: String) async throws -> Paired {
        let client = try ClientIdentity.current.get()
        let info = try await fetchServerInfo(address: address)

        // 1. Send a salt and our certificate. The host holds this request open until the PIN is typed
        //    into its web UI (it expires pending pairings after 10 minutes), then returns its certificate.
        let salt = randomBytes(16)
        let key = Data(SHA256.hash(data: salt + Data(pin.utf8)).prefix(16)) // AES-128 key from salt + PIN
        let certReply = try await step(address, timeout: 10 * 60, [
            "phrase": "getservercert", "salt": salt.hex, "clientcert": Data(client.certificatePEM.utf8).hex,
        ])
        guard let plainCert = certReply["plaincert"], !plainCert.isEmpty else { throw PairingError.alreadyInProgress }
        guard let serverPEM = Data(hex: plainCert).flatMap({ String(data: $0, encoding: .utf8) }),
              let serverDER = der(fromPEM: serverPEM),
              let serverCert = SecCertificateCreateWithData(nil, serverDER as CFData),
              let serverKey = SecCertificateCopyKey(serverCert),
              let serverSignature = certificateSignature(fromDER: serverDER)
        else { throw PairingError.badServerCertificate }

        // 2. Send an encrypted random challenge. The host answers with its hash proof and a challenge for us.
        let challenge = randomBytes(16)
        let challengeReply = try await step(address, ["clientchallenge": try aes128ECB(challenge, key: key, encrypt: true).hex])
        guard let encrypted = challengeReply["challengeresponse"].flatMap(Data.init(hex:)),
              let decrypted = try? aes128ECB(encrypted, key: key, encrypt: false), decrypted.count >= 48
        else { throw PairingError.malformedReply }
        let serverHash = Data(decrypted.prefix(32))
        let serverChallenge = Data(decrypted[32..<48])

        // 3. Answer the host's challenge with our hash proof, using our certificate's signature and a secret.
        let clientSecret = randomBytes(16)
        let clientHash = Data(SHA256.hash(data: serverChallenge + client.signature + clientSecret))
        let secretReply = try await step(address, ["serverchallengeresp": try aes128ECB(clientHash, key: key, encrypt: true).hex])
        guard let pairingSecret = secretReply["pairingsecret"].flatMap(Data.init(hex:)), pairingSecret.count > 16
        else { throw PairingError.malformedReply }
        let serverSecret = Data(pairingSecret.prefix(16))
        let serverSecretSignature = Data(pairingSecret.dropFirst(16))

        // The host signed its secret with the key behind the certificate it sent...
        guard SecKeyVerifySignature(serverKey, .rsaSignatureMessagePKCS1v15SHA256, serverSecret as CFData,
                                    serverSecretSignature as CFData, nil)
        else { throw PairingError.badServerCertificate }
        // ...and its hash only matches ours if it derived the same AES key, i.e. saw the same PIN.
        guard Data(SHA256.hash(data: challenge + serverSignature + serverSecret)) == serverHash
        else { throw PairingError.wrongPIN }

        // 4. Prove we hold our private key: send our secret signed with it.
        var error: Unmanaged<CFError>?
        guard let signedSecret = SecKeyCreateSignature(client.privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                                       clientSecret as CFData, &error) as Data?
        else { throw ClientIdentityError(error?.takeRetainedValue().localizedDescription ?? "Signing failed.") }
        _ = try await step(address, ["clientpairingsecret": (clientSecret + signedSecret).hex])

        // 5. Over HTTPS with both certificates: confirms the host now trusts us.
        let tls = PairedTLS(serverCert: serverDER, identity: client.identity)
        _ = try await step(address, httpsPort: info.httpsPort, tls: tls, ["phrase": "pairchallenge"])

        return Paired(info: info, serverCert: serverDER)
    }

    /// One /pair request. Every step must come back with `<paired>1</paired>`.
    private static func step(_ address: String, timeout: TimeInterval = 5, httpsPort: Int? = nil, tls: PairedTLS? = nil,
                             _ parameters: KeyValuePairs<String, String>) async throws -> [String: String] {
        let query = [URLQueryItem(name: "uniqueid", value: uniqueID),
                     URLQueryItem(name: "devicename", value: deviceName),
                     URLQueryItem(name: "updateState", value: "1")]
            + parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        let url = try hostURL(for: address, path: "/pair", httpsPort: httpsPort, query: query)
        let fields = try await hostRequest(url, timeout: timeout, tls: tls)
        guard fields["paired"] == "1" else { throw PairingError.declined }
        return fields
    }

    static func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) }) // SystemRandomNumberGenerator is cryptographically secure
    }
}

/// AES-128 in ECB mode without padding, which is what GameStream pairing uses (moonlight-ios CryptoManager).
nonisolated func aes128ECB(_ data: Data, key: Data, encrypt: Bool) throws -> Data {
    guard key.count == kCCKeySizeAES128, data.count.isMultiple(of: kCCBlockSizeAES128) else { throw PairingError.malformedReply }
    var output = Data(count: data.count)
    var written = 0
    let status = output.withUnsafeMutableBytes { out in
        data.withUnsafeBytes { input in
            key.withUnsafeBytes { keyBytes in
                CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress, key.count, nil, input.baseAddress, data.count, out.baseAddress, data.count, &written)
            }
        }
    }
    guard status == kCCSuccess else { throw PairingError.malformedReply }
    return output
}

nonisolated extension Data {
    var hex: String { map { String(format: "%02X", $0) }.joined() }

    init?(hex: String) {
        guard hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
