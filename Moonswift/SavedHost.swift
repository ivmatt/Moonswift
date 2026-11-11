import SwiftData

/// A host PC the user chose to keep. Identified by the host's serverinfo `uniqueid`.
@Model final class SavedHost {
    @Attribute(.unique) var uniqueID: String
    var name: String
    var address: String

    init(uniqueID: String, name: String, address: String) {
        self.uniqueID = uniqueID
        self.name = name
        self.address = address
    }
}
