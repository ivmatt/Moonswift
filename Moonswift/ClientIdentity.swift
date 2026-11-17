import Foundation
import Security

/// The app's own RSA key and self-signed certificate. The host learns the certificate during pairing
/// and from then on recognises the app by it on every HTTPS request.
nonisolated struct ClientIdentity: @unchecked Sendable { // Security types are immutable CF references
    let identity: SecIdentity
    let privateKey: SecKey
    let certificateDER: Data
    let certificatePEM: String
    let signature: Data

    /// Loaded from the keychain, or created on first use. Static lets are initialised once, thread-safely.
    static let current = Result { try loadOrCreate() }

    private static let keyTag = Data("com.moonswift.client-key".utf8)
    private static let certificateLabel = "Moonswift client certificate"

    private static func loadOrCreate() throws -> ClientIdentity {
        let key: SecKey
        if let existing = try findKey() {
            key = existing
        } else {
            SecItemDelete([kSecClass: kSecClassCertificate, kSecAttrLabel: certificateLabel] as CFDictionary) // can't match a new key
            key = try createKey()
        }

        let der: Data
        if let certificate = findCertificate() {
            der = SecCertificateCopyData(certificate) as Data
        } else {
            der = try makeSelfSignedCertificate(privateKey: key)
            guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
                throw ClientIdentityError("The generated certificate was rejected.")
            }
            let status = SecItemAdd([kSecClass: kSecClassCertificate, kSecValueRef: certificate,
                                     kSecAttrLabel: certificateLabel] as CFDictionary, nil)
            guard status == errSecSuccess else { throw ClientIdentityError("Couldn't store the certificate (\(status)).") }
        }

        // The keychain links a certificate and a key with the same public key into an identity.
        guard let identity = findIdentity(certificateDER: der) else {
            throw ClientIdentityError("The keychain didn't link the certificate to its key.")
        }
        guard let signature = certificateSignature(fromDER: der) else {
            throw ClientIdentityError("Couldn't read the certificate's signature.")
        }
        return ClientIdentity(identity: identity, privateKey: key, certificateDER: der,
                              certificatePEM: pem(fromDER: der), signature: signature)
    }

    /// nil only when there's no key yet. Any other keychain error (locked, say) throws: replacing the key on a
    /// passing error would unpair every host.
    private static func findKey() throws -> SecKey? {
        var item: CFTypeRef?
        let query = [kSecClass: kSecClassKey, kSecAttrApplicationTag: keyTag,
                     kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecReturnRef: true] as CFDictionary
        let status = SecItemCopyMatching(query, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item else { throw ClientIdentityError("Couldn't read the key (\(status)).") }
        return (item as! SecKey)
    }

    private static func createKey() throws -> SecKey {
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048, // same as moonlight-ios mkcert.c
                          kSecPrivateKeyAttrs: [kSecAttrIsPermanent: true, kSecAttrApplicationTag: keyTag]] as CFDictionary
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes, &error) else {
            throw ClientIdentityError(error?.takeRetainedValue().localizedDescription ?? "Key generation failed.")
        }
        return key
    }

    private static func findCertificate() -> SecCertificate? {
        var item: CFTypeRef?
        let query = [kSecClass: kSecClassCertificate, kSecAttrLabel: certificateLabel, kSecReturnRef: true] as CFDictionary
        guard SecItemCopyMatching(query, &item) == errSecSuccess, let item else { return nil }
        return (item as! SecCertificate)
    }

    private static func findIdentity(certificateDER: Data) -> SecIdentity? {
        var items: CFTypeRef?
        let query = [kSecClass: kSecClassIdentity, kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitAll] as CFDictionary
        guard SecItemCopyMatching(query, &items) == errSecSuccess, let identities = items as? [SecIdentity] else { return nil }
        return identities.first { identity in
            var certificate: SecCertificate?
            SecIdentityCopyCertificate(identity, &certificate)
            return certificate.map { SecCertificateCopyData($0) as Data } == certificateDER
        }
    }
}

nonisolated struct ClientIdentityError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = "Client certificate problem: \(message)" }
}

