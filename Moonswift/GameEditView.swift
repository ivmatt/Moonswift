import PhotosUI
import SwiftUI

/// A game's page for how Moonswift shows it: a nickname, your own hero picture and a cover for each cover shape (2:3,
/// 3:4, square; a shape without one shows the PC's art; apps have no art options), favourite, hidden, game or app, how long its launch splash waits, and its logo's size on Home. The PC's own name and art stay as they are,
/// and Reset brings them back (asking first; Favorite, Hidden and art from Choose Artwork stay). Controller: up/down move between rows; A types the name, picks a picture (or offers
/// Change and Remove for one that's set), flips Favorite or presses Reset; B saves and closes.
struct GameEditView: View {
    let game: CatalogGame

    @Environment(GameCatalog.self) private var catalog
    @AppStorage(SettingsKey.coverShape) private var coverShape = SettingsDefault.coverShape
    @AppStorage(SettingsKey.logoSize) private var defaultLogoSize = SettingsDefault.logoSize
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var heroItem: PhotosPickerItem?
    /// The picker for each cover shape.
    @State private var coverItems: [CoverShape: PhotosPickerItem] = [:]

    private enum Row: Hashable { case name, hero, cover(CoverShape), onlineArt, chooseArt, favorite, hidden, showAs, splashWait, logoSize, reset }
    /// Must match the on-screen order, or up/down feel inverted.
    private var rows: [Row] {
        let art: [Row] = current.isApp ? []
            : (match != nil ? [.onlineArt] : []) + (hasArtworkKey ? [.chooseArt] : []) + (hasLogo ? [.logoSize] : [])
                + [.hero, .cover(coverShape)]
        return [.name] + art + [.favorite, .hidden, .showAs, .splashWait, .reset]
    }
    /// Logo Size shows only for a game with a logo.
    private var hasLogo: Bool { catalog.shownLogo(for: game.id) != nil }
    /// A SteamGridDB key is set: art can be chosen there. Read once: it's in the Keychain.
    @State private var hasArtworkKey = SteamGridDB.savedKey != nil
    @State private var isChoosingArt = false
    /// What SteamGridDB matched it to, once it's been looked up.
    private var match: GameCatalog.FoundMatch? { catalog.foundMatches[game.id] }
    @State private var focus = 0
    @FocusState private var isNameFocused: Bool
    /// The controller's photo picker: which picture it's for, and what was picked.
    @State private var pickerKind: GameCatalog.Artwork?
    @State private var pickedItem: PhotosPickerItem?
    @State private var choice: ChoiceMenuSpec?
    /// Reset's confirmation.
    @State private var menu: MenuSpec?
    @State private var rowFrames = RowFrames()
    @Environment(GamepadInput.self) private var gamepad

