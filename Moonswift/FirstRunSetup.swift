import SwiftUI

/// After the first host is paired: one setting a page (online artwork, touch controls, the splash screen), each with
/// its default already chosen and a Skip that keeps it. Then, with online artwork and a key, a moment of "final
/// touches" while the first games' art comes in. Choices are the same saved settings Settings shows.
/// Controller: up/down move, A picks (or continues, on Continue), X skips, B goes back a page.
struct FirstRunSetup: View {
    /// Which page shows: Add Host keeps it, so its toolbar's Back steps through the pages too.
    @Binding var pageIndex: Int
    /// Which way the pages last moved (Add Host's Back moves them too): the slide follows it.
    @Binding var isForward: Bool
    /// The new host: its games are fetched meanwhile, and waited for at the end.
    let hostID: String
    /// Back from the first page: to the success page.
    let backFromFirst: () -> Void
    let finish: () -> Void

    private enum Page: Int, CaseIterable { case artwork, touch, splash }

    @Environment(GameCatalog.self) private var catalog
    @Environment(GamepadInput.self) private var gamepad
    @AppStorage(SettingsKey.onlineArtwork) private var findsArtwork = true
    @AppStorage(SettingsKey.artworkKeyVersion) private var artworkKeyVersion = 0
    @AppStorage("touchMode") private var touchMode = TouchMode.automatic
    @AppStorage(SettingsKey.splashScreen) private var showsSplash = true
    @AppStorage(SettingsKey.splashWait) private var splashWait = LaunchSplash.defaultWait
    @AppStorage(SettingsKey.splashEndsOnSound) private var splashEndsOnSound = false
    private var page: Page { Page(rawValue: pageIndex) ?? .artwork }
    @State private var isFinishing = false
    @State private var key = SteamGridDB.savedKey ?? ""
    @FocusState private var isKeyFocused: Bool
    @State private var focus = 0

    private static let keyPage = URL(string: "https://www.steamgriddb.com/profile/preferences/api")!

