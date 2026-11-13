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
        case .online(paired: false): return .init(text: "Not paired · pair it again in PCs", health: .problem)
        case .online(paired: true):
            if isNotResponding { return .init(text: "Not responding…", health: .fine, isWaiting: true) }
            if fetchFailed { return .init(text: "Couldn't get its games · showing saved ones", health: .problem) }
            if isFetching { return .init(text: "Getting games…", health: .fine) }
            let ago = checkedAgo.map { $0 < 2 ? " · checked just now" : $0 < 60 ? " · checked \($0)s ago" : " · checked \($0 / 60)m ago" }
            return .init(text: "Up to date" + (ago ?? ""), health: .fine)
        }
    }
}

/// Home's status button, where Refresh was: the refresh arrow while every PC is fine, and otherwise what needs your
/// attention (Wi-Fi crossed out for an offline PC, a warning for one that isn't paired or won't send its games). It
/// spins at launch until the first answer and while you refresh, never for the checks in between. Tap for each PC's
/// details and Refresh; hold to refresh straight away. Controller: View refreshes.
struct PCStatusButton: View {
    var refresh: () -> Void
    var isRefreshing: Bool

    @Environment(PCDirectory.self) private var directory
    @Environment(GameCatalog.self) private var catalog
    @Query(sort: \SavedHost.name) private var hosts: [SavedHost]
    @State private var isShowingDetails = false

    private func line(_ host: SavedHost, now: Date) -> PCStatusLine {
        let id = host.uniqueID
        return .make(status: directory.statuses[id], isNotResponding: directory.notResponding.contains(id),
                     isFetching: catalog.fetching.contains(id), fetchFailed: catalog.fetchFailed.contains(id),
                     hasSavedGames: !(catalog.apps[id] ?? []).isEmpty,
                     checkedAgo: directory.lastChecked[id].map { Int(now.timeIntervalSince($0)) })
    }

    private var worst: PCStatusLine.Health { hosts.map { line($0, now: .now).health }.max() ?? .fine }

    private var icon: String {
        switch worst {
        case .offline: "wifi.slash"
        case .problem: "exclamationmark.triangle"
        case .fine, .checking: "arrow.clockwise"
        }
    }

    var body: some View {
        FunctionButtonLabel(systemImage: icon, isSpinning: isRefreshing || worst == .checking)
            .foregroundStyle(worst == .problem ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
            .onTapGesture { isShowingDetails = true }
            .onLongPressGesture { if !isRefreshing { refresh() } }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("PC Status")
            .accessibilityValue(hosts.map { "\($0.displayName): \(line($0, now: .now).text)" }.joined(separator: ", "))
            .accessibilityAction { isShowingDetails = true }
            .accessibilityAction(named: "Refresh", refresh)
            .popover(isPresented: $isShowingDetails, arrowEdge: .top) {
                details.presentationCompactAdaptation(.popover) // a popover on the phone too, not a sheet
            }
    }

    private var details: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in // "checked 3s ago" keeps counting
            VStack(alignment: .leading, spacing: 12) {
                ForEach(hosts) { host in
                    let line = line(host, now: context.date)
                    HStack(spacing: 10) {
                        Circle().fill(color(line)).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(host.displayName).font(.headline)
                            Text(line.text).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                Divider()
                Button("Refresh", systemImage: "arrow.clockwise", action: refresh).disabled(isRefreshing)
            }
            .padding(16)
            .frame(minWidth: 280, alignment: .leading)
        }
    }

    private func color(_ line: PCStatusLine) -> Color {
        if line.isWaiting { return .yellow }
        return switch line.health {
        case .fine: .green
        case .checking, .offline: .secondary
        case .problem: .orange
        }
    }
}