    /// `game` is a snapshot from when the page opened; favourite and art change while it's open.
    private var current: CatalogGame {
        catalog.games(on: game.sources.map(\.pcID)).first { $0.id == game.id } ?? game
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
            Form {
                Section {
                    row(.name) {
                        TextField(game.originalTitle, text: $name)
                            .autocorrectionDisabled()
                            .focused($isNameFocused)
                    }
                } header: {
                    Text("Name")
                } footer: {
                    Text("Only changes it in Moonswift. Your host calls it \(game.originalTitle).")
                }
                if !current.isApp && (match != nil || hasArtworkKey) {
                    Section {
                        if let match {
                            row(.onlineArt) {
                                Toggle("Use Online Artwork", isOn: Binding(get: { !catalog.onlineArtOff.contains(game.id) },
                                                                           set: { catalog.setOnlineArt($0, for: game) }))
                                    .disabled(match.gameID == nil)
                            }
                        }
                        if hasArtworkKey {
                            row(.chooseArt) {
                                Button("Choose Artwork…") { isChoosingArt = true }.foregroundStyle(.primary)
                            }
                        }
                        if hasLogo {
                            row(.logoSize) {
                                ChoiceRow(title: "Logo Size", value: logoSizeTitle(catalog.logoSizes[game.id]),
                                          isValueHidden: choice?.source == AnyHashable(Row.logoSize)) {
                                    Picker("Logo Size", selection: Binding(get: { catalog.logoSizes[game.id] },
                                                                           set: { catalog.setLogoSize($0, for: game) })) {
                                        ForEach(logoSizeOptions, id: \.self) { Text(logoSizeTitle($0)).tag($0) }
                                    }
                                    .pickerStyle(.inline)
                                }
                            }
                        }
                    } header: {
                        Text("Online Artwork and Covers")
                    } footer: {
                        Text(match?.name.map { "Found on SteamGridDB as \($0). Choose Artwork to change the art or game." }
                             ?? (match != nil ? "Not found on SteamGridDB. Choose Artwork to search."
                                 : "Not looked up on SteamGridDB yet."))
                    }
                }
                if !current.isApp {
                    Section {
                        row(.hero) { artworkRow("Hero", catalog.heroArt[game.id], aspect: 16 / 9, item: $heroItem, kind: .hero) }
                        // The cover for the shape chosen in Settings: the other shapes' don't show anywhere.
                        row(.cover(coverShape)) {
                            artworkRow("Cover", catalog.cover(for: game.id, coverShape), aspect: coverShape.ratio,
                                       item: Binding(get: { coverItems[coverShape] }, set: { coverItems[coverShape] = $0 }),
                                       kind: .cover(coverShape))
                        }
                    } header: {
                        Text("Artwork and Covers")
                    } footer: {
                        Text("The hero shows behind the game on Home. The cover uses your \(coverShape.rawValue) shape from Settings. "
                             + "Your pictures show before online or host art.")
                    }
                }
                Section {
                    row(.favorite) {
                        Toggle("Favorite", isOn: Binding(get: { current.isFavorite }, set: { _ in catalog.toggleFavorite(current) }))
                    }
                    row(.hidden) {
                        Toggle("Hidden", isOn: Binding(get: { current.isHidden }, set: { catalog.setHidden($0, for: game) }))
                    }
                    row(.showAs) {
                        ChoiceRow(title: "Show As", value: showAsTitle(catalog.showAs[game.id]),
                                  isValueHidden: choice?.source == AnyHashable(Row.showAs)) {
                            Picker("Show As", selection: Binding(get: { catalog.showAs[game.id] },
                                                                 set: { catalog.setShowAs($0, for: game) })) {
                                ForEach(showAsOptions, id: \.self) { Text(showAsTitle($0)).tag($0) }
                            }
                            .pickerStyle(.inline)
                        }
                    }
                } footer: {
                    Text("Hidden games leave Home and Library; Library's Filter shows them again. Apps appear above your games.")
                }
                Section {
                    row(.splashWait) {
                        ChoiceRow(title: "Splash Wait", value: waitTitle(catalog.splashWaits[game.id]),
                                  isValueHidden: choice?.source == AnyHashable(Row.splashWait)) {
                            Picker("Splash Wait", selection: Binding(get: { catalog.splashWaits[game.id] },
                                                                     set: { catalog.setSplashWait($0, for: game) })) {
                                ForEach(waitOptions, id: \.self) { Text(waitTitle($0)).tag($0) }
                            }
                            .pickerStyle(.inline)
                        }
                    }
                } footer: {
                    Text("How long the splash stays after the game's picture appears. Default uses Settings.")
                }
                Section {
                    row(.reset) {
                        Button("Reset to Original", role: .destructive, action: confirmReset)
                            .disabled(!canReset)
                    }
                }
            }
            // The focused row in the middle, so its section's title and notes show too.
            .onChange(of: focus) { if rows.indices.contains(focus) { withAnimation { scroller.scrollTo(rows[focus], anchor: .center) } } }
            // Show As adds or removes the art rows above: focus stays on its row, and never past the last one.
            .onChange(of: rows) { old, new in focus = GamesView.followedPosition(focus, from: old, to: new) ?? 0 }
            }
            .navigationTitle(game.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
            }
            .onAppear { name = game.title }
            .onChange(of: heroItem) { load(heroItem, .hero) }
            .onChange(of: coverItems) { old, new in
                for shape in CoverShape.allCases where new[shape] != old[shape] { load(new[shape], .cover(shape)) }
            }
            .photosPicker(isPresented: Binding(get: { pickerKind != nil }, set: { if !$0 { pickerKind = nil } }),
                          selection: $pickedItem, matching: .images)
            .onChange(of: pickedItem) {
                if let pickerKind { load(pickedItem, pickerKind) }
                pickedItem = nil
            }
            .choiceMenu($choice)
            .actionMenu($menu)
            .sheet(isPresented: $isChoosingArt) { ArtworkPicker(game: game) }
            .buttonLegend([([.a], "Select"), ([.b], "Done")], reportsLayout: false)
            .onGamepad(handle)
        }
    }

    private func row(_ row: Row, @ViewBuilder content: () -> some View) -> some View {
        let isFocused = gamepad.isActive && !isNameFocused && rows.firstIndex(of: row) == focus
        return content()
            .recordsFrame(row, in: rowFrames)
            .focusedRowBackground(isFocused)
            .id(row) // outermost: under the row background a list doesn't find it to scroll to
    }

    private func handle(_ command: GamepadCommand) {
        // The photo picker is Apple's own screen: B closes just it (it closed the whole page), the rest waits.
        if pickerKind != nil { if command == .back { pickerKind = nil }; return }
        // Moving off the name puts the keyboard away, so the highlight shows where it went.
        if [.up, .down].contains(command), isNameFocused { isNameFocused = false }
        switch command {
        case .up, .down: focus = FocusMove.next(focus, count: rows.count, columns: 1, command)
        case .select: select(rows[focus])
        case .back: if isNameFocused { isNameFocused = false } else { done() }
        default: break
        }
    }

    private func select(_ row: Row) {
        switch row {
        case .name: isNameFocused = true
        case .hero: pick(.hero, hasImage: catalog.heroArt[game.id] != nil, row: row)
        case .cover(let shape): pick(.cover(shape), hasImage: catalog.cover(for: game.id, shape) != nil, row: row)
        case .favorite: catalog.toggleFavorite(current)
        case .chooseArt: isChoosingArt = true
        case .onlineArt: if match?.gameID != nil { catalog.setOnlineArt(catalog.onlineArtOff.contains(game.id), for: game) }
        case .hidden: catalog.setHidden(!current.isHidden, for: game)
        case .showAs:
            let options = showAsOptions
            let spec = ChoiceMenuSpec(source: row, options: options.map(showAsTitle),
                                      selected: options.firstIndex(of: catalog.showAs[game.id]) ?? 0,
                                      anchor: rowFrames.frames[row] ?? .zero) { catalog.setShowAs(options[$0], for: game) }
            withAnimation(.easeOut(duration: 0.12)) { choice = spec }
        case .splashWait:
            let options = waitOptions
            let spec = ChoiceMenuSpec(source: row, options: options.map(waitTitle),
                                      selected: options.firstIndex(of: catalog.splashWaits[game.id]) ?? 0,
                                      anchor: rowFrames.frames[row] ?? .zero) { catalog.setSplashWait(options[$0], for: game) }
            withAnimation(.easeOut(duration: 0.12)) { choice = spec }
        case .logoSize:
            let options = logoSizeOptions
            let spec = ChoiceMenuSpec(source: row, options: options.map(logoSizeTitle),
                                      selected: options.firstIndex(of: catalog.logoSizes[game.id]) ?? 0,
                                      anchor: rowFrames.frames[row] ?? .zero) { catalog.setLogoSize(options[$0], for: game) }
            withAnimation(.easeOut(duration: 0.12)) { choice = spec }
        case .reset: if canReset { confirmReset() }
        }
    }

    /// A picture's row: the photo picker, or for one that's set, Change or Remove.
    private func pick(_ kind: GameCatalog.Artwork, hasImage: Bool, row: Row) {
        guard hasImage else { return pickerKind = kind }
        let spec = ChoiceMenuSpec(source: row, options: ["Change…", "Remove"], selected: -1,
                                  anchor: rowFrames.frames[row] ?? .zero) { index in
            if index == 0 { pickerKind = kind } else { catalog.setArtwork(nil, kind, for: game) }
        }
        withAnimation(.easeOut(duration: 0.12)) { choice = spec }
    }

    /// Automatic (nil), then the two choices.
    private var showAsOptions: [ShowAs?] { [nil] + ShowAs.allCases.map(Optional.some) }
    /// Automatic says what it picked, so you know whether to change it.
    private func showAsTitle(_ choice: ShowAs?) -> String {
        switch choice {
        case .game: "Game"
        case .shortcut: "App"
        case nil:
            CatalogGame.isShortcut(nil, title: game.originalTitle, isSessionControl: game.sources[0].app.sessionControl != nil)
                ? "Automatic (App)" : "Automatic (Game)"
        }
    }

    /// Default (nil), then the seconds.
    private var waitOptions: [Int?] { [nil] + LaunchSplash.waitChoices.map(Optional.some) }
    /// Default (nil: Settings' size), then each step.
    private var logoSizeOptions: [Int?] { [nil] + GameCatalog.logoSizeChoices.map(Optional.some) }
    private func logoSizeTitle(_ percent: Int?) -> String { percent.map { "\($0)%" } ?? "Default (\(defaultLogoSize)%)" }
    private func waitTitle(_ seconds: Int?) -> String { seconds.map(SettingsView.seconds) ?? "Default" }

    /// Something here differs from the host's and the defaults, including a name typed but not yet saved.
    private var canReset: Bool {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog.hasCustomizations(for: game) || !(typed.isEmpty || typed == game.originalTitle)
    }

    private func confirmReset() {
        menu = MenuSpec(title: "Reset \(game.title)?",
                        message: "Its name, your pictures and its settings here go back. Favorite, Hidden and chosen art stay.",
                        actions: [.init(title: "Reset", isDestructive: true) {
                            catalog.resetCustomizations(for: game)
                            name = game.originalTitle
                        }],
                        cancelTitle: "Cancel")
    }

    private func artworkRow(_ label: String, _ image: UIImage?, aspect: CGFloat, item: Binding<PhotosPickerItem?>,
                            kind: GameCatalog.Artwork, isInUse: Bool = false) -> some View {
        HStack(spacing: 12) {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: 44 * aspect, height: 44)
                    .clipShape(.rect(cornerRadius: 6))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if isInUse { Text("In use").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            PhotosPicker(image == nil ? "Choose…" : "Change…", selection: item, matching: .images)
                .buttonStyle(.borderless)
            if image != nil {
                Button("Remove", role: .destructive) { catalog.setArtwork(nil, kind, for: game) }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func load(_ item: PhotosPickerItem?, _ kind: GameCatalog.Artwork) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
            catalog.setArtwork(image, kind, for: game)
        }
    }

    private func done() {
        catalog.setNickname(name, for: game)
        dismiss()
    }
}
