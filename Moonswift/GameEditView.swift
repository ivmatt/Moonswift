import PhotosUI
import SwiftUI

/// A game's page for how Moonswift shows it: a nickname, your own hero picture and a cover for each cover shape (2:3,
/// 3:4, square; a shape without one shows the PC's art), and favourite. The PC's own name and art stay as they are,
/// and Reset brings them back. Controller: up/down move between rows; A types the name, picks a picture (or offers
/// Change and Remove for one that's set), flips Favorite or presses Reset; B saves and closes.
struct GameEditView: View {
    let game: CatalogGame

    @Environment(GameCatalog.self) private var catalog
    @AppStorage(SettingsKey.coverShape) private var coverShape = CoverShape.tall
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var heroItem: PhotosPickerItem?
    /// The picker for each cover shape.
    @State private var coverItems: [CoverShape: PhotosPickerItem] = [:]

    private enum Row: Hashable { case name, hero, cover(CoverShape), favorite, reset }
    /// Must match the on-screen order, or up/down feel inverted.
    private let rows: [Row] = [.name, .hero] + CoverShape.allCases.map(Row.cover) + [.favorite, .reset]
    @State private var focus = 0
    @FocusState private var isNameFocused: Bool
    /// The controller's photo picker: which picture it's for, and what was picked.
    @State private var pickerKind: GameCatalog.Artwork?
    @State private var pickedItem: PhotosPickerItem?
    @State private var choice: ChoiceMenuSpec?
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
                    Text("Your host calls it \(game.originalTitle). The new name only shows in Moonswift.")
                }
                Section("Artwork") {
                    row(.hero) { artworkRow("Hero Image", catalog.heroArt[game.id], aspect: 16 / 9, item: $heroItem, kind: .hero) }
                }
                Section {
                    ForEach(CoverShape.allCases, id: \.self) { shape in
                        row(.cover(shape)) {
                            artworkRow(shape == .square ? "Square Cover" : "\(shape.rawValue) Cover",
                                       catalog.cover(for: game.id, shape), aspect: shape.ratio,
                                       item: Binding(get: { coverItems[shape] }, set: { coverItems[shape] = $0 }),
                                       kind: .cover(shape), isInUse: shape == coverShape)
                        }
                    }
                } header: {
                    Text("Covers")
                } footer: {
                    Text("One for each cover shape. The shape chosen in Settings (\(coverShape.rawValue)) shows yours if you've "
                         + "added one, otherwise the art from your host.")
                }
                Section {
                    row(.favorite) {
                        Toggle("Favorite", isOn: Binding(get: { current.isFavorite }, set: { _ in catalog.toggleFavorite(current) }))
                    }
                }
                Section {
                    row(.reset) {
                        Button("Reset to Original", role: .destructive, action: reset)
                    }
                }
            }
            // The focused row in the middle, so its section's title and notes show too.
            .onChange(of: focus) { if rows.indices.contains(focus) { withAnimation { scroller.scrollTo(rows[focus], anchor: .center) } } }
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
            .buttonGuide([([.a], "Select"), ([.b], "Done")], reportsLayout: false)
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
        case .reset: reset()
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

    private func reset() {
        catalog.resetCustomizations(for: game)
        name = game.originalTitle
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
