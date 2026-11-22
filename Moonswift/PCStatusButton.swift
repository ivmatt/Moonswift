import SwiftData
import SwiftUI

/// What one PC's line in Home's status says, and how much it needs your attention.
nonisolated struct PCStatusLine: Equatable {
    /// Worst last: the button shows the worst of all PCs.
    enum Health: Int, Comparable {
        case fine, checking, problem, offline
        static func < (a: Health, b: Health) -> Bool { a.rawValue < b.rawValue }
    }

    let text: String
    /// The smaller line under it, in Home's status menu.
    var detail: String?
    let health: Health
    /// A missed answer: still counted as it was, but worth a word in the details.
    var isWaiting = false

    /// `checkedAgo` is the seconds since it last answered (nil: not known, as in demo mode); `connection` is
    /// "Local" or "Remote" when known.
    static func make(status: HostStatus?, isNotResponding: Bool, isFetching: Bool, fetchFailed: Bool,
                     hasSavedGames: Bool, checkedAgo: Int?, connection: String? = nil) -> PCStatusLine {
        switch status {
        case nil: return .init(text: "Checking…", health: .checking)
        case .offline: return .init(text: "Offline", detail: hasSavedGames ? "Showing saved games" : nil, health: .offline)
        case .online(paired: false): return .init(text: "Not paired", detail: "Pair it again in Hosts", health: .problem)
        case .online(paired: true):
            if isNotResponding { return .init(text: "Not responding…", health: .fine, isWaiting: true) }
            if fetchFailed { return .init(text: "Couldn't get games", detail: "Showing saved ones", health: .problem) }
            if isFetching { return .init(text: "Getting games…", health: .fine) }
            let ago = checkedAgo.map { $0 < 2 ? "Checked just now" : $0 < 60 ? "Checked \($0)s ago" : "Checked \($0 / 60)m ago" }
            return .init(text: "Online" + (connection.map { " · \($0)" } ?? ""), detail: ago, health: .fine)
        }
    }
}

/// Home's status button, a system toolbar item (on the Duo the system puts it in the side column): the PC with a
/// traffic-light dot (green while every PC is fine, orange when one isn't paired or won't send its games, red when
/// one is offline), and a spinning arc exactly while Play, Resume and Quit wait for a host's status
/// (`PCDirectory.isWaiting`; never for the regular checks). Tap for a menu of each PC's status and Refresh. Controller: View refreshes.
struct PCStatusButton: View {
    var refresh: () -> Void
    /// The controller is on it: A opens Home's own copy of its menu (the system's opens only by touch).
    var isFocused = false
    /// Its controller menu is open over it: shrunk and faded into it, as the menu grows out of it.
    var isHidden = false
    /// Next to the floating tab bar (iPhone in landscape): its icon and text at the bar's size, so it doesn't loom.
    var isCompact = false

    @Environment(PCDirectory.self) private var directory
    @Environment(GameCatalog.self) private var catalog
    @Environment(StreamLauncher.self) private var launcher
    @Query(sort: \SavedHost.name) private var hosts: [SavedHost]

    private func line(_ host: SavedHost, now: Date) -> PCStatusLine {
        Self.line(host, directory: directory, catalog: catalog, now: now)
    }

    /// One host's status line; with no `now`, without when it was last checked.
    static func line(_ host: SavedHost, directory: PCDirectory, catalog: GameCatalog, now: Date?) -> PCStatusLine {
        let id = host.uniqueID
        if directory.waking.contains(id), directory.statuses[id] == .offline { return .init(text: "Waking…", health: .checking) }
        return .make(status: directory.statuses[id], isNotResponding: directory.notResponding.contains(id),
                     isFetching: catalog.fetching.contains(id), fetchFailed: catalog.fetchFailed.contains(id),
                     hasSavedGames: !(catalog.apps[id] ?? []).isEmpty,
                     checkedAgo: now.flatMap { now in directory.lastChecked[id].map { Int(now.timeIntervalSince($0)) } },
                     connection: directory.connection(of: id))
    }

    private var worst: PCStatusLine.Health { hosts.map { line($0, now: .now).health }.max() ?? .fine }

