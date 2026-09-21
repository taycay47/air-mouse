import SwiftUI
import QuartzCore

/// Shared, mutable state between the touch surface and the dot grid.
///
/// Deliberately not `ObservableObject`. Ripples are appended on every touch and
/// read on every frame; publishing that would invalidate the SwiftUI view tree
/// sixty times a second to redraw a canvas that is already redrawing itself.
/// `TimelineView` drives the redraw, and this is just the data it reads.
final class SurfaceEffects {
    struct Ripple {
        let x: Double
        let y: Double
        let start: Double
    }

    private(set) var ripples: [Ripple] = []
    /// A whole-grid colour flash, for feedback that is not located anywhere in
    /// particular — a shortcut firing, a successful pairing.
    private(set) var flash: (colour: SIMD3<Double>, start: Double)?

    func ripple(x: Double, y: Double, at time: Double) {
        ripples.append(Ripple(x: x, y: y, start: time))
        // Bounded: a long drag would otherwise append one per frame forever.
        if ripples.count > 24 { ripples.removeFirst(ripples.count - 24) }
    }

    func pulse(_ colour: SIMD3<Double>, at time: Double) {
        flash = (colour, time)
    }

    func prune(now: Double, lifetime: Double) {
        ripples.removeAll { now - $0.start > lifetime }
        if let flash, now - flash.start > 0.6 { self.flash = nil }
    }
}

/// The animated dot field behind everything.
///
/// This is the app's only status indicator: it tints red when the connection
/// drops and pulses green on success, which is why there is no status light or
/// toast anywhere in the interface. Ported from the web client's canvas, whose
/// constants are reproduced exactly — the grid's character comes from the
/// relationship between spacing, ripple speed and decay rate, and changing any
/// one of them in isolation makes it feel wrong.
struct DotGrid: View {
    let effects: SurfaceEffects
    let isOffline: Bool

    private let spacing: Double = 22
    private let rippleSpeed: Double = 320   // points per second
    private let rippleWidth: Double = 55    // width of the exciting ring
    private let rippleMaxRadius: Double = 150

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                // CACurrentMediaTime, not the timeline's date. Ripples are
                // stamped with the former (seconds since boot) and this read
                // them as the latter (seconds since 2001), so every ripple
                // looked eight hundred million seconds old and was discarded
                // before it could be drawn. The redraw still comes from the
                // timeline; only the clock is shared with the touch side.
                _ = timeline.date
                let now = CACurrentMediaTime()
                effects.prune(now: now, lifetime: rippleMaxRadius / rippleSpeed)
                draw(context: context, size: size, now: now)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func draw(context: GraphicsContext, size: CGSize, now: Double) {
        let flashMix = flashAmount(now: now)

        var y = 0.0
        while y <= size.height + spacing {
            var x = 0.0
            while x <= size.width + spacing {
                let excitement = excitementAt(x: x, y: y, now: now)
                draw(dot: CGPoint(x: x, y: y), excitement: excitement,
                     flashMix: flashMix, context: context)
                x += spacing
            }
            y += spacing
        }
    }

    /// How strongly a dot is lit by the ripples currently passing over it.
    ///
    /// A ripple is a ring, not a disc: `lead` fades the dot in as the ring
    /// arrives and `trail` fades it out behind, so the grid reads as a wave
    /// travelling outward rather than a circle growing.
    private func excitementAt(x: Double, y: Double, now: Double) -> Double {
        var excitement = 0.0
        for ripple in effects.ripples {
            let age = now - ripple.start
            guard age >= 0 else { continue }
            let radius = age * rippleSpeed
            guard radius <= rippleMaxRadius else { continue }

            let distance = hypot(x - ripple.x, y - ripple.y)
            let offset = abs(distance - radius)
            guard offset < rippleWidth else { continue }

            let lead = 1 - offset / rippleWidth
            let trail = 1 - radius / rippleMaxRadius
            excitement = max(excitement, lead * trail)
        }
        return min(1, excitement)
    }

