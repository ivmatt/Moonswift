import SwiftUI

/// The on-screen controller's layouts, kept on this device: Standard (editable, and Reset brings it back) and the ones
/// you make.
@MainActor @Observable final class PadLayoutStore {
    private(set) var layouts: [PadLayout]

    init() {
        let saved = UserDefaults.standard.data(forKey: "padLayouts").flatMap { try? JSONDecoder().decode([PadLayout].self, from: $0) }
        layouts = saved?.isEmpty == false ? saved! : [.standard]
        if !layouts.contains(where: { $0.id == PadLayout.standard.id }) { layouts.insert(.standard, at: 0) }
    }

    /// A layout by ID; one that's gone (deleted) is Standard.
    func layout(_ id: String?) -> PadLayout { layouts.first { $0.id == id } ?? layouts.first { $0.id == PadLayout.standard.id } ?? .standard }

    func save(_ layout: PadLayout) {
        if let index = layouts.firstIndex(where: { $0.id == layout.id }) { layouts[index] = layout } else { layouts.append(layout) }
        persist()
    }

    /// A copy of `layout` (Standard's controls for a new one), named "Layout 2" and so on.
    func add(copying layout: PadLayout = .standard, name: String? = nil) -> PadLayout {
        var copy = layout
        copy.id = UUID().uuidString
        copy.name = name ?? "Layout \(layouts.count + 1)"
        layouts.append(copy)
        persist()
        return copy
    }

    /// Standard stays.
    func delete(_ id: String) {
        guard id != PadLayout.standard.id else { return }
        layouts.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(layouts), forKey: "padLayouts")
    }
}

/// Editing a layout over the live game (Quick Settings → Edit Layout): drag a control to move it, pinch it (or use −
/// and +) to resize it, tap it for those and Remove; the bar on top switches, adds, renames and deletes layouts, adds
/// controls back, and sets opacity and the floating left stick. Changes save as they're made. Touch only; B finishes.
struct PadEditor: View {
    let store: PadLayoutStore
    /// The layout being edited (and used by this game).
    @Binding var layoutID: String
    let done: () -> Void

    @State private var selected: PadControl?
    @State private var resizeBase: CGFloat?
    @State private var naming: NameRequest?
    @State private var name = ""
    private enum NameRequest: Identifiable { case new, rename; var id: Self { self } }

