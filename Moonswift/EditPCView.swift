import SwiftData
import SwiftUI

/// One PC's settings: its name in this app and its home and remote addresses. Addresses are checked before saving
/// (the same PC must answer there). The place for any future per-PC settings. A controller moves with up/down,
/// A edits a field (or removes), X saves, B stops editing or closes.
struct EditPCView: View {
    let host: SavedHost
    /// Remove Host: the Hosts page asks to confirm, and unpairs.
    var remove: () -> Void = {}

    private enum Field: CaseIterable { case name, address, remote, remove }
    /// Why an address can't simply be saved.
    private enum Problem { case differentPC(String), unreachable(String) }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(GamepadInput.self) private var gamepad
    @State private var name = ""
    @State private var address = ""
    @State private var remote = ""
    @State private var isSaving = false
    @State private var menu: MenuSpec?
    @State private var focus = 0
    @FocusState private var typing: Field?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    row(.name) { TextField("Name", text: $name, prompt: Text(host.name)) }
                } header: {
                    Text("Name")
                } footer: {
                    Text("Leave empty to use \(host.name).")
                }
                Section {
                    row(.address) { addressField("IP address or name", text: $address) }
                } header: {
                    Text("Home Network")
                } footer: {
                    Text("The host's address on your home network.")
                }
                Section {
                    row(.remote) { addressField("Public IP address", text: $remote) }
                } header: {
                    Text("Remote")
                } footer: {
                    Text("Used securely when the host isn't reachable at home. Found automatically while you're home. Leave empty to remove.")
                }
                Section {
                    row(.remove) {
                        Button("Remove Host", role: .destructive) { removeHost() }
                    }
                }
            }
            .barTitle(host.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                // Words like every other sheet's Done; a spinner while the addresses are checked.
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving { ArcSpinner(size: 18) } else { Button("Save") { Task { await save() } } }
                }
            }
            .onAppear {
                name = host.customName ?? ""
                address = host.address
                remote = host.remoteAddress ?? ""
            }
            .onGamepad { command in
                let current = Field.allCases[focus]
                switch command {
                case .up, .down: focus = FocusMove.next(focus, count: Field.allCases.count, columns: 1, command)
                case .select: if current == .remove { removeHost() } else { typing = current }
                case .alternate: if !isSaving { Task { await save() } }
                case .back: if typing != nil { typing = nil } else { dismiss() }
                default: break
                }
            }
            .buttonGuide([([.a], "Select"), ([.x], "Save"), ([.b], "Cancel")], reportsLayout: false)
            .actionMenu($menu)
        }
    }

    private func removeHost() {
        dismiss()
        remove()
    }

    private func row(_ field: Field, @ViewBuilder content: () -> some View) -> some View {
        content()
            .focused($typing, equals: field)
            .listRowBackground(gamepad.isActive && Field.allCases[focus] == field ? Color.accentColor.opacity(0.25)
                                                                                  : Color(.secondarySystemGroupedBackground))
    }

    private func addressField(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .keyboardType(.numbersAndPunctuation)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    private func save() async {
        let name = name.trimmingCharacters(in: .whitespaces)
        let address = address.trimmingCharacters(in: .whitespaces)
        let remote = remote.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return menu = .error("Enter the host's address on your home network.") }
        isSaving = true
        defer { isSaving = false }

        var unreachable: [String] = []
        for (candidate, isRemote) in [(address, false), (remote, true)]
        where !candidate.isEmpty && candidate != (isRemote ? host.remoteAddress : host.address) {
            switch await problem(with: candidate, isRemote: isRemote) {
            case .differentPC(let message)?: return menu = .error(message)
            case .unreachable(let message)?: unreachable.append(message)
            case nil: break
            }
        }
        func store() {
            host.customName = name.isEmpty ? nil : name
            host.address = address
            host.remoteAddress = remote.isEmpty ? nil : remote
            try? context.save()
            dismiss()
        }
        guard unreachable.isEmpty else {
            // It may just be off or unreachable from here: let the user keep the address anyway.
            return menu = MenuSpec(title: "Couldn't reach \(host.displayName)", message: unreachable.joined(separator: "\n\n"),
                                   actions: [.init(title: "Save Anyway") { store() }])
        }
        store()
    }

    /// Checks that this PC (same unique ID) answers at `address`: over pinned HTTPS once paired, else plain HTTP at home.
    private func problem(with address: String, isRemote: Bool) async -> Problem? {
        do {
            let info = host.serverCert.isEmpty && !isRemote
                ? try await fetchServerInfo(address: address)
                : try await fetchPairedServerInfo(address: address, httpsPort: host.httpsPort, serverCert: host.serverCert)
            return info.uniqueID == host.uniqueID ? nil : .differentPC("\(address) is a different host (\(info.hostname)).")
        } catch {
            return .unreachable("\(address): \(error.localizedDescription)")
        }
    }
}
