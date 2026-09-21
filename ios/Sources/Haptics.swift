import CoreHaptics
import UIKit

/// Gesture feedback through CoreHaptics.
///
/// The web client could only call `navigator.vibrate`, which iOS Safari ignores
/// outright — hence the hidden-checkbox trick it resorts to, which produces one
/// undifferentiated buzz. CoreHaptics gives each gesture its own character, so
/// a tap, a drag picking something up, and a scroll detent feel distinct instead
/// of merely *happening*.
@MainActor
final class Haptics {

    /// Sharpness separates a click from a thud; intensity separates a detent
    /// from a commitment. Values are tuned to be felt through a grip rather
    /// than only when the phone is resting on a table.
    enum Feedback {
        case tap
        case rightClick
        case dragPickUp
        case dragDrop
        case scrollDetent
        case desktopSwitch
        case failure

        var intensity: Float {
            switch self {
            case .tap: return 0.55
            case .rightClick: return 0.8
            case .dragPickUp: return 1.0
            case .dragDrop: return 0.7
            case .scrollDetent: return 0.25
            case .desktopSwitch: return 0.85
            case .failure: return 0.9
            }
        }

        var sharpness: Float {
            switch self {
            case .tap: return 0.8
            case .rightClick: return 0.55
            case .dragPickUp: return 0.35
            case .dragDrop: return 0.5
            case .scrollDetent: return 0.95
            case .desktopSwitch: return 0.4
            case .failure: return 0.2
            }
        }

        /// A second tick, for the gestures that mean "two things happened".
        var isDouble: Bool {
            switch self {
            case .rightClick, .desktopSwitch, .failure: return true
            default: return false
            }
        }
    }

    private var engine: CHHapticEngine?
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    init() {
        prepare()
    }

    private func prepare() {
        // Not every device has a Taptic Engine, and the simulator never does.
        // Everything below is then a no-op rather than an error — feedback is a
        // refinement, and its absence must not break anything.
        guard supported else { return }
        do {
            let engine = try CHHapticEngine()
            // The engine is stopped when the app backgrounds or the audio
            // session is interrupted, and does not restart itself. Without
            // these, haptics work until the first phone call and then never
            // again for the rest of the session.
            engine.resetHandler = { [weak self] in try? self?.engine?.start() }
            engine.stoppedHandler = { _ in }
            engine.isAutoShutdownEnabled = true
            try engine.start()
            self.engine = engine
        } catch {
            NSLog("Air Mouse: haptic engine unavailable — \(error.localizedDescription)")
        }
    }

    func play(_ feedback: Feedback) {
        guard supported, let engine else { return }

        var events = [CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                .init(parameterID: .hapticIntensity, value: feedback.intensity),
                .init(parameterID: .hapticSharpness, value: feedback.sharpness),
            ],
            relativeTime: 0)]

        if feedback.isDouble {
            events.append(CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    .init(parameterID: .hapticIntensity, value: feedback.intensity * 0.75),
                    .init(parameterID: .hapticSharpness, value: feedback.sharpness),
                ],
                // 80ms reads as two taps; much less and it blurs into one.
                relativeTime: 0.08))
        }

        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            // A failed tick is never worth interrupting the gesture over.
            NSLog("Air Mouse: haptic failed — \(error.localizedDescription)")
        }
    }
}