/// A self-signed X.509 v3 certificate like moonlight-ios's mkcert.c: CN "NVIDIA GameStream Client",
/// SHA-256 with RSA, valid 20 years. iOS can't create certificates, so the DER is written by hand.
nonisolated func makeSelfSignedCertificate(privateKey: SecKey, now: Date = .now) throws -> Data {
    guard let publicKey = SecKeyCopyPublicKey(privateKey),
          let publicKeyBytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? // PKCS#1 RSAPublicKey
    else { throw ClientIdentityError("Couldn't read the public key.") }

    let sha256WithRSA = DER.sequence(DER.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]), DER.null)
    let rsaEncryption = DER.sequence(DER.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]), DER.null)
    let name = DER.sequence(DER.set(DER.sequence(DER.oid([0x55, 0x04, 0x03]), DER.utf8String("NVIDIA GameStream Client"))))
    let validity = DER.sequence(DER.time(now), DER.time(now.addingTimeInterval(20 * 365 * 24 * 60 * 60)))

    var serial = (0..<8).map { _ in UInt8.random(in: .min ... .max) }
    serial[0] = serial[0] & 0x7F | 0x01 // positive, and minimally encoded

    let tbs = DER.sequence(
        Data([0xA0, 0x03, 0x02, 0x01, 0x02]), // [0] version: v3
        DER.tlv(0x02, Data(serial)),
        sha256WithRSA,
        name, // issuer = subject: self-signed
        validity,
        name,
        DER.sequence(rsaEncryption, DER.bitString(publicKeyBytes))
    )
    var error: Unmanaged<CFError>?
    guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, &error) as Data? else {
        throw ClientIdentityError(error?.takeRetainedValue().localizedDescription ?? "Signing failed.")
    }
    return DER.sequence(tbs, sha256WithRSA, DER.bitString(signature))
}

/// The certificate's signature bytes (the last of its three parts). Pairing hashes both sides' signatures.
nonisolated func certificateSignature(fromDER der: Data) -> Data? {
    guard let outer = DER.elements(der), outer.count == 1, outer[0].tag == 0x30,
          let parts = DER.elements(outer[0].content), parts.count == 3,
          parts[2].tag == 0x03, parts[2].content.count > 1
    else { return nil }
    return Data(parts[2].content.dropFirst()) // first byte is the bit string's "unused bits" count
}

nonisolated func pem(fromDER der: Data) -> String {
    let body = der.base64EncodedString(options: .lineLength64Characters).replacingOccurrences(of: "\r\n", with: "\n")
    return "-----BEGIN CERTIFICATE-----\n\(body)\n-----END CERTIFICATE-----\n"
}

nonisolated func der(fromPEM pem: String) -> Data? {
    let body = pem.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
    return Data(base64Encoded: body)
}

/// Just enough DER (the binary encoding of X.509) to write one certificate and read signatures back.
nonisolated enum DER {
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var length = [UInt8]()
        if content.count < 0x80 {
            length = [UInt8(content.count)]
        } else {
            var n = content.count
            while n > 0 { length.insert(UInt8(n & 0xFF), at: 0); n >>= 8 }
            length.insert(0x80 | UInt8(length.count), at: 0)
        }
        return Data([tag] + length) + content
    }

    static func sequence(_ parts: Data...) -> Data { tlv(0x30, parts.reduce(Data(), +)) }
    static func set(_ parts: Data...) -> Data { tlv(0x31, parts.reduce(Data(), +)) }
    static func oid(_ encoded: [UInt8]) -> Data { tlv(0x06, Data(encoded)) }
    static func utf8String(_ string: String) -> Data { tlv(0x0C, Data(string.utf8)) }
    static func bitString(_ bytes: Data) -> Data { tlv(0x03, Data([0]) + bytes) }
    static let null = Data([0x05, 0x00])

    /// UTCTime until 2049, GeneralizedTime after, as X.509 requires.
    static func time(_ date: Date) -> Data {
        let year = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date).year!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = year < 2050 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return tlv(year < 2050 ? 0x17 : 0x18, Data(formatter.string(from: date).utf8))
    }

    /// Splits DER bytes into their top-level elements, or nil if they're malformed.
    static func elements(_ data: Data) -> [(tag: UInt8, raw: Data, content: Data)]? {
        let bytes = [UInt8](data)
        var elements: [(tag: UInt8, raw: Data, content: Data)] = []
        var i = 0
        while i < bytes.count {
            guard i + 2 <= bytes.count else { return nil }
            var length = Int(bytes[i + 1])
            var header = 2
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard (1...4).contains(count), i + 2 + count <= bytes.count else { return nil }
                length = bytes[(i + 2)..<(i + 2 + count)].reduce(0) { $0 << 8 | Int($1) }
                header += count
            }
            guard i + header + length <= bytes.count else { return nil }
            elements.append((bytes[i], Data(bytes[i..<(i + header + length)]), Data(bytes[(i + header)..<(i + header + length)])))
            i += header + length
        }
        return elements
    }
}
