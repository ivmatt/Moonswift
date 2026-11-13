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
    let health: Health
    /// A missed answer: still counted as it was, but worth a word in the details.
    var isWaiting = false

    /// `checkedAgo` is the seconds since it last answered (nil: not known, as in demo mode).
    static func make(status: HostStatus?, isNotResponding: Bool, isFetching: Bool, fetchFailed: Bool,
                     hasSavedGames: Bool, checkedAgo: Int?) -> PCStatusLine {
        switch status {
        case nil: return .init(text: "Checking…", health: .checking)
        case .offline: return .init(text: hasSavedGames ? "Offline · showing saved games" : "Offline", health: .offline)
        case .online(paired: false): return .init(text: "Not paired · pair it again in Hosts", health: .problem)
        case .online(paired: true):
            if isNotResponding { return .init(text: "Not responding…", health: .fine, isWaiting: true) }
            if fetchFailed { return .init(text: "Couldn't get its games · showing saved ones", health: .problem) }
            if isFetching { return .init(text: "Getting games…", health: .fine) }
            let ago = checkedAgo.map { $0 < 2 ? " · checked just now" : $0 < 60 ? " · checked \($0)s ago" : " · checked \($0 / 60)m ago" }
            return .init(text: "Up to date" + (ago ?? ""), health: .fine)
        }
    }
}

/// Home's status button, a system toolbar item (on the Duo the system puts it in the side column): the PC with a
/// traffic-light dot (green while every PC is fine, orange when one isn't paired or won't send its games, red when
/// one is offline), and a spinning arc at launch until the first answer and while you refresh (never for the checks
/// in between). Tap for a menu of each PC's status and Refresh. Controller: View refreshes.
struct PCStatusButton: View {
    var refresh: () -> Void
    var isRefreshing: Bool

    @Environment(PCDirectory.self) private var directory
    @Environment(GameCatalog.self) private var catalog
    @Query(sort: \SavedHost.name) private var hosts: [SavedHost]

    private func line(_ host: SavedHost, now: Date) -> PCStatusLine {
        let id = host.uniqueID
        return .make(status: directory.statuses[id], isNotResponding: directory.notResponding.contains(id),
                     isFetching: catalog.fetching.contains(id), fetchFailed: catalog.fetchFailed.contains(id),
                     hasSavedGames: !(catalog.apps[id] ?? []).isEmpty,
                     checkedAgo: directory.lastChecked[id].map { Int(now.timeIntervalSince($0)) })
    }

    private var worst: PCStatusLine.Health { hosts.map { line($0, now: .now).health }.max() ?? .fine }

    private var isSpinning: Bool { isRefreshing || worst == .checking }

    private var dot: Color {
        switch worst {
        case .fine, .checking: .green
        case .problem: .orange
        case .offline: .red
        }
    }

    var body: some View {
        // A menu rather than a popover: from a toolbar button a popover took two taps to close and then two to open.
        Menu {
            ForEach(hosts) { host in
                let line = line(host, now: .now)
                Section(host.displayName) {
                    Label {
                        Text(line.text)
                    } icon: {
                        Image(systemName: "circle.fill").symbolRenderingMode(.palette).foregroundStyle(color(line))
                    }
                }
            }
            Divider()
            Button("Refresh", systemImage: "arrow.clockwise", action: refresh).disabled(isRefreshing)
        } label: {
            // Always the symbol, the arc drawn over it while it spins: on the Duo the system keeps only symbols in
            // the side column, and moved the button to a bar along the bottom while the arc stood in for it.
            Image(systemName: "desktopcomputer")
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(dot)
                        .frame(width: 9, height: 9)
                        .overlay { Circle().stroke(.black.opacity(0.35), lineWidth: 1) } // shows on light and dark glass
                        .offset(x: 3, y: 1)
                }
                // Shrinks and fades into the arc, and back.
                .opacity(isSpinning ? 0 : 1)
                .scaleEffect(isSpinning ? 0.5 : 1)
                .overlay {
                    if isSpinning { ArcSpinner().transition(.opacity.combined(with: .scale(scale: 0.5))) }
                }
        }
        .animation(.default, value: worst)
        .animation(.spring(duration: 0.35), value: isSpinning)
        .accessibilityLabel("Host Status")
        .accessibilityValue(hosts.map { "\($0.displayName): \(line($0, now: .now).text)" }.joined(separator: ", "))
    }

    private func color(_ line: PCStatusLine) -> Color {
        if line.isWaiting { return .yellow }
        return switch line.health {
        case .fine: .green
        case .checking: .secondary
        case .problem: .orange
        case .offline: .red // the button's traffic light
        }
    }
}

/// An open ring turning, like a loading arc: the button's "checking" icon.
private struct ArcSpinner: View {
    @State private var isTurning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            .frame(width: 18, height: 18)
            .rotationEffect(.degrees(isTurning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: isTurning)
            .onAppear { isTurning = true }
            .accessibilityHidden(true)
    }
}
