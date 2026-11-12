import Foundation
import SwiftData

/// A host PC the app has paired with. Identified by the host's serverinfo `uniqueid`.
@Model final class SavedHost {
    @Attribute(.unique) var uniqueID: String
    var name: String
    var address: String
    var httpsPort: Int = 47984
    /// The host's certificate from pairing (DER), pinned for HTTPS. Empty means never paired.
    var serverCert: Data = Data()
    /// The host's public address, for when the local one doesn't answer (away from home). Learned with STUN
    /// while on the home network, or typed in. Only ever used over pinned HTTPS.
    var remoteAddress: String?

    init(uniqueID: String, name: String, address: String, httpsPort: Int = 47984, serverCert: Data = Data()) {
        self.uniqueID = uniqueID
        self.name = name
        self.address = address
        self.httpsPort = httpsPort
        self.serverCert = serverCert
    }
}