    private var layout: PadLayout { store.layout(layoutID) }
    private var missing: [PadControl] { PadControl.allCases.filter { control in !layout.items.contains { $0.control == control } } }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { selected = nil }
            GeometryReader { proxy in
                ZStack {
                    ForEach(layout.items, id: \.control) { item in
                        editable(item, area: proxy.size)
                    }
                }
                .coordinateSpace(.named("pad"))
            }
            .opacity(max(layout.opacity, 0.5)) // never too faint to edit
            bar
        }
        .onGamepad { if $0 == .back { done() } }
        .alert(naming == .new ? "New Layout" : "Rename Layout", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") { saveName() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: Controls

    private func editable(_ item: PadItem, area: CGSize) -> some View {
        let frame = item.frame(in: area)
        let isSelected = selected == item.control
        return ZStack {
            PadControlView(item: item, area: area, presses: PadPresses())
            Rectangle().fill(.clear)
                .frame(width: frame.width + 16, height: frame.height + 16)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isSelected ? Color.white : .white.opacity(0.4), style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: [5, 4]))
                }
                .contentShape(.rect)
                .position(x: frame.midX, y: frame.midY)
                .gesture(DragGesture(coordinateSpace: .named("pad")).onChanged { drag in
                    selected = item.control
                    update(item.control) {
                        $0.x = min(max(drag.location.x / max(area.width, 1), 0), 1)
                        $0.y = min(max(drag.location.y / max(area.height, 1), 0), 1)
                    }
                })
                .simultaneousGesture(MagnifyGesture().onChanged { pinch in
                    let base = resizeBase ?? item.size
                    resizeBase = base
                    update(item.control) { $0.size = Self.clamped(base * pinch.magnification) }
                }.onEnded { _ in resizeBase = nil })
                .onTapGesture { selected = isSelected ? nil : item.control }
            if isSelected { itemTools(item, frame: frame, area: area) }
        }
    }

    /// − and + to resize, and Remove, beside the selected control (below it, or above near the bottom).
    private func itemTools(_ item: PadItem, frame: CGRect, area: CGSize) -> some View {
        HStack(spacing: 4) {
            Button { update(item.control) { $0.size = Self.clamped($0.size - 8) } } label: { Image(systemName: "minus").frame(width: 36, height: 36) }
            Button { update(item.control) { $0.size = Self.clamped($0.size + 8) } } label: { Image(systemName: "plus").frame(width: 36, height: 36) }
            Button(role: .destructive) { remove(item.control) } label: { Image(systemName: "trash").frame(width: 36, height: 36) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .glassEffect(.regular, in: .capsule)
        .position(x: min(max(frame.midX, 70), area.width - 70),
                  y: frame.maxY + 34 < area.height ? frame.maxY + 34 : frame.minY - 34)
    }

    nonisolated static func clamped(_ size: CGFloat) -> CGFloat { min(max(size, 32), 240) }

    private func update(_ control: PadControl, _ change: (inout PadItem) -> Void) {
        var edited = layout
        guard let index = edited.items.firstIndex(where: { $0.control == control }) else { return }
        change(&edited.items[index])
        store.save(edited)
    }

    private func remove(_ control: PadControl) {
        var edited = layout
        edited.items.removeAll { $0.control == control }
        store.save(edited)
        selected = nil
    }

    private func addBack(_ control: PadControl) {
        var edited = layout
        let size = PadLayout.standard.items.first { $0.control == control }?.size ?? 56
        edited.items.append(PadItem(control: control, x: 0.5, y: 0.5, size: size))
        store.save(edited)
        selected = control
    }

    // MARK: Bar

    private var bar: some View {
        HStack(spacing: 14) {
            Menu {
                Picker("Layout", selection: $layoutID) {
                    ForEach(store.layouts) { Text($0.name).tag($0.id) }
                }
                Divider()
                Button("New Layout", systemImage: "plus") { name = ""; naming = .new }
                Button("Duplicate", systemImage: "plus.square.on.square") { layoutID = store.add(copying: layout, name: layout.name + " Copy").id }
                Button("Rename…", systemImage: "pencil") { name = layout.name; naming = .rename }
                if layoutID != PadLayout.standard.id {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        store.delete(layoutID)
                        layoutID = PadLayout.standard.id
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(layout.name).font(.headline)
                    Image(systemName: "chevron.up.chevron.down").font(.footnote.weight(.semibold))
                }
            }
            Menu {
                ForEach(missing, id: \.self) { control in Button(control.label) { addBack(control) } }
            } label: {
                Image(systemName: "plus.circle").font(.title3)
            }
            .disabled(missing.isEmpty)
            HStack(spacing: 6) {
                Image(systemName: "circle.lefthalf.filled")
                Slider(value: Binding(get: { layout.opacity }, set: { value in var edited = layout; edited.opacity = value; store.save(edited) }),
                       in: 0.2...1)
                    .frame(width: 110)
            }
            Toggle(isOn: Binding(get: { layout.floatingLeftStick },
                                 set: { value in var edited = layout; edited.floatingLeftStick = value; store.save(edited) })) {
                Text("Floating Stick").font(.subheadline)
            }
            .fixedSize()
            Button("Reset") { reset() }
            Button("Done", action: done).fontWeight(.semibold)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .environment(\.colorScheme, .dark)
        .padding(.top, 8)
    }

    /// Standard's controls again (its opacity and floating stick too); a layout of yours keeps its name.
    private func reset() {
        var edited = PadLayout.standard
        edited.id = layout.id
        edited.name = layout.name
        store.save(edited)
        selected = nil
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if naming == .new {
            layoutID = store.add(name: trimmed).id
        } else {
            var edited = layout
            edited.name = trimmed
            store.save(edited)
        }
    }
}
