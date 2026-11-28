import SwiftUI

/// A tab's toolbar buttons with the Settings gear, which every tab has in the same spot so it's easy to find: the top
/// of the Duo's side column (the first button there), the right end of a top bar (the last button there).
struct TabToolbar<Other: View>: ToolbarContent {
    /// The tab's toolbar runs along the top (iPhone, iPad), rather than down the Duo's side column.
    let hasTopBar: Bool
    let openSettings: () -> Void
    /// The tab's own button, if it has one (Home's host status, Library's filter).
    @ViewBuilder var other: Other

    var body: some ToolbarContent {
        if hasTopBar {
            if Other.self != EmptyView.self { ToolbarItem(placement: .topBarTrailing) { other } }
            gear
        } else {
            gear
            if Other.self != EmptyView.self { ToolbarItem(placement: .topBarTrailing) { other } }
        }
    }

    private var gear: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { Button("Settings", systemImage: "gear", action: openSettings) }
    }
}

extension TabToolbar {
    /// The toolbar runs along the top unless the Duo's side column (its toolbar and tab rail) takes room on one side,
    /// which makes that inset larger than the other (an iPhone's are equal, either side of the camera). The column is
    /// on the left with the folded Duo turned curved side up.
    /// shortcut: iOS doesn't say where it put the toolbar; this reads it from the room it takes. Revisit if it says.
    static func hasTopBar(insets: EdgeInsets) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad || abs(insets.trailing - insets.leading) < 20
    }

    /// Where the system toolbar puts a corner button (Back, Cancel, the gear), from the screen's edge, so the app's own
    /// match it: an iPhone's sit 38 points in, inside the landscape safe area; an iPad's 10; the folded Duo's at the
    /// safe area's edge, clear of the camera. Measured on iOS 27 simulators.
    static func cornerInset(insets: EdgeInsets) -> CGFloat {
        if UIDevice.current.userInterfaceIdiom == .pad { return 10 }
        return hasTopBar(insets: insets) ? 38 : max(insets.leading, 10)
    }

    /// The Duo's side column is on the left (folded, curved side up).
    static func isRailOnLeft(insets: EdgeInsets) -> Bool {
        UIDevice.current.userInterfaceIdiom != .pad && insets.leading - insets.trailing >= 20
    }
}

extension View {
    /// The bar's title as its middle item, as Settings' Stream/Interface switch is: on the folded Duo a bar without one
    /// puts its title by the camera and drops Back or Save into the side column below it.
    func barTitle(_ title: String) -> some View {
        navigationTitle(title)
            .toolbar { ToolbarItem(placement: .principal) { Text(title).font(.headline).lineLimit(1) } }
    }
}

extension View {
    /// A sheet's bar stays put while its rows scroll: on the folded Duo's short screen iOS 27 slides it away on scroll
    /// down, taking Done with it. (The Duo needs iOS 27, so earlier systems have nothing to turn off.)
    @ViewBuilder func pinnedBar() -> some View {
        if #available(iOS 27, *) { toolbarMinimizationBehavior(.never, for: .navigationBar) } else { self }
    }
}

extension View {
    /// A pushed Settings page's title and Back. The folded Duo's system bar keeps its leading corner for the camera and
    /// drops Back into the side column below the title, whatever the page puts there, so there the page draws its own
    /// row, as Add a Host does.
    func subpageBar(_ title: String) -> some View { modifier(SubpageBar(title: title)) }
}

private struct SubpageBar: ViewModifier {
    let title: String
    @Environment(\.dismiss) private var dismiss

    /// The window's, not the page's: the page's change with the bar it shows, so they'd flip the choice back and forth.
    private var insets: EdgeInsets {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let i = window?.safeAreaInsets ?? .zero
        return EdgeInsets(top: i.top, leading: i.left, bottom: i.bottom, trailing: i.right)
    }

    func body(content: Content) -> some View {
        if TabToolbar<EmptyView>.hasTopBar(insets: insets) {
            content.barTitle(title)
        } else {
            content
                .navigationTitle(title)
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaBar(edge: .top) { header } // blurs the rows scrolling under it, as the system bar does
                .overlay(alignment: .leading) { swipeEdge }
        }
    }

    private var header: some View {
        ZStack(alignment: .leading) {
            Text(title).font(.headline).lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 60) // clear of Back; centred as the Stream/Interface switch is
            // At the safe area's edge, in line with the rows below and clear of the camera.
            Button("Back", systemImage: "chevron.backward") { dismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        }
        .controlSize(.large)
        .frame(minHeight: 48)
        .padding(.top, 16) // level with Done on the Settings page below it
        .padding(.bottom, 4)
        .tint(.primary)
    }

    /// The system's back swipe goes with its bar.
    private var swipeEdge: some View {
        Color.clear
            .frame(width: 24)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 10).onEnded { drag in
                if drag.translation.width > 60 && abs(drag.translation.height) < drag.translation.width { dismiss() }
            })
            .ignoresSafeArea()
    }
}

extension View {
    /// A taller page-sized sheet on 12.9" and 13" iPads, whose form sheet is no bigger than the mini's and scrolls.
    /// The app is landscape only, so the screen's short side is the window's height: 1024+ pt on those, 834 on the 11".
    @ViewBuilder func roomySheet() -> some View {
        let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.size ?? .zero
        if min(screen.width, screen.height) >= 1000 { presentationSizing(.page) } else { self }
    }
}
