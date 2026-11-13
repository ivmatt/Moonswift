import PhotosUI
import SwiftUI

/// A game's page for how Moonswift shows it: a nickname, your own hero picture and a cover for each cover shape (2:3,
/// 3:4, square; a shape without one shows the PC's art), and favourite. The PC's own name and art stay as they are,
/// and Reset brings them back. Controller: B saves and closes.
struct GameEditView: View {
    let game: CatalogGame

    @Environment(GameCatalog.self) private var catalog
    @AppStorage(SettingsKey.coverShape) private var coverShape = CoverShape.tall
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var heroItem: PhotosPickerItem?
    /// The picker for each cover shape.
    @State private var coverItems: [CoverShape: PhotosPickerItem] = [:]

    /// `game` is a snapshot from when the page opened; favourite and art change while it's open.
    private var current: CatalogGame {
        catalog.games(on: game.sources.map(\.pcID)).first { $0.id == game.id } ?? game
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(game.originalTitle, text: $name)
                        .autocorrectionDisabled()
                } header: {
                    Text("Name")
                } footer: {
                    Text("Your PC calls it \(game.originalTitle). The new name only shows in Moonswift.")
                }
                Section("Artwork") {
                    artworkRow("Hero Image", catalog.heroArt[game.id], aspect: 16 / 9, item: $heroItem, kind: .hero)
                }
                Section {
                    ForEach(CoverShape.allCases, id: \.self) { shape in
                        artworkRow(shape == .square ? "Square Cover" : "\(shape.rawValue) Cover",
                                   catalog.cover(for: game.id, shape), aspect: shape.ratio,
                                   item: Binding(get: { coverItems[shape] }, set: { coverItems[shape] = $0 }),
                                   kind: .cover(shape), isInUse: shape == coverShape)
                    }
                } header: {
                    Text("Covers")
                } footer: {
                    Text("One for each cover shape. The shape chosen in Settings (\(coverShape.rawValue)) shows yours if you've "
                         + "added one, otherwise the art from your PC.")
                }
                Section {
                    Toggle("Favorite", isOn: Binding(get: { current.isFavorite }, set: { _ in catalog.toggleFavorite(current) }))
                }
                Section {
                    Button("Reset to Original", role: .destructive) {
                        catalog.resetCustomizations(for: game)
                        name = game.originalTitle
                    }
                }
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
            .onGamepad { if $0 == .back { done() } }
        }
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
