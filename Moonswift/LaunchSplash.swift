import SwiftUI

/// The game's art from pressing Play until the game is showing, over the host's desktop and launchers. From Home's
/// hero it grows out of the hero to fill the screen; from anywhere else it fades in.
struct LaunchSplash: Equatable {
    static let defaultWait = 3
    static let waitChoices = [0, 1, 2, 3, 5, 8, 12]

    let title: String
    /// Its hero picture, else a cover; nil: plain black.
    let art: UIImage?
    /// Home's hero, in screen coordinates, when it grows from there (only for a hero picture).
    let from: CGRect?
    /// How long it stays once the first picture is in, over what the host shows first.
    let wait: Duration
    /// Beta: it goes as soon as the game makes sound (half a second of it), `wait` at most.
    let endsOnSound: Bool
    /// Filling the screen (false: still the size and place of Home's hero, about to grow).
    var isGrown = true

    @MainActor init(title: String, catalog: GameCatalog, from: CGRect?, wait: Int) {
        let id = title.lowercased()
        let hero = catalog.heroArt[id]
        self.title = title
        art = hero ?? CoverShape.allCases.lazy.compactMap { catalog.cover(for: id, $0) }.first
        self.from = hero == nil ? nil : from
        self.wait = .seconds(wait)
        endsOnSound = UserDefaults.standard.bool(forKey: SettingsKey.splashEndsOnSound)
    }

    static func == (a: Self, b: Self) -> Bool { a.title == b.title && a.isGrown == b.isGrown }
}

/// Over the whole app, above the stream: the art filling the screen, darkened, with the title and what's happening.
struct LaunchSplashView: View {
    let splash: LaunchSplash
    let status: String?
    /// The picture is in and it's only holding: a hint that a tap or button skips the rest.
    let canSkip: Bool
    let skip: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let screen = CGRect(origin: .zero, size: proxy.size)
            let rect = splash.isGrown ? screen : splash.from ?? screen
            ZStack {
                Color.black.opacity(splash.isGrown ? 1 : 0)
                if let art = splash.art {
                    // Starts looking as Home draws it (fading out at the bottom, darker on the left), then darkens.
                    Color.clear
                        .overlay { Image(uiImage: art).resizable().scaledToFill() }
                        .overlay {
                            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .leading, endPoint: .center)
                                .opacity(splash.isGrown ? 0 : 1)
                        }
                        .overlay { DimmedBlur().opacity(splash.isGrown ? 1 : 0) } // the same as the stream's
                        .clipped()
                        .mask {
                            VStack(spacing: 0) {
                                Color.black
                                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                    .frame(height: splash.isGrown ? 0 : rect.height * 0.45)
                            }
                        }
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
                CenteredStatus(title: splash.title, detail: status, hint: canSkip ? "Tap or press any button to skip" : nil)
                    .opacity(splash.isGrown ? 1 : 0)
            }
        }
        .ignoresSafeArea()
        .contentShape(.rect)
        .onTapGesture(perform: skip) // and it blocks touches to what's underneath
    }
}

/// The splash's and the stream's shared words: large in the middle, with a spinner and what's happening below.
struct CenteredStatus: View {
    let title: String
    let detail: String?
    var hint: String?

    var body: some View {
        VStack(spacing: 14) {
            Text(title).font(.system(size: 40, weight: .bold)).multilineTextAlignment(.center).lineLimit(3)
                .minimumScaleFactor(0.6)
            HStack(spacing: 10) {
                ProgressView().tint(.white)
                if let detail { Text(detail).font(.headline).foregroundStyle(.white.opacity(0.8)) }
            }
            Text(hint ?? " ").font(.footnote).foregroundStyle(.white.opacity(0.5)).opacity(hint == nil ? 0 : 1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 40)
        .accessibilityElement(children: .combine)
    }
}

/// The splash's and the stream's shared backdrop: a moderate blur (between the system's materials and none) and
/// darkening, over the art or the frozen last frame.
struct DimmedBlur: View {
    static let darkening = 0.7

    var body: some View {
        ZStack {
            PartialBlur(fraction: 0.3)
            Color.black.opacity(Self.darkening)
        }
    }
}

/// A blur only part of the way to the system's full one: a paused blur animation, the usual way to get one in between.
private struct PartialBlur: UIViewRepresentable {
    let fraction: CGFloat

    final class Coordinator { var animator: UIViewPropertyAnimator? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: nil)
        let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) { view.effect = UIBlurEffect(style: .dark) }
        animator.pausesOnCompletion = true
        animator.fractionComplete = fraction
        context.coordinator.animator = animator
        return view
    }

    func updateUIView(_ view: UIVisualEffectView, context: Context) {}

    static func dismantleUIView(_ view: UIVisualEffectView, coordinator: Coordinator) {
        coordinator.animator?.stopAnimation(true) // a paused animator mustn't be released as it is
        coordinator.animator = nil
    }
}
