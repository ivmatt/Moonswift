import SwiftUI

/// The on-screen controller's layouts, kept on this device: Standard (editable, and Reset brings it back) and the ones
/// you make.
@Observable final class PadLayoutStore {
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

/// Editing a layout over the live game (Quick Settings → Edit Layout): drag a control to move it (it goes solid while
/// it moves; several at once, one finger each), pinch it (or use − and +) to resize it, tap it for those and Remove.
/// Along the top, in the actions row's strip (which controls stay below): + to add controls back, the layout (switch,
/// new, rename, reset, delete), opacity, and the options (the actions row and its buttons, floating sticks, Liquid
/// Glass, the grid, button labels, Hide When Idle); the blue check at the right finishes. Changes save as they're
/// made. The game, the overlay and the keyboard stay out of the way meanwhile. Touch only; B also finishes.
struct PadEditor: View {
    let store: PadLayoutStore
    /// The layout being edited (and used by this game).
    @Binding var layoutID: String
    let done: () -> Void

    @State private var selected: PadControl?
    /// The control being dragged, and where its centre was when the drag began: it moves with the finger from there,
    /// rather than jumping to put its centre under it.
    @State private var dragging: [PadControl: CGPoint] = [:] // several at once, one finger each
    /// Controls snap to a 12-point grid, measured from the edges they're placed from (Snap to Grid in the options).
    @AppStorage("padSnapToGrid") private var snapsToGrid = false
    static let gridStep: CGFloat = 12
    @State private var resizeBase: CGFloat?
    @State private var naming: NameRequest?
    @State private var menu: MenuSpec?
    /// The options sheet.
    @State private var isShowingOptions = false
    @State private var name = ""
    private enum NameRequest: Identifiable { case new, rename; var id: Self { self } }