    private func flashAmount(now: Double) -> Double {
        guard let flash = effects.flash else { return 0 }
        let age = now - flash.start
        guard age < 0.6 else { return 0 }
        // Quick in, slow out — a flash that fades linearly reads as a flicker.
        return age < 0.1 ? age / 0.1 : 1 - (age - 0.1) / 0.5
    }

    private func draw(dot point: CGPoint, excitement: Double,
                      flashMix: Double, context: GraphicsContext) {
        // Resting dots are the overwhelming majority, so they get a cheap path
        // with no per-dot randomness or size maths.
        if excitement < 0.008 {
            let alpha = 0.07
            let colour = restingColour(alpha: alpha, flashMix: flashMix)
            context.fill(Path(ellipseIn: CGRect(x: point.x - 1, y: point.y - 1,
                                                width: 2, height: 2)),
                         with: .color(colour))
            return
        }

        let sizeRatio = pow(excitement, 1.8)
        let diameter = 1 + sizeRatio * 5.5
        // A little noise at the peak keeps an excited dot from looking like a
        // solid disc; without it the wave front reads as plastic.
        let flicker = Double.random(in: -0.11...0.11) * excitement
        let alpha = max(0, 0.07 + excitement * 0.93 + flicker)

        var red = 1.0, green = 0.0, blue = 0.0
        if isOffline {
            let channel = (40 + 150 * (1 - excitement)) / 255
            green = channel
            blue = channel
        } else {
            let channel = (215 + 40 * excitement) / 255
            green = channel
            blue = channel
        }
        if flashMix > 0, let flash = effects.flash {
            red += (flash.colour.x - red) * flashMix
            green += (flash.colour.y - green) * flashMix
            blue += (flash.colour.z - blue) * flashMix
        }

        let rect = CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2,
                          width: diameter, height: diameter)
        context.fill(Path(ellipseIn: rect),
                     with: .color(Color(red: red, green: green, blue: blue).opacity(alpha)))
    }

    private func restingColour(alpha: Double, flashMix: Double) -> Color {
        if flashMix > 0, let flash = effects.flash {
            return Color(red: flash.colour.x, green: flash.colour.y, blue: flash.colour.z)
                .opacity((0.07 + 0.18 * flashMix))
        }
        return isOffline
            ? Color(red: 1, green: 88 / 255, blue: 78 / 255).opacity(0.10)
            : Color.white.opacity(alpha)
    }
}

extension SIMD3<Double> {
    /// System green, the web client's success pulse.
    static let success = SIMD3<Double>(52 / 255, 199 / 255, 89 / 255)
}

/// The blue field rising from the bottom of the screen.
///
/// Ported from the web client's `#ambient-glow`. It is the only colour in an
/// otherwise monochrome interface, and it is what stops the surface reading as
/// an empty black rectangle — the dot grid alone is too sparse to give the
/// screen a bottom.
///
/// Suppressed entirely while disconnected, so the red offline state reads
/// unambiguously rather than fighting a blue wash for the same screen.
struct AmbientGlow: View {
    let isOffline: Bool

    /// System blue, matching the web client's --accent.
    private let accent = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)

    var body: some View {
        GeometryReader { proxy in
            // The gradient is wider than it is tall (135% × 105% in CSS) and
            // centred just below the bottom edge, so what shows on screen is
            // the top of a much larger ellipse rather than a circle sitting in
            // the corner.
            EllipticalGradient(
                stops: [
                    .init(color: accent.opacity(0.42), location: 0.00),
                    .init(color: accent.opacity(0.24), location: 0.24),
                    .init(color: accent.opacity(0.08), location: 0.50),
                    .init(color: accent.opacity(0.00), location: 0.76),
                ],
                center: UnitPoint(x: 0.5, y: 0.96),
                startRadiusFraction: 0,
                endRadiusFraction: 0.85
            )
            .frame(width: proxy.size.width, height: proxy.size.height * 0.62)
            .position(x: proxy.size.width / 2,
                      y: proxy.size.height - (proxy.size.height * 0.62) / 2)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .opacity(isOffline ? 0 : 0.42)
        .animation(.easeInOut(duration: 0.5), value: isOffline)
    }
}
