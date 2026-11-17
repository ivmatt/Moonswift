import SwiftData
import SwiftUI

/// Adding a host, one step at a time: what to have ready, finding the PC on the network (or typing its address), pairing
/// with a PIN, and done. Pairing is what saves it. Controller: A continues or picks, up/down move, B goes back a step
/// (on the first, closes).
struct AddHostView: View {
    /// The first host: its success page leads into the app (Get Started), which is revealed as the sheet goes.
    var isFirstHost = false

    private enum Step: Equatable {
        case ready, find, address, troubleshoot
        case pair(address: String, name: String)
        case done(hostID: String, name: String)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(GamepadInput.self) private var gamepad
    @Environment(GameCatalog.self) private var catalog
    @Query private var hosts: [SavedHost]
    @State private var step = Step.ready
    @State private var discovery = HostDiscovery()
    @State private var focus = 0
    @State private var address = ""
    @State private var isConnecting = false
    @State private var addressProblem: String?
    @FocusState private var isAddressFocused: Bool
    /// The games didn't come within a while of pairing: the success page shows without them.
    @State private var hasWaitedForGames = false

    /// Found PCs that aren't paired yet.
    private var found: [HostDiscovery.Found] {
        discovery.found.filter { found in !hosts.contains { $0.uniqueID == found.id } }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .ready: ready
                case .find: find
                case .address: enterAddress
                case .troubleshoot: troubleshooting
                case let .pair(address, name):
                    PairingView(address: address, name: name, onBack: back) { id, name in
                        withAnimation(.easeInOut(duration: 0.15)) { step = .done(hostID: id, name: name) }
                    }
                case let .done(hostID, name): done(hostID: hostID, name: name)
                }
            }
            .transition(.opacity) // a quick fade between steps: no slide, which felt slow
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .done = step { EmptyView() } else if step == .ready { Button("Cancel") { dismiss() } }
                    else { Button("Back", systemImage: "chevron.backward", action: back) }
                }
            }
            .tint(.primary)
            .onAppear { discovery.start() }
            .onDisappear { discovery.stop() }
            .buttonGuide(hints, reportsLayout: false)
            .onGamepad(handle)
        }
    }

    /// The button guide's hints for the step showing.
    private var hints: [(buttons: [ControllerHints.Button], label: String)] {
        switch step {
        case .ready: [([.a], "Continue"), ([.b], "Cancel")]
        case .find: [([.a], "Select"), ([.b], "Back")]
        case .address: [([.a], isAddressFocused ? "Connect" : addressProblem != nil ? "Troubleshooting" : "Type"), ([.b], "Back")]
        case .troubleshoot: [([.b], "Back")]
        case .pair: [([.b], "Back")]
        case .done: [([.a], isFirstHost ? "Get Started" : "Done")]
        }
    }

    private var title: String {
        switch step {
        case .ready: "Add a Host"
        case .find: "Find Your Host"
        case .address: "Manually Add Host"
        case .troubleshoot: "Troubleshooting"
        case .pair: "Pair"
        case .done: "All Set"
        }
    }

    // MARK: Steps

    private var ready: some View {
        ScrollView { // the Air in landscape is too short for it all
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "link")
                .font(.system(size: 88, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            HostChecklist()
        }
        .padding(28)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        }
        // At the sheet's bottom, whatever the page's length.
        .safeAreaInset(edge: .bottom) {
            Button { advance(to: .find) } label: { Text("Continue").frame(width: 200) }
                .buttonStyle(.glassProminent)
                .tint(.blue) // the page's white tint made it white on white
                .controlSize(.large)
                .focusRing(gamepad.isActive, cornerRadius: .infinity)
                .padding(.bottom, 16)
        }
    }

    private var find: some View {
        List {
            Section {
                ForEach(Array(found.enumerated()), id: \.element.id) { index, pc in
                    Button { advance(to: .pair(address: pc.address, name: pc.info.hostname)) } label: {
                        LabeledContent { Text(pc.address) } label: { Label(pc.info.hostname, systemImage: "desktopcomputer") }
                    }
                    .focusedRowBackground(gamepad.isActive && index == focus)
                }
                HStack(spacing: 10) {
                    ArcSpinner(size: 16).foregroundStyle(.secondary)
                    Text(found.isEmpty ? "Looking for hosts on your network…" : "Still looking…").foregroundStyle(.secondary)
                }
            } header: {
                if !found.isEmpty { Text("We found these hosts on your network") }
            } footer: {
                Button("Not showing up?") { advance(to: .address) }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
                    .tint(.blue)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .focusedRowBackground(gamepad.isActive && focus == found.count)
                    .padding(.top, 6)
            }
        }
    }

    private var enterAddress: some View {
        Form {
            Section {
                TextField("192.168.1.50", text: $address)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numbersAndPunctuation)
                    .focused($isAddressFocused)
                    .onSubmit(connect)
            } header: {
                Text("Your PC's IP address")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if let addressProblem { // what failed, and where to look, on one line
                        HStack {
                            Text(addressProblem).foregroundStyle(.red)
                            Spacer()
                            Button("Troubleshoot") { advance(to: .troubleshoot) }
                                .font(.footnote.weight(.semibold))
                                .tint(.blue)
                                .foregroundStyle(.tint)
                                .focusRing(gamepad.isActive && !isAddressFocused, cornerRadius: 6)
                        }
                        .padding(.bottom, 6)
                    }
                    Text("Where to find it").font(.footnote.weight(.semibold))
                    hint("1", "On Windows: Settings › Network & internet › your connection › Properties, then IPv4 address.")
                    hint("2", "Or open a terminal on the PC and run ipconfig.")
                    hint("3", "Or look in your router's list of connected devices.")
                    Text("Using a custom port? Add it after a colon, like 192.168.1.50:47989.").padding(.top, 2)
                }
                .padding(.top, 4)
            }
            Section {
                Button(action: connect) {
                    // The same height connecting or not: the spinner takes the text's place.
                    ZStack {
                        Text("Connect").opacity(isConnecting ? 0 : 1)
                        if isConnecting { ArcSpinner(size: 18) }
                    }
                    .frame(width: 200)
                }
                .buttonStyle(.glassProminent)
                .tint(.blue)
                .controlSize(.large)
                .disabled(isConnecting || address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .onAppear { isAddressFocused = true }
    }

    private func hint(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(number).font(.caption2.weight(.bold)).frame(width: 16, height: 16).background(.quaternary, in: .circle)
            Text(text)
        }
    }

    /// Laid out like Before you start: a large symbol, a heading, then the checks.
    private var troubleshooting: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 88, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)
                Text("Things to check:").font(.title2.bold())
                tip("checkmark.circle", "The address is four numbers separated by dots, like 192.168.1.50.")
                tip("power", "The PC is awake and its host is running.")
                tip("wifi", "Both are on the same network, not a guest network.")
                tip("shield", "The PC's firewall lets the host through: TCP 47984–47990 and UDP 47998–48010.")
                tip("arrow.clockwise", "Restarting the host on the PC, then trying again, can help.")
            }
            .padding(28)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol).frame(width: 28).foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true) // wraps, never "…"
        }
    }

    @ViewBuilder private func done(hostID: String, name: String) -> some View {
        let count = catalog.games(on: [hostID]).count
        if count == 0 && !hasWaitedForGames {
            // Paired: its games next, so the success page (and the app after it) has them.
            VStack(spacing: 16) {
                ArcSpinner(size: 34).foregroundStyle(.secondary)
                Text("Getting your games from \(name)…").font(.title3.weight(.semibold))
                Text("This only takes a moment.").foregroundStyle(.secondary)
            }
            .padding(28)
            .task {
                try? await Task.sleep(for: .seconds(15)) // a host that lists none, or is slow: on anyway
                withAnimation(.easeInOut(duration: 0.15)) { hasWaitedForGames = true }
            }
        } else {
            success(name: name, count: count)
        }
    }

    private func success(name: String, count: Int) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: isFirstHost ? 88 : 64)).foregroundStyle(.green)
            Text(isFirstHost ? "You're all set" : "\(name) is ready").font(isFirstHost ? .largeTitle.bold() : .title2.bold())
            Text(isFirstHost ? "\(name) is paired. " + (count > 0 ? "\(count) games and apps are waiting for you." : "Its games are on their way.")
                 : count > 0 ? "\(count) games and apps found." : "Loading its games…")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { dismiss() } label: { Text(isFirstHost ? "Get Started" : "Done").frame(width: 200) }
                .buttonStyle(.glassProminent)
                .tint(.blue) // the page's white tint made it white on white
                .controlSize(.large)
                .focusRing(gamepad.isActive, cornerRadius: .infinity)
                .padding(.top, 8)
        }
        .padding(28)
    }

    // MARK: Moving between steps

    private func advance(to next: Step) {
        focus = 0
        withAnimation(.easeInOut(duration: 0.15)) { step = next }
    }

    private func back() {
        isAddressFocused = false
        switch step {
        case .ready, .done: dismiss()
        case .find: advance(to: .ready)
        case .address, .pair:
            addressProblem = nil // a fresh start next time
            advance(to: .find)
        case .troubleshoot: withAnimation(.easeInOut(duration: 0.15)) { step = .address } // the failed address and its message stay
        }
    }

    private func connect() {
        let address = address.trimmingCharacters(in: .whitespaces)
        guard !isConnecting, !address.isEmpty else { return }
        isAddressFocused = false // the keyboard goes, so the result shows
        isConnecting = true
        addressProblem = nil
        Task {
            do {
                let info = try await fetchServerInfo(address: address)
                advance(to: .pair(address: address, name: info.hostname))
            } catch {
                addressProblem = "Couldn't connect to \(address)."
            }
            isConnecting = false
        }
    }

    private func handle(_ command: GamepadCommand) {
        if command == .back { return back() }
        switch step {
        case .ready: if command == .select { advance(to: .find) }
        case .find:
            switch command {
            case .up, .down: focus = FocusMove.next(focus, count: found.count + 1, columns: 1, command) // + Enter Address
            case .select:
                if found.indices.contains(focus) { advance(to: .pair(address: found[focus].address, name: found[focus].info.hostname)) }
                else { advance(to: .address) }
            default: break
            }
        case .address:
            if command == .select {
                if isAddressFocused { connect() } else if addressProblem != nil { advance(to: .troubleshoot) } else { isAddressFocused = true }
            }
        case .troubleshoot: break
        case .pair: break // the pairing screen handles A (Try Again)
        case .done: if command == .select { dismiss() }
        }
    }
}

