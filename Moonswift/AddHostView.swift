import SwiftData
import SwiftUI

/// Adding a host, one step at a time: what to have ready, finding the PC on the network (or typing its address), pairing
/// with a PIN, and done. Pairing is what saves it. Controller: A continues or picks, up/down move, B goes back a step
/// (on the first, closes).
struct AddHostView: View {
    /// The first host: its success page leads into the app (Get Started), which is revealed as the sheet goes.
    var isFirstHost = false

    private enum Step: Hashable {
        case ready, find, address, troubleshoot
        case pair(address: String, name: String)
        case done(hostID: String, name: String)
        case setup
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
    /// Getting Started's page, and the host it follows (Back from its first page returns to that success page).
    @State private var setupPage = 0
    /// The way the steps (and Getting Started's pages) last moved: their slide follows it.
    @State private var isForward = true
    @State private var paired: (hostID: String, name: String)?
    /// The whole screen or sheet, safe areas included, so a keyboard or toolbar doesn't change the layout.
    @State private var window = CGSize.zero
    private var iconSize: CGFloat { window.isShort ? 48 : 88 }

    /// Found PCs that aren't paired yet.
    private var found: [HostDiscovery.Found] {
        discovery.found.filter { found in !hosts.contains { $0.uniqueID == found.id } }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                stepView
                    .id(step) // a new view for each step, so it slides in as the last slides out
                    .transition(Self.slide(forward: isForward))
            }
            .onGeometryChange(for: CGSize.self) { proxy in
                CGSize(width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                       height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom)
            } action: { window = $0 }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    switch step {
                    case .ready: Button("Cancel") { dismiss() }
                    case .done: EmptyView()
                    default: Button("Back", systemImage: "chevron.backward", action: back)
                    }
                }
            }
            .tint(.primary)
            // A swipe down closes it until the PIN shows; from then on it's seen through (pairing, then Getting Started).
            .interactiveDismissDisabled(!isClosable)
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
        case .done: [([.a], isFirstHost ? "Continue" : "Done")]
        case .setup: []
        }
    }

    @ViewBuilder private var stepView: some View {
        switch step {
        case .ready: ready
        case .find: find
        case .address: enterAddress
        case .troubleshoot: troubleshooting
        case let .pair(address, name):
            PairingView(address: address, name: name, onBack: back) { id, name in
                advance(to: .done(hostID: id, name: name))
            }
        case let .done(hostID, name): done(hostID: hostID, name: name)
        case .setup:
            FirstRunSetup(pageIndex: $setupPage, isForward: $isForward, hostID: paired?.hostID ?? "", window: window,
                          backFromFirst: back) { dismiss() }
        }
    }

    /// Forward: the next step slides in from the trailing edge as this one leaves by the leading; back, the reverse.
    static func slide(forward: Bool) -> AnyTransition {
        .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    /// Before pairing starts: a swipe down (or B on the first page) closes it.
    private var isClosable: Bool {
        switch step {
        case .ready, .find, .address, .troubleshoot: true
        case .pair, .done, .setup: false
        }
    }

    private var title: String {
        switch step {
        case .ready: "Add a Host"
        case .find: "Find Your Host"
        case .address: "Manually Add Host"
        case .troubleshoot: "Troubleshooting"
        case .pair: "Pair"
        case .done: isFirstHost ? "Paired" : "All Set"
        case .setup: "Getting Started"
        }
    }

    // MARK: Steps

    private var ready: some View {
        ScrollView { // the Air in landscape is too short for it all
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "link")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            HostChecklist()
        }
        .padding(28)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        }
        // At the sheet's bottom, whatever the page's length; the page blurs and fades under it.
        .safeAreaBar(edge: .bottom) {
            Button { advance(to: .find) } label: { Text("Continue").frame(width: 200) }
                .buttonStyle(.glassProminent)
                .tint(.blue) // the page's white tint made it white on white
                .controlSize(.large)
                .focusRing(gamepad.isActive, cornerRadius: .infinity)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .fadingBarBackground()
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
                .frame(maxWidth: .infinity) // centred
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
                    .font(.system(size: iconSize, weight: .semibold))
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
        HStack(alignment: .center, spacing: 14) { // like Before you start: centred on its text, in one column
            Image(systemName: symbol).frame(width: 30).foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true) // wraps, never "…"
        }
    }

    @ViewBuilder private func done(hostID: String, name: String) -> some View {
        let count = catalog.games(on: [hostID]).count
        if count == 0 && !hasWaitedForGames && !isFirstHost { // the first host's are fetched during Getting Started
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
            Image(systemName: "checkmark.circle.fill").font(.system(size: min(iconSize, isFirstHost ? 88 : 64))).foregroundStyle(.green)
            // "All set" only for another host: the first one has a few settings to go.
            Text(isFirstHost ? "\(name) is paired" : "You're all set").font(isFirstHost ? .largeTitle.bold() : .title2.bold())
            Text(isFirstHost ? "While we grab your games, let's go through a few quick settings."
                 : "\(name) is ready" + (count > 0 ? " with \(count) games and apps." : "."))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { finishPairing() } label: { Text(isFirstHost ? "Continue" : "Done").frame(width: 200) }
                .buttonStyle(.glassProminent)
                .tint(.blue) // the page's white tint made it white on white
                .controlSize(.large)
                .focusRing(gamepad.isActive, cornerRadius: .infinity)
                .padding(.top, 8)
        }
        .padding(28)
    }

    // MARK: Moving between steps

    private func finishPairing() {
        guard isFirstHost else { return dismiss() }
        if case let .done(hostID, name) = step { paired = (hostID, name) }
        setupPage = 0
        advance(to: .setup)
    }

    private func advance(to next: Step, forward: Bool = true) {
        focus = 0
        isForward = forward
        withAnimation(.easeInOut(duration: 0.3)) { step = next }
    }

    private func back() {
        isAddressFocused = false
        switch step {
        case .ready: dismiss()
        case .done: break // paired: the flow goes on from here
        case .setup:
            if setupPage > 0 { isForward = false; withAnimation(.easeInOut(duration: 0.3)) { setupPage -= 1 } }
            else if let paired { advance(to: .done(hostID: paired.hostID, name: paired.name), forward: false) }
        case .find: advance(to: .ready, forward: false)
        case .address, .pair:
            addressProblem = nil // a fresh start next time
            advance(to: .find, forward: false)
        case .troubleshoot: advance(to: .address, forward: false) // the failed address and its message stay
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
        case .done: if command == .select { finishPairing() }
        case .setup: break // its own pages handle the controller
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
            check("gamecontroller", "Your games are added in the host's app list. Moonswift shows what's there, so games "
                  + "that aren't added won't appear here.", isImportant: true)
        }
    }

    /// `isImportant`: easy to miss, and Moonswift looks broken without it (games not added on the host).
    private func check(_ symbol: String, _ text: String, isImportant: Bool = false) -> some View {
        // Centred on its point, however many lines it wraps to; all in one column, whatever each symbol's width.
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol).frame(width: 30).foregroundStyle(isImportant ? Color.orange : .secondary)
            Text(text)
                .fontWeight(isImportant ? .semibold : nil)
                .fixedSize(horizontal: false, vertical: true) // wraps, never "…"
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
        welcome
            .background(Color(.systemBackground).ignoresSafeArea())
            .buttonGuide([([.a], "Add a Host")], reportsLayout: false)
            .onGamepad { if $0 == .select { add() } }
            // As it goes, the app fades in from black (or, cancelled before pairing, the welcome stays).
            .addHostCover(isPresented: $isAdding, isFirstHost: true, onDismiss: finish)
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            AppIconMark(size: 132)
            VStack(spacing: 10) {
                Text("Welcome to Moonswift").font(.largeTitle.bold())
                Text("Stream games from your PC. Start by adding it as a host.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Add a Host") { add() }
                .font(.title3.weight(.semibold))
                .buttonStyle(.glassProminent)
                .tint(.blue)
                .controlSize(.large)
                .focusRing(gamepad.isActive, cornerRadius: .infinity)
                .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Gone once a host is paired: behind the sheet it's black, and the app fades in from that.
        .opacity(hosts.isEmpty ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: hosts.isEmpty)
        // Centred on the whole screen: the Duo's status column on one side made it sit off to the other.
        .ignoresSafeArea()
    }

    private func add() {
        isSettingUp = true
        isAdding = true
    }

    /// Cancelled before pairing: the welcome stays. Paired: the app fades in from black.
    private func finish() {
        if hosts.isEmpty { isSettingUp = false } else { reveal() }
    }
}