    private var isSpinning: Bool { hosts.contains { directory.isWaiting(on: $0.uniqueID, launcher) } }

    private var word: String {
        if isSpinning { return "Checking…" }
        if !directory.waking.isEmpty { return "Waking…" }
        return switch worst {
        case .fine: "Online"
        case .checking: "Checking…"
        case .problem: "Needs Attention"
        case .offline: "Offline"
        }
    }

    private var dot: Color {
        switch worst {
        case .fine, .checking: .green
        case .problem: .orange
        case .offline: .red
        }
    }

    var body: some View {
        Menu {
            ForEach(hosts) { host in
                let line = line(host, now: .now)
                Section(host.displayName) {
                    // A system menu paints a plain symbol in its text colour; an image with its own colour keeps it.
                    let dot = Image(uiImage: (UIImage(systemName: "circle.fill") ?? UIImage())
                        .withTintColor(UIColor(Self.color(line)), renderingMode: .alwaysOriginal))
                    // Only a button's label gets a subtitle in a system menu: its second Text, with no `if` between them.
                    Group {
                        if let detail = line.detail {
                            Button {} label: { Text(line.text); Text(detail); dot }
                        } else {
                            Button {} label: { Text(line.text); dot }
                        }
                    }
                    .disabled(true) // information, not an action
                }
            }
            Divider()
            Button("Refresh", systemImage: "arrow.clockwise", action: refresh).disabled(directory.isRefreshing)
        } label: {
            // A pill in place of Home's title: the PC with its traffic-light dot (or the arc while it checks), and
            // the status in a word, so the dot's colour comes with its meaning.
            HStack(spacing: isCompact ? 8 : 10) {
                Image(systemName: "desktopcomputer")
                    .font(isCompact ? .system(size: 15, weight: .medium) : nil)
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(dot)
                            .frame(width: isCompact ? 8 : 9, height: isCompact ? 8 : 9)
                            .overlay { Circle().stroke(.black.opacity(0.35), lineWidth: 1) } // shows on light and dark glass
                            .offset(x: 3, y: 1)
                    }
                    // Shrinks and fades into the arc, and back.
                    .opacity(isSpinning ? 0 : 1)
                    .scaleEffect(isSpinning ? 0.5 : 1)
                    .overlay {
                        if isSpinning { ArcSpinner().transition(.opacity.combined(with: .scale(scale: 0.5))) }
                    }
                Text(word).contentTransition(.opacity)
                    .font(isCompact ? .system(size: 13, weight: .semibold) : nil)
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, isCompact ? 14 : 16)
            .frame(height: 44) // the standard button height, like the gear's
            .glassEffect(.regular.interactive(), in: .capsule)
            .tint(.primary) // white words, not the accent colour a menu gives its label
        }
        .focusRing(isFocused, cornerRadius: .infinity)
        .scaleEffect(isHidden ? 0.6 : 1, anchor: .leading)
        .opacity(isHidden ? 0 : 1)
        .animation(.spring(duration: 0.3, bounce: 0.2), value: isHidden) // in step with the menu growing out of it
        .animation(.default, value: worst)
        .animation(.spring(duration: 0.35), value: isSpinning)
        .accessibilityLabel("Host Status")
        .accessibilityValue(hosts.map { host in
            let line = line(host, now: .now)
            return "\(host.displayName): \([line.text, line.detail].compactMap(\.self).joined(separator: ", "))"
        }.joined(separator: ", "))
    }

    /// A host's dot in the menu.
    static func color(_ line: PCStatusLine) -> Color {
        if line.isWaiting { return .yellow }
        return switch line.health {
        case .fine: .green
        case .checking: .secondary
        case .problem: .orange
        case .offline: .red // the button's traffic light
        }
    }
}

/// An open ring turning, like a loading arc: the status button's "checking" icon, and the app's spinner elsewhere.
struct ArcSpinner: View {
    var size: CGFloat = 18

    @State private var isTurning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(isTurning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: isTurning)
            .onAppear { isTurning = true }
            .accessibilityHidden(true)
    }
}