    var body: some View {
        Group {
            if isFinishing {
                finalTouches
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        content
                        buttons.padding(.top, 14) // after the options: read through them to move on
                    }
                    .padding(28)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
                .id(page) // each page from its top, sliding in
                .transition(AddHostView.slide(forward: isForward))
            }
        }
        .transition(.opacity)
        .buttonGuide(isFinishing ? [] : [([.a], "Select"), ([.x], "Skip"), ([.b], "Back")], reportsLayout: false)
        .onGamepad(handle)
    }

    // MARK: Pages

    @ViewBuilder private var content: some View {
        switch page {
        case .artwork:
            header("photo.on.rectangle.angled", "Artwork",
                   "Moonswift can find covers and big background pictures for your games online, from SteamGridDB. "
                   + "Your games' names are sent to it to look them up.")
            option(0, "Use online artwork", "Recommended. Sharp covers and a picture behind every game on Home.",
                   isOn: findsArtwork) { findsArtwork = true }
            option(1, "Use my host's art", "Whatever your host provides; some games have none.", isOn: !findsArtwork) {
                findsArtwork = false
            }
            if findsArtwork { keyInstructions }
        case .touch:
            header("hand.tap", "Touch Controls",
                   "How touching the screen controls your PC while you stream. Change it any time from the stream's Quick Settings.")
            option(0, "Automatic", "Recommended. The on-screen controller when no game controller is connected, the "
                   + "touchscreen when one is.", isOn: touchMode == .automatic) { touchMode = .automatic }
            option(1, "On-screen controller", "A game controller drawn over the stream, for when you don't have one with you.",
                   isOn: touchMode == .controller) { touchMode = .controller }
            option(2, "Touchscreen", "Your finger is the pointer: tap where you want to click. Best for desktop apps.",
                   isOn: touchMode == .touchscreen) { touchMode = .touchscreen }
            option(3, "Trackpad", "Slide to move the cursor, tap to click, two fingers to scroll, like a laptop.",
                   isOn: touchMode == .trackpad) { touchMode = .trackpad }
        case .splash:
            header("sparkles.rectangle.stack", "Splash Screen",
                   "Shows the game's art from the moment you press Play until it's on screen, so you don't see the host's "
                   + "desktop or launchers flash by.")
            option(0, "On", "Recommended.", isOn: showsSplash) { showsSplash = true }
            option(1, "Off", "Go straight to the stream as it starts.", isOn: !showsSplash) { showsSplash = false }
            if showsSplash {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Splash Wait")
                            Text("How long it stays once the game's picture comes in.").font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("Splash Wait", selection: $splashWait) {
                            ForEach(LaunchSplash.waitChoices, id: \.self) { Text(SettingsView.seconds($0)).tag($0) }
                        }
                        .tint(.secondary)
                    }
                    .padding(14)
                    .background(rowBackground(isFocused: focused(2)), in: .rect(cornerRadius: 16))
                    Toggle(isOn: $splashEndsOnSound) { // green: the page's white tint made it white
                        VStack(alignment: .leading, spacing: 2) {
                            Text("End on Game Sound (Beta)")
                            Text("Lifts it as soon as the game makes sound, Splash Wait at most.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .tint(.green)
                    .padding(14)
                    .background(rowBackground(isFocused: focused(3)), in: .rect(cornerRadius: 16))
                }
                .padding(.top, 4)
            }
        }
    }

    private var keyInstructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Get your free API key").font(.headline).padding(.top, 6)
            step(1, "Open SteamGridDB's API page and sign in with your Steam account.")
            Link(destination: Self.keyPage) { Label("Open steamgriddb.com", systemImage: "safari") }
                .font(.subheadline.weight(.semibold))
                .tint(.blue)
                .padding(.leading, 32)
            step(2, "Under API Keys, press Generate API Key (or copy the one already there).")
            step(3, "Come back and paste it here.")
            SecureField("Paste your API key", text: $key)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isKeyFocused)
                .padding(14)
                .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 14))
                .onSubmit(saveKey)
            Text("No key yet? Carry on: add it later in Settings › Interface, and the art follows.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func header(_ symbol: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 72, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            Text(title).font(.title2.bold())
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func option(_ index: Int, _ title: String, _ detail: String, isOn: Bool, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.blue : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(isFocused: focused(index)), in: .rect(cornerRadius: 16))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.subheadline.weight(.bold)).frame(width: 22, height: 22).background(.quaternary, in: .circle)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func rowBackground(isFocused: Bool) -> Color {
        isFocused ? Color.accentColor.opacity(0.25) : Color(.secondarySystemGroupedBackground)
    }

    private var buttons: some View {
        HStack(spacing: 14) {
            Button("Skip", action: next)
                .buttonStyle(.glass)
                .controlSize(.large)
            Button { next() } label: { Text("Continue").frame(width: 160) }
                .buttonStyle(.glassProminent)
                .tint(.blue)
                .controlSize(.large)
                .focusRing(focused(rowCount - 1), cornerRadius: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Final touches

    /// The games, if they aren't in yet, then (with online artwork and a key) the first few games' art: each a few
    /// seconds at most, so a slow host or service never holds it up for long.
    private var finalTouches: some View {
        VStack(spacing: 16) {
            ArcSpinner(size: 34).foregroundStyle(.secondary)
            Text("Almost done…").font(.title3.weight(.semibold))
            Text(catalog.games(on: [hostID]).isEmpty ? "Getting your games." : "Getting your games' artwork ready.")
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .task {
            let deadline = ContinuousClock.now + .seconds(20)
            while catalog.games(on: [hostID]).isEmpty, ContinuousClock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
            }
            if findsArtwork, let key = SteamGridDB.savedKey {
                let games = Array(catalog.games(on: [hostID]).prefix(6))
                await withTaskGroup(of: Void.self) { group in // whichever comes first: the art, or 10 seconds
                    group.addTask { await catalog.findArtwork(for: games, key: key) }
                    group.addTask { try? await Task.sleep(for: .seconds(10)) }
                    await group.next()
                    group.cancelAll()
                }
            }
            finish()
        }
    }

    // MARK: Moving on

    /// Options, then Splash's extras (while it's on), then Continue.
    private var rowCount: Int {
        switch page {
        case .artwork: 3
        case .touch: 5
        case .splash: showsSplash ? 5 : 3
        }
    }

    private func focused(_ index: Int) -> Bool { gamepad.isActive && !isKeyFocused && focus == index }

    private func next() {
        if page == .artwork { saveKey() }
        focus = 0
        isKeyFocused = false
        if Page(rawValue: pageIndex + 1) != nil {
            isForward = true
            withAnimation(.easeInOut(duration: 0.3)) { pageIndex += 1 }
        } else if catalog.games(on: [hostID]).isEmpty || (findsArtwork && SteamGridDB.savedKey != nil) {
            isForward = true
            withAnimation(.easeInOut(duration: 0.3)) { isFinishing = true }
        } else {
            finish()
        }
    }

    private func back() {
        focus = 0
        if pageIndex == 0 { backFromFirst() } else { isForward = false; withAnimation(.easeInOut(duration: 0.3)) { pageIndex -= 1 } }
    }

    private func saveKey() {
        guard key.trimmingCharacters(in: .whitespacesAndNewlines) != (SteamGridDB.savedKey ?? "") else { return }
        SteamGridDB.save(key: key)
        artworkKeyVersion += 1
    }

    private func handle(_ command: GamepadCommand) {
        guard !isFinishing else { return }
        if isKeyFocused, [.up, .down, .back].contains(command) { isKeyFocused = false; return }
        switch command {
        case .up, .down: focus = FocusMove.next(focus, count: rowCount, columns: 1, command)
        case .left, .right:
            guard page == .splash, focus == 2, let index = LaunchSplash.waitChoices.firstIndex(of: splashWait) else { return }
            let choices = LaunchSplash.waitChoices
            splashWait = choices[min(max(index + (command == .left ? -1 : 1), 0), choices.count - 1)]
        case .select:
            if focus == rowCount - 1 { return next() }
            switch page {
            case .artwork: findsArtwork = focus == 0
            case .touch: touchMode = [TouchMode.automatic, .controller, .touchscreen, .trackpad][focus]
            case .splash:
                if focus < 2 { showsSplash = focus == 0 } else if focus == 3 { splashEndsOnSound.toggle() }
            }
        case .alternate: next()
        case .back: back()
        default: break
        }
    }
}
