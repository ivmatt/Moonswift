import SwiftUI

/// The game's art from pressing Play until the game is showing, over the host's desktop and launchers. From Home's
/// hero it grows out of the hero to fill the screen; from anywhere else it fades in.
struct LaunchSplash: Equatable {
    static let waitChoices = [0, 1, 2, 3, 5, 8, 12]

    let title: String
    /// Its hero picture, else a cover; nil: plain black.
    let art: UIImage?
    /// Its logo, shown instead of the title, at its Logo Size.
    let logo: (image: UIImage, scale: CGFloat)?
    /// Home's hero, in screen coordinates, when it grows from there (only for a hero picture).
    let from: CGRect?
    /// How long it stays once the first picture is in, over what the host shows first.
    let wait: Duration
    /// It goes as soon as the game makes sound (half a second of it), `wait` at most.
    let endsOnSound: Bool
    /// Filling the screen (false: still the size and place of Home's hero, about to grow).
    var isGrown = true

    init(title: String, catalog: GameCatalog, from: CGRect?, wait: Int) {
        let hero = catalog.shownHero(for: title.lowercased())
        self.title = title
        art = Self.art(for: title, catalog: catalog)
        logo = Self.logo(for: title, catalog: catalog)
        self.from = hero == nil ? nil : from
        self.wait = .seconds(wait)
        endsOnSound = UserDefaults.standard.object(forKey: SettingsKey.splashEndsOnSound) as? Bool ?? SettingsDefault.splashEndsOnSound
    }

    /// The game's hero picture, else a cover; nil for none.
    static func art(for title: String, catalog: GameCatalog) -> UIImage? {
        let id = title.lowercased()
        return catalog.shownHero(for: id) ?? CoverShape.allCases.lazy.compactMap { catalog.shownCover(for: id, $0) }.first
    }

    /// The game's logo and its Logo Size (1 the usual), as Home's hero shows it; nil for none.
    static func logo(for title: String, catalog: GameCatalog) -> (image: UIImage, scale: CGFloat)? {
        let id = title.lowercased()
        guard let image = catalog.shownLogo(for: id) else { return nil }
        let size = catalog.logoSizes[id] ?? UserDefaults.standard.object(forKey: SettingsKey.logoSize) as? Int ?? SettingsDefault.logoSize
        return (image, CGFloat(size) / 100)
    }

    static func == (a: Self, b: Self) -> Bool { a.title == b.title && a.isGrown == b.isGrown }
}

/// Over the whole app, above the stream: the art filling the screen, darkened, with the title and what's happening.
struct LaunchSplashView: View {
    let splash: LaunchSplash
    let status: String?
    /// The picture is in and it's only holding: a hint that a tap or button skips the rest.
    let canSkip: Bool
    /// Until the picture is in: Cancel (and B) stops the launch.
    let cancel: (() -> Void)?
    let skip: () -> Void
    @Environment(GamepadInput.self) private var gamepad

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
                CenteredStatus(title: splash.title, logo: splash.logo, detail: status,
                               hint: canSkip ? "Tap or press any button to skip" : nil)
                    .belowCentered {
                        if let cancel {
                            // Red like Home's Quit; with a controller, the button that does it too (there's no legend here).
                            Button(action: cancel) {
                                HStack(spacing: 6) {
                                    if gamepad.isControllerConnected { ControllerHints.Icon(button: .b, size: 22, relativeTo: .headline) }
                                    Text("Cancel")
                                }
                                .font(.headline)
                                .frame(minWidth: 90)
                            }
                            .buttonStyle(.glassProminent)
                            .tint(.red)
                            .controlSize(.large)
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: cancel == nil)
                    .opacity(splash.isGrown ? 1 : 0)
            }
        }
        .ignoresSafeArea()
        .contentShape(.rect)
        .onTapGesture(perform: skip) // and it blocks touches to what's underneath
        .onGamepad(isActive: cancel != nil) { if $0 == .back { cancel?() } } // the stream screen's, once it's up
    }
}

/// The splash's and the stream's shared words: the game (its logo, else its title) large in the middle, with a spinner
/// and what's happening below. Only those two are centred: a hint or button goes under them (`belowCentered`).
struct CenteredStatus: View {
    let title: String
    var logo: (image: UIImage, scale: CGFloat)?
    let detail: String?
    var hint: String?

    private static let titleSize: CGFloat = 40

    var body: some View {
        VStack(spacing: 14) {
            if let logo {
                // As Home's hero sizes them: every logo the area of a 2.6:1 one, so wide and stacked ones weigh the same.
                let maxHeight = Self.titleSize * 3 * logo.scale
                let aspect = max(logo.image.size.width / max(logo.image.size.height, 1), 0.1)
                let height = (2.6 * pow(maxHeight * 0.85, 2) / aspect).squareRoot()
                Image(uiImage: logo.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: min(height * aspect, 560), maxHeight: height)
                    .shadow(color: .black.opacity(0.5), radius: 8)
                    .accessibilityLabel(title)
                    .padding(.bottom, 6)
            } else {
                // Wraps well short of the screen's width, rather than one line edge to edge.
                Text(title).font(.system(size: Self.titleSize, weight: .bold)).multilineTextAlignment(.center).lineLimit(3)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: 600)
            }
            HStack(spacing: 10) {
                ProgressView().tint(.white)
                if let detail { Text(detail).font(.headline).foregroundStyle(.white.opacity(0.8)) }
            }
        }
        .belowCentered {
            if let hint { Text(hint).font(.footnote).foregroundStyle(.white.opacity(0.5)) }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 40)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Puts `content` 24 points under this view without moving it: it stays centred where it was.
    func belowCentered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        overlay(alignment: .bottom) { content().alignmentGuide(.bottom) { $0[.top] - 24 } }
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
