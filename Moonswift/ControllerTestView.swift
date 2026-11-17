import GameController
import SwiftUI

/// Settings → Controller Test: the connected controller's buttons, sticks and triggers as it reports them (before
/// Button Mapping), and on a DualSense, adaptive trigger effects played through the same code the host's effects use.
/// Every button lights up here instead of navigating; holding B leaves.
struct ControllerTestView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sample: Sample?
    @State private var effects: (left: TriggerPreset, right: TriggerPreset) = (.off, .off)
    /// The motors tried so far (made on first use, as the stream's rumble makes them), and the one buzzing now.
    @State private var motors: [GCHapticsLocality: HapticMotor] = [:]
    @State private var rumbling: GCHapticsLocality?

    var body: some View {
        List {
            if let sample {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 10)], spacing: 10) {
                        ForEach(sample.buttons, id: \.label) { button in
                            Image(systemName: button.symbol)
                                .font(.system(size: 26))
                                .foregroundStyle(button.isPressed ? Color.black : .primary)
                                .frame(width: 52, height: 52)
                                .background(button.isPressed ? Color.white : Color.white.opacity(0.08), in: .circle)
                                .accessibilityLabel(button.label)
                                .accessibilityValue(button.isPressed ? "Pressed" : "")
                        }
                    }
                    .padding(.vertical, 6)
                    HStack(spacing: 24) {
                        StickView(position: sample.leftStick, label: "Left stick")
                        TriggerBar(value: sample.leftTrigger, label: "Left trigger")
                        TriggerBar(value: sample.rightTrigger, label: "Right trigger")
                        StickView(position: sample.rightStick, label: "Right stick")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                } header: {
                    Text(sample.name)
                } footer: {
                    Text("What the controller sends, before Button Mapping. Hold B to leave.")
                }
                if !sample.motors.isEmpty {
                    Section {
                        ForEach(sample.motors, id: \.locality) { motor in
                            Button {
                                rumble(motor.locality)
                            } label: {
                                HStack {
                                    Text(motor.label)
                                    Spacer()
                                    if rumbling == motor.locality { Image(systemName: "waveform").symbolEffect(.variableColor) }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    } header: {
                        Text("Rumble")
                    } footer: {
                        Text("A second at full strength, through the same motors a game's rumble uses.")
                    }
                }
                if sample.isDualSense {
                    Section {
                        Picker("Left Trigger", selection: $effects.left) {
                            ForEach(TriggerPreset.allCases, id: \.self) { Text($0.rawValue) }
                        }
                        Picker("Right Trigger", selection: $effects.right) {
                            ForEach(TriggerPreset.allCases, id: \.self) { Text($0.rawValue) }
                        }
                    } header: {
                        Text("Adaptive Triggers")
                    } footer: {
                        Text("Each effect goes through the same code as a game's, so this checks the controller and Moonswift. "
                             + "In a game, the host also has to send the effects.")
                    }
                }
            } else {
                ContentUnavailableView("No Controller", systemImage: "gamecontroller",
                                       description: Text("Connect a controller to test it."))
            }
        }
        .navigationTitle("Controller Test")
        .onGamepad { _ in } // every button is for testing here, not for moving around
        .buttonGuide([([.b], "Hold to Leave")], reportsLayout: false)
        .task { await follow() }
        .onChange(of: effects.left) { apply() }
        .onChange(of: effects.right) { apply() }
        .onDisappear {
            (GCController.current?.extendedGamepad as? GCDualSenseGamepad).map(Self.turnOff)
            motors.values.forEach { $0.stop() }
        }
    }

    /// Reads the controller about 60 times a second, and leaves once B has been held for a second.
    private func follow() async {
        var bHeldSince: ContinuousClock.Instant?
        while !Task.isCancelled {
            let controller = GCController.current ?? GCController.controllers().first
            sample = controller.flatMap(Sample.init)
            if sample?.buttons.first(where: { $0.label == "B" })?.isPressed == true {
                let since = bHeldSince ?? .now
                bHeldSince = since
                if ContinuousClock.now - since >= .seconds(1) { return dismiss() }
            } else {
                bHeldSince = nil
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private func rumble(_ locality: GCHapticsLocality) {
        guard let controller = GCController.current ?? GCController.controllers().first,
              let motor = motors[locality] ?? HapticMotor(controller: controller, locality: locality) else { return }
        motors[locality] = motor
        motor.set(.max)
        rumbling = locality
        Task {
            try? await Task.sleep(for: .seconds(1))
            motor.set(0)
            if rumbling == locality { rumbling = nil }
        }
    }

    private func apply() {
        guard let pad = GCController.current?.extendedGamepad as? GCDualSenseGamepad else { return }
        effects.left.effect.apply(to: pad.leftTrigger)
        effects.right.effect.apply(to: pad.rightTrigger)
    }

    private static func turnOff(_ pad: GCDualSenseGamepad) {
        pad.leftTrigger.setModeOff()
        pad.rightTrigger.setModeOff()
    }
}

/// A trigger effect to try, built as the host would send it (an effect type and 10 bytes), so it goes through
/// `AdaptiveTriggerEffect`'s conversion like a game's.
nonisolated enum TriggerPreset: String, CaseIterable {
    case off = "Off", resistance = "Resistance", weapon = "Weapon", vibration = "Vibration"

    var effect: AdaptiveTriggerEffect {
        let (type, start): (UInt8, [UInt8]) = switch self {
        case .off: (0x05, [])
        case .resistance: (0x01, [0x40, 0xC0]) // from a quarter of the way down, fairly strong
        case .weapon: (0x02, [0x60, 0xA0, 0xFF]) // a click between about 40% and 60% of the way down
        case .vibration: (0x06, [0x30, 0xFF, 0x20]) // a low buzz from an eighth of the way down
        }
        return AdaptiveTriggerEffect(type: type, bytes: start + [UInt8](repeating: 0, count: 10 - start.count))
    }
}

/// One reading of a controller.
private struct Sample {
    struct Button { let symbol: String, label: String, isPressed: Bool }
    let name: String
    let isDualSense: Bool
    let buttons: [Button]
    let leftStick: CGPoint, rightStick: CGPoint
    let leftTrigger: Float, rightTrigger: Float
    /// Where it can rumble: both grips (big motor left, small right, as games use them) and any trigger motors, else
    /// its one motor.
    let motors: [(locality: GCHapticsLocality, label: String)]

    init?(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return nil }
        name = controller.vendorName ?? "Controller"
        isDualSense = pad is GCDualSenseGamepad
        let inputs: [(GCControllerButtonInput?, String, String)] = [
            (pad.buttonA, "A", "a.circle"), (pad.buttonB, "B", "b.circle"),
            (pad.buttonX, "X", "x.circle"), (pad.buttonY, "Y", "y.circle"),
            (pad.dpad.up, "Up", "dpad.up.filled"), (pad.dpad.down, "Down", "dpad.down.filled"),
            (pad.dpad.left, "Left", "dpad.left.filled"), (pad.dpad.right, "Right", "dpad.right.filled"),
            (pad.leftShoulder, "Left Bumper", "lb.rectangle.roundedbottom"),
            (pad.rightShoulder, "Right Bumper", "rb.rectangle.roundedbottom"),
            (pad.leftTrigger, "Left Trigger", "lt.rectangle.roundedtop"),
            (pad.rightTrigger, "Right Trigger", "rt.rectangle.roundedtop"),
            (pad.leftThumbstickButton, "Left Stick Click", "l.joystick.press.down"),
            (pad.rightThumbstickButton, "Right Stick Click", "r.joystick.press.down"),
            (pad.buttonOptions, "View", "rectangle.on.rectangle.circle"),
            (pad.buttonMenu, "Menu", "line.3.horizontal.circle"),
            (pad.buttonHome, "Home", "house.circle"),
            ((pad as? GCDualSenseGamepad)?.touchpadButton, "Touchpad", "touchpad.button"),
        ]
        // The controller's own symbols (✕ ○ on a DualSense), else Xbox's; buttons it doesn't have are left out.
        buttons = inputs.compactMap { input, label, fallback in
            input.map { Button(symbol: $0.sfSymbolsName ?? fallback, label: label, isPressed: $0.isPressed) }
        }
        leftStick = CGPoint(x: CGFloat(pad.leftThumbstick.xAxis.value), y: CGFloat(pad.leftThumbstick.yAxis.value))
        rightStick = CGPoint(x: CGFloat(pad.rightThumbstick.xAxis.value), y: CGFloat(pad.rightThumbstick.yAxis.value))
        leftTrigger = pad.leftTrigger.value
        rightTrigger = pad.rightTrigger.value
        let supported = controller.haptics?.supportedLocalities ?? []
        let spots: [(GCHapticsLocality, String)] = [(.leftHandle, "Left Grip (Strong)"), (.rightHandle, "Right Grip (Light)"),
                                                     (.leftTrigger, "Left Trigger"), (.rightTrigger, "Right Trigger")]
        let found = spots.filter { supported.contains($0.0) }.map { (locality: $0.0, label: $0.1) }
        motors = found.isEmpty && supported.contains(.default) ? [(.default, "Rumble")] : found
    }
}

/// A stick's position: a dot in a circle, up being up.
private struct StickView: View {
    let position: CGPoint
    let label: String
    private let size: CGFloat = 72

    var body: some View {
        Circle().fill(.white.opacity(0.08))
            .overlay {
                Circle().fill(.white).frame(width: 18, height: 18)
                    .offset(x: position.x * (size - 18) / 2, y: -position.y * (size - 18) / 2)
            }
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(String(format: "%.2f, %.2f", position.x, position.y))
    }
}

/// How far a trigger is pressed, filling from the bottom.
private struct TriggerBar: View {
    let value: Float
    let label: String

    var body: some View {
        Capsule().fill(.white.opacity(0.08))
            .overlay(alignment: .bottom) {
                Capsule().fill(.white).frame(height: 72 * CGFloat(value))
            }
            .clipShape(.capsule)
            .frame(width: 18, height: 72)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue("\(Int(value * 100))%")
    }
}
