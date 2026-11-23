import SwiftUI

extension GeometryProxy {
    /// The fold of a half-open iPhone Duo in this view's own coordinates (its margins included), or nil while the
    /// device is flat or closed, the fold misses this view, or it isn't a Duo. Apple's guidance is to keep important
    /// content off it.
    var fold: CGRect? {
        #if DEBUG
        if let fake = FakeFold.current { return fake.rect(in: self) }
        #endif
        guard #available(iOS 27.1, *) else { return nil } // no foldable iPhone runs anything older
        let bounds = CGRect(origin: .zero, size: size)
        return reservedRegions(kind: .division).lazy.filter(\.isActive).map { $0.frame.intersection(bounds) }
            .first { FoldAvoidance.isFold($0, in: self.size) }
    }
}

extension View {
    /// Keeps this view in the half below a fold across the screen; anywhere else it keeps all its room.
    func belowFold() -> some View {
        GeometryReader { proxy in
            padding(.top, proxy.fold.flatMap { $0.width >= $0.height ? $0.maxY : nil } ?? 0)
        }
    }
}

/// How a view moves its content off the fold: a fold across the screen (top and bottom halves) lifts the content
/// above it; a fold down the screen (left and right halves) keeps the content to its left.
nonisolated struct FoldAvoidance: Equatable {
    /// A fold is a thin band all the way across or down: anything else the system might report as a division is
    /// ignored rather than laid out around.
    static func isFold(_ rect: CGRect, in size: CGSize) -> Bool {
        guard !rect.isNull, !rect.isEmpty else { return false }
        return rect.width >= rect.height
            ? rect.width >= size.width * 0.9 && rect.height <= size.height * 0.25
            : rect.height >= size.height * 0.9 && rect.width <= size.width * 0.25
    }

    var lift: CGFloat = 0
    var maxWidth: CGFloat?

    init(fold: CGRect?, in size: CGSize) {
        guard let fold else { return }
        if fold.width >= fold.height {
            lift = max(0, size.height - fold.minY)
        } else if fold.minX > 0 {
            maxWidth = fold.minX
        }
    }
}

#if DEBUG
/// `-MoonswiftFold across` or `down`: acts as if the Duo were half open, with a 24-point fold through the middle of
/// the screen, across it or down it, to check layouts on the simulator, which can't fold.
enum FakeFold: String {
    case across, down

    static var current: FakeFold? { UserDefaults.standard.string(forKey: "MoonswiftFold").flatMap(FakeFold.init) }

    func rect(in proxy: GeometryProxy) -> CGRect? {
        guard let screen = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.screen.bounds }).first
        else { return nil }
        let band = self == .across ? CGRect(x: 0, y: screen.midY - 12, width: screen.width, height: 24)
                                   : CGRect(x: screen.midX - 12, y: 0, width: 24, height: screen.height)
        let frame = proxy.frame(in: .global)
        let local = band.offsetBy(dx: -frame.minX, dy: -frame.minY).intersection(CGRect(origin: .zero, size: proxy.size))
        return local.isNull || local.isEmpty ? nil : local
    }
}
#endif