    private var layout: PadLayout { store.layout(layoutID) }
    private var missing: [PadControl] { PadControl.allCases.filter { control in !layout.items.contains { $0.control == control } } }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { selected = nil }
            GeometryReader { proxy in
                ZStack {
                    if snapsToGrid { GridLines(area: proxy.size, step: Self.gridStep) }
                    ForEach(layout.items, id: \.control) { item in
                        editable(item, area: proxy.size)
                    }
                    // At the top, the hardest place to reach while holding the phone like a controller (Standard keeps
                    // its controls out from under it); the options drop down beneath.
                    // The actions row's strip, which controls stay below, holds the editor's pills meanwhile.
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: PadLayout.actionStrip))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: PadLayout.actionStrip))
                    }
                    .stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    .allowsHitTesting(false)
                    VStack(spacing: 8) {
                        pills
                    }
                    .environment(\.colorScheme, .dark)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, (PadLayout.actionStrip - 44) / 2) // the 44-point pills centred in the strip
                    Button(action: done) {
                        Image(systemName: "checkmark").font(.title3.weight(.bold)).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Done")
                    .padding(.top, 14).padding(.trailing, 14) // in the corner's curve, as far from both edges
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                .coordinateSpace(.named("pad"))
            }
        }
        .onGamepad { if $0 == .back { done() } }
        .sheet(isPresented: $isShowingOptions) { options }
        .actionMenu($menu)
    }

    // MARK: Controls

    private func editable(_ item: PadItem, area: CGSize) -> some View {
        let frame = item.frame(in: area)
        let isSelected = selected == item.control
        let isDragged = dragging[item.control] != nil
        return ZStack {
            let isFloating = layout.isFloating(item.control)
            PadControlView(item: item, layout: layout, area: area, presses: PadPresses())
                .saturation(isFloating ? 0 : 1)
                .opacity(isDragged ? 1 : isFloating ? layout.opacity * 0.45 : layout.opacity) // greyed: no fixed place in play
                .overlay {
                    if isFloating {
                        Text("Floating").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isDragged)
            Rectangle().fill(.clear)
                .frame(width: frame.width + 16, height: frame.height + 16)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isSelected ? Color.white : .white.opacity(0.4), style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: [5, 4]))
                }
                .contentShape(.rect)
                .position(x: frame.midX, y: frame.midY)
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("pad")).onChanged { drag in
                    let start = dragging[item.control] ?? CGPoint(x: frame.midX, y: frame.midY)
                    dragging[item.control] = start
                    if dragging.count == 1 { selected = item.control }
                    // Not into the actions row's strip.
                    let top = PadLayout.actionStrip + frame.height / 2
                    let center = CGPoint(x: min(max(start.x + drag.translation.width, 0), area.width),
                                         y: min(max(start.y + drag.translation.height, top), area.height))
                    update(item.control) {
                        $0 = $0.moved(to: center, in: area)
                        if snapsToGrid { $0 = $0.snapped(to: Self.gridStep) }
                    }
                }.onEnded { _ in dragging[item.control] = nil })
                .simultaneousGesture(MagnifyGesture().onChanged { pinch in
                    let base = resizeBase ?? item.size
                    resizeBase = base
                    update(item.control) { $0.size = Self.clamped(base * pinch.magnification) }
                }.onEnded { _ in resizeBase = nil })
                .onTapGesture { selected = isSelected ? nil : item.control }
            if isSelected, !isDragged { itemTools(item, frame: frame, area: area) }
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

    private func edit(_ change: (inout PadLayout) -> Void) {
        var edited = layout
        change(&edited)
        store.save(edited)
    }

    private func remove(_ control: PadControl) {
        edit { $0.items.removeAll { $0.control == control } }
        selected = nil
    }

    /// Back where Standard has it (the middle of the screen, for the stick clicks), at Standard's size.
    private func addBack(_ control: PadControl) {
        let standard = PadLayout.standard.items.first { $0.control == control }
        edit { $0.items.append(standard ?? PadItem(control: control, .center, .bottom, x: 0, y: 140, size: 56)) }
        selected = control
    }

    // MARK: Bar

    /// Adds a removed control back: on its own, so it reads as "add".
    private var addButton: some View {
        Menu {
            ForEach(missing, id: \.self) { control in Button(control.name(layout.labels)) { addBack(control) } }
        } label: {
            Image(systemName: "plus").font(.title3.weight(.semibold)).foregroundStyle(.white).frame(width: 46, height: 46)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(missing.isEmpty)
        .opacity(missing.isEmpty ? 0.5 : 1)
        .accessibilityLabel("Add a Control")
    }

    /// The editor's pills along the top: add a control, the layout (switch, new, rename, reset, delete), opacity, and
    /// the options; each its own glass piece.
    private var pills: some View {
        HStack(spacing: 10) {
            addButton
            Menu {
                Picker("Layout", selection: $layoutID) {
                    ForEach(store.layouts) { Text($0.name).tag($0.id) }
                }
                Divider()
                Button("New Layout", systemImage: "plus") { askName(.new) }
                Button("Duplicate", systemImage: "plus.square.on.square") { layoutID = store.add(copying: layout, name: layout.name + " Copy").id }
                Button("Rename…", systemImage: "pencil") { askName(.rename) }
                Button("Reset to Standard", systemImage: "arrow.counterclockwise") { reset() }
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
                .foregroundStyle(.white)
                .padding(.horizontal, 16).frame(height: 44)
            }
            .glassEffect(.regular.interactive(), in: .capsule)
            HStack(spacing: 6) {
                Image(systemName: "circle.lefthalf.filled")
                Slider(value: Binding(get: { layout.opacity }, set: { value in edit { $0.opacity = value } }), in: 0.2...1)
                    .frame(width: 110)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16).frame(height: 44)
            .glassEffect(.regular, in: .capsule)
            Button { isShowingOptions = true } label: {
                Image(systemName: "slider.horizontal.3").font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Layout Options")
        }
    }


    /// The layout's options: switches and choices that apply as they're set, with the panel staying open.
    /// The layout's options, as a sheet: half height, so the controls show above it and each change can be seen at
    /// once; it stays until Done. The actions row's buttons can be added, removed and dragged into order.
    private var options: some View {
        let shortcuts = KeyShortcutStore().all
        let available = (GestureAction.fixed.filter { $0 != .nothing && $0 != .controlPanel } + shortcuts.map { .shortcut($0.id) })
            .filter { !layout.actions.contains($0) }
        return NavigationStack {
            Form {
                Section {
                    // Always there, always first: the way back to the control panel.
                    HStack(spacing: 12) {
                        ActionButtonFace(action: .controlPanel, shortcuts: shortcuts, isGlass: false).scaleEffect(0.8)
                        Text("Control Center")
                        Spacer()
                        Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    }
                    .moveDisabled(true)
                    .deleteDisabled(true)
                    ForEach(Array(layout.actions.enumerated()), id: \.offset) { _, action in
                        HStack(spacing: 12) {
                            ActionButtonFace(action: action, shortcuts: shortcuts, isGlass: false).scaleEffect(0.8)
                            Text(action.title(shortcuts))
                        }
                    }
                    .onDelete { offsets in edit { $0.actions.remove(atOffsets: offsets) } }
                    .onMove { from, to in edit { $0.actions.move(fromOffsets: from, toOffset: to) } }
                    Menu {
                        ForEach(available, id: \.self) { action in Button(action.title(shortcuts)) { edit { $0.actions.append(action) } } }
                    } label: {
                        Label("Add Action", systemImage: "plus.circle.fill")
                    }
                    .disabled(available.isEmpty)
                    Toggle("Show on Touch", isOn: Binding(get: { layout.actionsOnTouch }, set: { value in edit { $0.actionsOnTouch = value } }))
                    Picker("Position", selection: Binding(get: { layout.actionsPosition }, set: { value in edit { $0.actionsPosition = value } })) {
                        ForEach(PadRowPosition.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } header: {
                    Text("Actions Row")
                } footer: {
                    Text("Control Center always comes first. Add Quick Settings, the keyboard, Edit Layout or key shortcuts, and "
                         + "drag to reorder. Show on Touch hides the row until you touch the top strip.")
                }
                Section {
                    Toggle("Floating Left Stick", isOn: Binding(get: { layout.floatingLeftStick }, set: { value in edit { $0.floatingLeftStick = value } }))
                    Toggle("Floating Right Stick", isOn: Binding(get: { layout.floatingRightStick }, set: { value in edit { $0.floatingRightStick = value } }))
                } footer: {
                    Text("Appears where your thumb lands on its side of the screen, away from other controls.")
                }
                Section {
                    Toggle("Liquid Glass", isOn: Binding(get: { layout.glass }, set: { value in edit { $0.glass = value } }))
                    Picker("Button Labels", selection: Binding(get: { layout.labels }, set: { value in edit { $0.labels = value } })) {
                        ForEach(PadLabels.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Hide When Idle", selection: Binding(get: { layout.hideAfter }, set: { value in edit { $0.hideAfter = value } })) {
                        ForEach([0, 3, 5, 10, 20], id: \.self) { Text($0 == 0 ? "Never" : "After \($0) s").tag($0) }
                    }
                } footer: {
                    Text("Hide When Idle fades the controls when untouched. A touch brings them back.")
                }
                Section {
                    Toggle("Snap to Grid", isOn: $snapsToGrid)
                }
            }
            .environment(\.editMode, .constant(.active)) // the row's drag handles and delete buttons
            .navigationTitle("Layout Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { isShowingOptions = false } } }
        }
        .presentationDetents([.large]) // all of it at once: half-open hid most options
        .presentationBackground(Color(white: 0.11)) // plain dark grey, not glass
        .presentationBackgroundInteraction(.enabled(upThrough: .medium)) // the controls stay movable above it
        .onGamepad { if $0 == .back { isShowingOptions = false } } // B closes this, not the editor
    }

    /// Standard's controls again; a layout keeps its name, look and options.
    private func reset() {
        edit { $0.items = PadLayout.standard.items }
        selected = nil
    }

    private func askName(_ request: NameRequest) {
        naming = request
        name = request == .new ? "" : layout.name
        menu = MenuSpec(title: request == .new ? "New Layout" : "Rename Layout", field: .init(placeholder: "Name", text: $name),
                        actions: [.init(title: "Save") { saveName() }], cancelTitle: "Cancel", closable: false)
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if naming == .new {
            layoutID = store.add(name: trimmed).id
        } else {
            edit { $0.name = trimmed }
        }
    }
}

/// Faint lines where controls snap: every 12 points from the left and right edges (each on its half), from the middle
/// in the central fifth, and from the top and bottom edges, as positions are measured (PadItem).
private struct GridLines: View {
    let area: CGSize
    let step: CGFloat

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let (w, h) = (size.width, size.height), middle = w / 2, band = w * 0.1
            func vertical(_ x: CGFloat) { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: h)) }
            func horizontal(_ y: CGFloat) { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: w, y: y)) }
            for x in stride(from: 0, to: middle - band, by: step) { vertical(x) } // from the left edge
            for x in stride(from: 0, to: middle - band, by: step) { vertical(w - x) } // from the right edge
            for d in stride(from: 0, to: band, by: step) { vertical(middle + d); vertical(middle - d) } // from the middle
            for y in stride(from: 0, through: h / 2, by: step) { horizontal(y); horizontal(h - y) } // from top and bottom
            context.stroke(path, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
        }
        .frame(width: area.width, height: area.height)
        .allowsHitTesting(false)
    }
}
