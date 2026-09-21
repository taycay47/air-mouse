import CoreHaptics
import UIKit
import AirMouseGestures

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
    ///
    /// Extends the engine's vocabulary rather than duplicating it: the engine
    /// decides *that* something deserves feedback, this decides how it feels.
    private struct Feedback {
        let intensity: Float
        let sharpness: Float
        let isDouble: Bool
    }

    private func feedback(for cue: HapticCue) -> Feedback {
        switch cue {
        case .tap:           return Feedback(intensity: 0.55, sharpness: 0.80, isDouble: false)
        case .rightClick:    return Feedback(intensity: 0.80, sharpness: 0.55, isDouble: true)
        case .dragPickUp:    return Feedback(intensity: 1.00, sharpness: 0.35, isDouble: false)
        case .dragDrop:      return Feedback(intensity: 0.70, sharpness: 0.50, isDouble: false)
        case .doubleTap:     return Feedback(intensity: 0.65, sharpness: 0.75, isDouble: true)
        case .scrollDetent:  return Feedback(intensity: 0.25, sharpness: 0.95, isDouble: false)
        case .desktopSwitch: return Feedback(intensity: 0.85, sharpness: 0.40, isDouble: true)
        case .edgeEnter:     return Feedback(intensity: 0.30, sharpness: 0.70, isDouble: false)
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

    func play(_ cue: HapticCue) {
        guard supported, let engine else { return }
        let feedback = feedback(for: cue)

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
