import Foundation
import SwiftData

/// A host PC the app has paired with. Identified by the host's serverinfo `uniqueid`.
@Model final class SavedHost {
    @Attribute(.unique) var uniqueID: String
    /// The PC's own name (its hostname), kept current by status checks.
    var name: String
    /// A name chosen in this app, which wins over the PC's own.
    var customName: String?
    var displayName: String { customName ?? name }
    var address: String
    var httpsPort: Int = 47984
    /// The host's certificate from pairing (DER), pinned for HTTPS. Empty means never paired.
    var serverCert: Data = Data()
    /// The host's public address, for when the local one doesn't answer (away from home). Learned with STUN
    /// while on the home network, or typed in. Only ever used over pinned HTTPS.
    var remoteAddress: String?
    /// The network adapter this device reaches the PC through, for Wake-on-LAN. Learned while it's online and paired.
    var macAddress: String?

    init(uniqueID: String, name: String, address: String, httpsPort: Int = 47984, serverCert: Data = Data()) {
        self.uniqueID = uniqueID
        self.name = name
        self.address = address
        self.httpsPort = httpsPort
        self.serverCert = serverCert
    }

    /// Saves a pairing. A PC paired before keeps what's known about it here: your name, its remote address and MAC.
    /// (Inserting the same uniqueID would replace the whole record, blanking those.)
    static func remember(uniqueID: String, name: String, address: String, httpsPort: Int, serverCert: Data, in context: ModelContext) {
        let saved = FetchDescriptor<SavedHost>(predicate: #Predicate { $0.uniqueID == uniqueID })
        guard let host = try? context.fetch(saved).first else {
            return context.insert(SavedHost(uniqueID: uniqueID, name: name, address: address, httpsPort: httpsPort, serverCert: serverCert))
        }
        host.name = name
        host.address = address
        host.httpsPort = httpsPort
        host.serverCert = serverCert
    }
}
