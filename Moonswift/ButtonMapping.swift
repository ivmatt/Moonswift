import Foundation
import MoonlightCore

/// The buttons a remap can move, by their Xbox-style name (PlayStation symbols alongside).
nonisolated enum GameButton: String, CaseIterable, Codable, Sendable {
    case a, b, x, y, up, down, left, right, leftShoulder, rightShoulder, leftStick, rightStick, menu, view, home

    var title: String {
        switch self {
        case .a: "A / ✕"
        case .b: "B / ○"
        case .x: "X / □"
        case .y: "Y / △"
        case .up: "D-pad Up"
        case .down: "D-pad Down"
        case .left: "D-pad Left"
        case .right: "D-pad Right"
        case .leftShoulder: "LB / L1"
        case .rightShoulder: "RB / R1"
        case .leftStick: "Left Stick Click"
        case .rightStick: "Right Stick Click"
        case .menu: "Menu / Options"
        case .view: "View / Create"
        case .home: "Home / PS"
        }
    }

    /// The library's button bit.
    var flag: Int32 {
        switch self {
        case .a: A_FLAG
        case .b: B_FLAG
        case .x: X_FLAG
        case .y: Y_FLAG
        case .up: UP_FLAG
        case .down: DOWN_FLAG
        case .left: LEFT_FLAG
        case .right: RIGHT_FLAG
        case .leftShoulder: LB_FLAG
        case .rightShoulder: RB_FLAG
        case .leftStick: LS_CLK_FLAG
        case .rightStick: RS_CLK_FLAG
        case .menu: PLAY_FLAG
        case .view: BACK_FLAG
        case .home: SPECIAL_FLAG
        }
    }
}

/// Which button the PC sees when each physical button is pressed. Applies to every controller, in games and in the
/// app's menus (so with A and B swapped, the confirm button is the same everywhere).
nonisolated struct ButtonRemap: Codable, Equatable, Sendable {
    /// Physical button → the button it acts as. Buttons not listed act as themselves.
    var targets: [GameButton: GameButton] = [:]

    static let standard = ButtonRemap()
    /// Nintendo's layout has A and B, and X and Y, the other way round.
    static let nintendo = ButtonRemap(targets: [.a: .b, .b: .a, .x: .y, .y: .x])

    func target(_ button: GameButton) -> GameButton { targets[button] ?? button }

    /// The PC's button bits after remapping the pressed ones.
    func apply(_ flags: Int32) -> Int32 {
        guard !targets.isEmpty else { return flags }
        var result = flags
        for source in targets.keys { result &= ~source.flag } // moved buttons no longer press themselves...
        for (source, target) in targets where flags & source.flag != 0 { result |= target.flag } // ...but their target
        return result
    }

    /// Kept on this device; read once at launch and whenever it's changed.
    @MainActor static var current: ButtonRemap = load() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(current), forKey: "buttonRemap") }
    }

    private static func load() -> ButtonRemap {
        UserDefaults.standard.data(forKey: "buttonRemap").flatMap { try? JSONDecoder().decode(ButtonRemap.self, from: $0) } ?? .standard
    }
}
