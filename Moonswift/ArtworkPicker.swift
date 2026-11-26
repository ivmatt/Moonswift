import SwiftUI

/// The Edit sheet's Choose Artwork: a game's covers (in the chosen cover shape), heroes or logos on SteamGridDB, best rated
/// first and more as you scroll, with Steam's own store picture first for a Steam game. Picking one makes it the game's
/// found art of that kind. Change Game searches SteamGridDB for the right game when the name matched the wrong one.
/// Controller: arrows move, A picks, LB/RB switch between Cover, Hero and Logo, Y changes the game, B closes.
struct ArtworkPicker: View {
    let game: CatalogGame

    @Environment(GameCatalog.self) private var catalog
    @Environment(GamepadInput.self) private var gamepad
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.coverShape) private var coverShape = CoverShape.tall

    private enum Kind: String, CaseIterable { case cover = "Cover", hero = "Hero", logo = "Logo" }
    private struct Choice: Hashable {
        let thumb: URL
        let url: URL
        var isSteam = false
    }

    @State private var kind = Kind.cover
    @State private var choices: [Choice] = []
    @State private var page = 0
    @State private var isAtEnd = false
    @State private var isLoading = false
    /// Which reload a page belongs to: one that arrives after a switch to the other kind (or game) is dropped.
    @State private var generation = 0
    @State private var steamAppID: Int?
    @State private var problem: String?
    @State private var focus = 0
    /// Picked here: ticked. While it downloads: a spinner on it.
    @State private var chosen: URL?
    @State private var saving: URL?

    @State private var isChoosingGame = false
    @State private var query = ""
    @State private var matches: [SteamGridDB.Match] = []
    @State private var isRematching = false
    @FocusState private var isQueryFocused: Bool
    /// In Change Game: -1 the search field, then the matches.
    @State private var gameFocus = 0

    private var artwork: GameCatalog.Artwork {
        switch kind {
        case .cover: .cover(coverShape)
        case .hero: .hero
        case .logo: .logo
        }
    }
    private var match: GameCatalog.FoundMatch? { catalog.foundMatches[game.id] }
    private var columns: Int { kind == .cover ? 4 : kind == .logo ? 3 : 2 }

    var body: some View {
        NavigationStack {
            Group {
                if SteamGridDB.savedKey == nil {
                    ContentUnavailableView("No SteamGridDB Key", systemImage: "key",
                                           description: Text("Add your free API key in Settings, under Interface, to choose art."))
                } else if isChoosingGame {
                    gameSearch
                } else {
                    pictures
                }
            }
            .navigationTitle(isChoosingGame ? "Change Game" : "Choose Artwork")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(isChoosingGame ? "Back" : "Done") { if isChoosingGame { isChoosingGame = false } else { dismiss() } }
                }
            }
            .buttonLegend(isChoosingGame ? [([.a], "Select"), ([.b], "Back")]
                         : [([.a], "Choose"), ([.l1, .r1], "Cover / Hero / Logo"), ([.y], "Change Game"), ([.b], "Done")],
                         reportsLayout: false)
            .onGamepad(handle)
        }
    }

    // MARK: Pictures

    private var pictures: some View {
        VStack(spacing: 12) {
            HStack {
                Picker("Kind", selection: $kind) { ForEach(Kind.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                Spacer()
                Button(match?.name.map { "\($0) · Change Game" } ?? "Find Game") { openGameSearch() }
                    .lineLimit(1)
            }
            .padding(.horizontal, 20)
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: columns), spacing: 14) {
                        // By picture, and only by picture: an extra `.id(index)` gave the Cover and Hero tiles at the
                        // same place the same identity, and the highlight stuck to the first one after switching.
                        ForEach(Array(choices.enumerated()), id: \.element.url) { index, choice in
                            tile(choice, isFocused: gamepad.isActive && index == focus)
                                .onAppear { if index == choices.count - 1 { loadMore() } }
                        }
                    }
                    .padding(20)
                    if isLoading { ProgressView().padding() }
                }
                .overlay {
                    if match?.gameID == nil {
                        ContentUnavailableView("No Game Matched", systemImage: "magnifyingglass",
                                               description: Text("Find the game on SteamGridDB to choose its art."))
                    } else if let problem, choices.isEmpty {
                        ContentUnavailableView("Couldn't Load Artwork", systemImage: "wifi.exclamationmark", description: Text(problem))
                    } else if isAtEnd, choices.isEmpty {
                        ContentUnavailableView("No \(kind.rawValue) Art", systemImage: "photo",
                                               description: Text("SteamGridDB has none for this game yet."))
                    }
                }
                .onChange(of: focus) {
                    if choices.indices.contains(focus) { withAnimation { scroller.scrollTo(choices[focus].url, anchor: .center) } }
                }
            }
        }
        .onChange(of: kind) { focus = 0; choices = [] } // at once: not the old kind's pictures under the new highlight
        .task(id: "\(kind)|\(coverShape)|\(match?.gameID ?? -1)") { await reload() }
    }

    private func tile(_ choice: Choice, isFocused: Bool) -> some View {
        Color.clear
            .aspectRatio(kind == .cover ? coverShape.ratio : kind == .hero ? 1920 / 620 : 2, contentMode: .fit)
            .background { if kind == .logo { Color(white: 0.18) } } // a see-through logo needs something behind it
            .overlay {
                AsyncImage(url: choice.thumb) { phase in
                    if let image = phase.image {
                        if kind == .logo { image.resizable().scaledToFit().padding(12) } else { image.resizable().scaledToFill() }
                    } else if phase.error != nil {
                        Image(systemName: "photo").foregroundStyle(.secondary) // Steam has none of this kind
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 10))
            .overlay(alignment: .topLeading) {
                if choice.isSteam {
                    Text("Steam").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: .capsule).padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if chosen == choice.url {
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.white, .blue).padding(6)
                }
            }
            .overlay { if saving == choice.url { ProgressView() } }
            .focusRing(isFocused, cornerRadius: 10)
            .contentShape(.rect)
            .onTapGesture { choose(choice) }
            .accessibilityElement()
            .accessibilityLabel(choice.isSteam ? "Steam's \(kind.rawValue.lowercased())" : "\(kind.rawValue) option")
            .accessibilityAddTraits(.isButton)
    }

    /// From the start: Steam's own picture first (for a Steam game), then SteamGridDB's first page.
    private func reload() async {
        generation += 1
        choices = []; page = 0; isAtEnd = false; focus = 0; problem = nil; chosen = nil; isLoading = false
        guard let id = match?.gameID, let key = SteamGridDB.savedKey else { return }
        let generation = generation
        if steamAppID == nil { steamAppID = try? await SteamGridDB(key: key).steamAppID(game: id) }
        guard generation == self.generation else { return } // switched again while asking Steam's ID
        // Only when Steam really has one: an empty tile otherwise.
        if let appID = steamAppID, let url = SteamGridDB.steamPicture(artwork, appID: appID), await SteamGridDB.exists(url),
           generation == self.generation {
            choices.insert(Choice(thumb: url, url: url, isSteam: true), at: 0)
        }
        guard generation == self.generation else { return } // the newer reload loads its own pages
        loadMore()
    }

    private func loadMore() {
        guard !isLoading, !isAtEnd, let id = match?.gameID, let key = SteamGridDB.savedKey else { return }
        isLoading = true
        let kind = artwork, page = page, generation = generation
        Task {
            defer { if generation == self.generation { isLoading = false } }
            do {
                let found = try await SteamGridDB(key: key).pictures(kind, game: id, page: page)
                guard generation == self.generation else { return } // switched meanwhile: that reload loads its own
                if found.isEmpty { isAtEnd = true }
                choices += found.map { Choice(thumb: $0.thumb, url: $0.url) }.filter { !choices.contains($0) }
                self.page = page + 1
            } catch {
                guard generation == self.generation else { return }
                problem = "Check your connection and your SteamGridDB key."
                isAtEnd = true
            }
        }
    }

    private func choose(_ choice: Choice) {
        guard saving == nil else { return }
        saving = choice.url
        Task {
            do {
                try await catalog.setFound(from: choice.url, artwork, for: game.id)
                chosen = choice.url
            } catch {
                problem = "Couldn't download that picture."
            }
            saving = nil
        }
    }

    // MARK: Change Game

    private var gameSearch: some View {
        List {
            Section {
                TextField("Game name", text: $query)
                    .focused($isQueryFocused)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(search)
                    .focusedRowBackground(gamepad.isActive && !isQueryFocused && gameFocus == -1)
            } footer: {
                Text("Search SteamGridDB and pick the game. Its art replaces the wrong match.")
            }
            Section {
                ForEach(Array(matches.enumerated()), id: \.element.id) { index, candidate in
                    Button { rematch(candidate) } label: {
                        HStack {
                            Text(candidate.name).foregroundStyle(.primary)
                            Spacer()
                            if candidate.id == match?.gameID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .focusedRowBackground(gamepad.isActive && gameFocus == index)
                }
            }
        }
        .disabled(isRematching)
        .busyBox(isRematching ? "Getting its art…" : nil)
    }

    private func openGameSearch() {
        query = SteamGridDB.cleaned(game.originalTitle)
        gameFocus = 0
        isChoosingGame = true
        search()
    }

    private func search() {
        guard let key = SteamGridDB.savedKey else { return }
        let query = query
        Task { matches = (try? await SteamGridDB(key: key).matches(query)) ?? [] }
    }

    private func rematch(_ candidate: SteamGridDB.Match) {
        guard let key = SteamGridDB.savedKey else { return }
        isRematching = true
        Task {
            try? await catalog.rematch(game, to: candidate, key: key)
            steamAppID = nil
            isRematching = false
            isChoosingGame = false
        }
    }

    // MARK: Controller

    private func handle(_ command: GamepadCommand) {
        if isChoosingGame {
            if [.up, .down].contains(command), isQueryFocused { isQueryFocused = false }
            switch command {
            case .up: gameFocus = max(gameFocus - 1, -1)
            case .down: gameFocus = min(gameFocus + 1, matches.count - 1)
            case .select:
                if gameFocus == -1 { isQueryFocused = true } else if matches.indices.contains(gameFocus) { rematch(matches[gameFocus]) }
            case .back: if isQueryFocused { isQueryFocused = false } else { isChoosingGame = false }
            default: break
            }
            return
        }
        switch command {
        case .up, .down, .left, .right:
            focus = FocusMove.next(focus, count: choices.count, columns: columns, command)
            if focus >= choices.count - columns { loadMore() }
        case .select: if choices.indices.contains(focus) { choose(choices[focus]) }
        case .previousTab: kind = Kind.allCases[max(0, (Kind.allCases.firstIndex(of: kind) ?? 0) - 1)]
        case .nextTab: kind = Kind.allCases[min(Kind.allCases.count - 1, (Kind.allCases.firstIndex(of: kind) ?? 0) + 1)]
        case .menu: openGameSearch()
        case .back: dismiss()
        default: break
        }
    }
}
