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
        ToolbarItem(placement: .topBarTrailing) { Button("Settings", systemImage: "gearshape", action: openSettings) }
    }
}

extension TabToolbar {
    /// The toolbar runs along the top unless the Duo's side column (its toolbar and tab rail) takes room on the right,
    /// which makes the tab's right inset larger than its left (an iPhone's are equal, either side of the camera).
    /// shortcut: iOS doesn't say where it put the toolbar; this reads it from the room it takes. Revisit if it says.
    static func hasTopBar(insets: EdgeInsets) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad || insets.trailing - insets.leading < 20
    }
}