extension View {
    /// Add Host: the whole screen on an iPhone, where a sheet only wastes room; a sheet on the iPad's big screen.
    @ViewBuilder func addHostCover(isPresented: Binding<Bool>, isFirstHost: Bool = false,
                                   onDismiss: (() -> Void)? = nil) -> some View {
        if UIDevice.current.userInterfaceIdiom == .phone {
            fullScreenCover(isPresented: isPresented, onDismiss: onDismiss) { AddHostView(isFirstHost: isFirstHost) }
        } else {
            sheet(isPresented: isPresented, onDismiss: onDismiss) { AddHostView(isFirstHost: isFirstHost) }
        }
    }

    /// Behind a bar of buttons at a page's bottom: the page blurs and fades into the sheet's colour under it, starting
    /// a little above it, rather than running into the buttons or ending at a hard edge.
    func fadingBarBackground() -> some View {
        background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color(.systemBackground).opacity(0.55)
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.45)],
                                 startPoint: .top, endPoint: .bottom))
            .padding(.top, -28)
            .ignoresSafeArea()
        }
    }
}

/// The app icon, drawn: its moon on its teal-to-navy gradient, in the icon's rounded square. (The icon itself comes
/// from Icon Composer and can't be shown as an image.)
struct AppIconMark: View {
    var size: CGFloat = 120

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0, green: 0.743, blue: 0.798), Color(red: 0.01, green: 0.188, blue: 0.456)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay {
                Image("MoonswiftLogo")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .frame(width: size * 0.56)
                    .offset(y: -size * 0.03)
            }
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
            .accessibilityHidden(true)
    }
}
