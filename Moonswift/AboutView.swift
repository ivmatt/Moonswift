import SwiftUI

/// Version, license and the open-source code inside the app, whose licenses ask for their notices to ship with it.
/// A controller moves with up/down, opens with A and goes back with B.
struct AboutView: View {
    struct Component: Hashable {
        let name: String
        let license: String
        let file: String // in the app bundle, from Moonswift/Licenses
    }

    // shortcut: the repository must be public before release, since GPLv3 promises the source to everyone who gets the app.
    static let sourceURL = URL(string: "https://github.com/ivmatt/Moonswift")!
    static let components = [
        Component(name: "moonlight-common-c", license: "GPLv3", file: "License-moonlight-common-c"),
        Component(name: "ENet", license: "MIT", file: "License-ENet"),
        Component(name: "nanors", license: "MIT", file: "License-nanors"),
        Component(name: "Mbed TLS", license: "Apache 2.0", file: "License-MbedTLS"),
    ]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(GamepadInput.self) private var gamepad
    @State private var focus = 0
    @State private var opened: Component?

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: version)
            } footer: {
                Text("Moonswift is free software under the GNU General Public License, version 3. You may share and change it under the same license.")
            }
            Section {
                row(0) { Button("Source Code") { openURL(Self.sourceURL) } }
            }
            Section("Open-Source Components") {
                ForEach(Array(Self.components.enumerated()), id: \.element) { index, component in
                    row(index + 1) {
                        Button { opened = component } label: {
                            LabeledContent(component.name, value: component.license).foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
        .navigationTitle("About")
        .navigationDestination(item: $opened) { LicenseText(component: $0) }
        .onGamepad { command in
            switch command {
            case .up, .down: focus = FocusMove.next(focus, count: Self.components.count + 1, columns: 1, command)
            case .select: if focus == 0 { openURL(Self.sourceURL) } else { opened = Self.components[focus - 1] }
            case .back: dismiss()
            default: break
            }
        }
    }

    private func row(_ index: Int, @ViewBuilder content: () -> some View) -> some View {
        content().listRowBackground(gamepad.isActive && focus == index ? Color.accentColor.opacity(0.25)
                                                                       : Color(.secondarySystemGroupedBackground))
    }
}

private struct LicenseText: View {
    let component: AboutView.Component
    @Environment(\.dismiss) private var dismiss

    private var text: String {
        Bundle.main.url(forResource: component.file, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "License text missing from this build."
    }

    var body: some View {
        ScrollView {
            Text(text).font(.caption.monospaced()).textSelection(.enabled).padding()
        }
        .navigationTitle(component.name)
        .onGamepad { if $0 == .back { dismiss() } }
    }
}