/// What to have ready before adding a host: Add Host's first step, and the Hosts page while there are none.
struct HostChecklist: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Before you start, make sure that:").font(.title2.bold())
            check("power", "Your PC is on.")
            check("play.display", "A Sunshine-based host is installed and running on it (Vibepollo recommended).")
            check("wifi", "It's on the same network as this device. Remote access can be set up after pairing.")
        }
    }

    private func check(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol).frame(width: 28).foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true) // wraps, never "…"
        }
    }
}

/// Until a host is added, the whole app: what Moonswift is, and the way to add one.
struct WelcomeView: View {
    /// Set while the first host is being added, so the welcome (and its sheet) stays once it's paired, until Get Started.
    @Binding var isSettingUp: Bool
    /// After the first host's Get Started: Home, which then fades in from black.
    var reveal: () -> Void = {}
    @State private var isAdding = false
    @Query private var hosts: [SavedHost]
    @Environment(GamepadInput.self) private var gamepad

    var body: some View {
        ContentUnavailableView {
            Label("Welcome to Moonswift", systemImage: "play.tv")
        } description: {
            Text("Stream games from your PC. Start by adding it as a host.")
        } actions: {
            Button("Add a Host") { add() }
                .buttonStyle(.glassProminent)
                .tint(.blue)
                .controlSize(.large)
                .focusRing(gamepad.isActive, cornerRadius: .infinity)
        }
        // Gone once a host is paired: behind the success page it's black, and the app fades in from that.
        .opacity(hosts.isEmpty ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: hosts.isEmpty)
        // Centred on the whole screen: the Duo's status column on one side made it sit off to the other.
        .ignoresSafeArea()
        .background(Color(.systemBackground).ignoresSafeArea())
        .buttonGuide([([.a], "Add a Host")], reportsLayout: false)
        .onGamepad { if $0 == .select { add() } }
        // As it goes, the app is revealed (or, cancelled before pairing, the welcome stays).
        .sheet(isPresented: $isAdding, onDismiss: finish) {
            AddHostView(isFirstHost: true)
        }
    }

    private func add() {
        isSettingUp = true
        isAdding = true
    }

    /// Cancelled before pairing: the welcome stays. Paired: the app fades in.
    private func finish() {
        if hosts.isEmpty { isSettingUp = false } else { reveal() }
    }
}
