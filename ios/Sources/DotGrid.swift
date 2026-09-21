import SwiftUI
import QuartzCore

/// The dot grid's physics, ported from the web client's render loop.
///
/// This is a simulation with state, not a function of the current time. Each
/// dot keeps its own excitement and eases toward its target — quickly up,
/// slowly down — and that asymmetry is the whole feel: a wave passes and leaves
/// a fading trail behind it rather than switching dots on and off. Computed
/// statelessly it reads as a moving ring and nothing more, which is exactly
/// what the first attempt at this looked like.
///
/// Held here rather than in SwiftUI state because it changes every frame.
/// Publishing it would invalidate the view tree sixty times a second to redraw
/// a canvas that is already redrawing itself.
final class SurfaceEffects {

    // MARK: Constants
    //
    // Reproduced exactly. The grid's character lives in the relationships
    // between these — ring width against speed, decay against spawn rate — so
    // adjusting any one alone makes it feel wrong.

    static let spacing: Double = 22
    /// Radius of the glow that follows a finger while it is down.
    private let proximityRadius: Double = 80
    private let rippleSpeed: Double = 320       // points per second
    private let rippleWidth: Double = 55        // trailing fade
    private let rippleMaxRadius: Double = 150
    /// The leading edge is far sharper than the trail: a ripple arrives as an
    /// edge and leaves as a fade, which is what makes it read as travelling
    /// rather than as a circle being scaled up.
    private let rippleLeadWidth: Double = 12
    /// Snappy up, slow down — roughly half a second of afterglow.
    private let riseRate: Double = 0.35
    private let decayRate: Double = 0.10
    /// While disconnected the surface pulses from its own centre, so the lost
    /// connection is signalled by the thing the user is already looking at.
    private let offlinePulseInterval: Double = 1.4
    private let flashDuration: Double = 1.1
    /// Drag ripples are throttled by distance *and* time, or a slow drag spawns
    /// one per frame and the grid saturates into a single solid glow.
    private let minRippleDistance: Double = 22
    private let minRippleInterval: Double = 0.05

    // MARK: Appearance
    //
    // Raised from the web client's values. The browser drew this on a screen
    // the eye had already adjusted to; on an OLED phone at ambient brightness
    // the resting grid at 0.07 was effectively invisible.

    /// Alpha of a dot at rest.
    static let restingAlpha: Double = 0.13
    /// Slightly stronger while disconnected, so the red state is legible at a
    /// glance rather than only once a pulse crosses it.
    static let restingAlphaOffline: Double = 0.17
    /// Diameter of a resting dot.
    static let restingDiameter: Double = 2.2
    /// How much a fully excited dot grows beyond its resting size.
    static let peakSizeGain: Double = 6.5
    /// How far the resting grid fades toward the edges of the screen.
    static let vignetteMargin: Double = 110
    /// How dim the very corner gets. Not zero — the grid should recede at the
    /// edges, not stop, or the surface acquires a visible border.
    static let vignetteFloor: Double = 0.25

    // MARK: State

    private struct Dot {
        let x: Double
        let y: Double
        var excited: Double = 0
    }

    private struct Ripple {
        let x: Double
        let y: Double
        var radius: Double
    }

    private var dots: [Dot] = []
    private var ripples: [Ripple] = []
    private var width: Double = 0
    private var height: Double = 0

    private var touchX: Double = -1000
    private var touchY: Double = -1000
    private var touchActive = false

    private var lastRippleX: Double = -9999
    private var lastRippleY: Double = -9999
    private var lastRippleTime: Double = 0
    private var lastOfflinePulse: Double = 0
    private var flash: (colour: SIMD3<Double>, start: Double)?
    private var lastStep: Double = CACurrentMediaTime()

    // MARK: Input

    /// A finger landed. Always ripples, however recently the last one did — a
    /// tap must always be acknowledged.
    func touchDown(x: Double, y: Double, at time: Double) {
        touchX = x
        touchY = y
        touchActive = true
        spawnRipple(x: x, y: y)
        lastRippleX = x
        lastRippleY = y
        lastRippleTime = time
    }

    /// A finger moved. Ripples only once it has travelled far enough and waited
    /// long enough, so a drag leaves a trail of distinct rings rather than a
    /// smear.
    func touchMoved(x: Double, y: Double, at time: Double) {
        touchX = x
        touchY = y
        touchActive = true
        guard hypot(x - lastRippleX, y - lastRippleY) >= minRippleDistance,
              time - lastRippleTime >= minRippleInterval
        else { return }
        spawnRipple(x: x, y: y)
        lastRippleX = x
        lastRippleY = y
        lastRippleTime = time
    }

    func touchUp() {
        touchActive = false
        // Parked off-screen so the proximity term contributes nothing even if
        // something reads it before the next frame.
        touchX = -1000
        touchY = -1000
    }

    /// A whole-grid colour flash for feedback that is not located anywhere —
    /// a shortcut firing, a pairing succeeding. Also throws a ripple from the
    /// centre, so the flash has a shape rather than being a flat tint.
    func pulse(_ colour: SIMD3<Double>, at time: Double) {
        flash = (colour, time)
        spawnRipple(x: width / 2, y: height / 2)
    }

    private func spawnRipple(x: Double, y: Double) {
        ripples.append(Ripple(x: x, y: y, radius: 0))
        if ripples.count > 32 { ripples.removeFirst(ripples.count - 32) }
    }

    // MARK: Simulation

    func resize(width: Double, height: Double) {
        guard width != self.width || height != self.height else { return }
        self.width = width
        self.height = height
        var built: [Dot] = []
        built.reserveCapacity(Int((width / Self.spacing + 2) * (height / Self.spacing + 2)))
        var y = 0.0
        while y <= height + Self.spacing {
            var x = 0.0
            while x <= width + Self.spacing {
                built.append(Dot(x: x, y: y))
                x += Self.spacing
            }
            y += Self.spacing
        }
        dots = built
    }

    /// Advances one frame. `isOffline` is passed in rather than stored, so the
    /// simulation holds no opinion about connection state beyond how it looks.
    func step(now: Double, isOffline: Bool) {
        // Clamped, so a stall does not teleport every ripple past the screen.
        let dt = min(max(now - lastStep, 0), 0.1)
        lastStep = now

        if isOffline, now - lastOfflinePulse > offlinePulseInterval {
            lastOfflinePulse = now
            spawnRipple(x: width / 2, y: height / 2)
        }

        for index in ripples.indices {
            ripples[index].radius += rippleSpeed * dt
        }
        ripples.removeAll { $0.radius >= rippleMaxRadius + rippleWidth }
        if let flash, now - flash.start > flashDuration { self.flash = nil }

        for index in dots.indices {
            let target = targetExcitement(for: dots[index])
            // The asymmetry is the point: rising fast and falling slowly is
            // what leaves a trail behind a passing wave.
            let rate = target > dots[index].excited ? riseRate : decayRate
            dots[index].excited += (target - dots[index].excited) * rate
        }
    }

    private func targetExcitement(for dot: Dot) -> Double {
        var excitement = 0.0

        // Continuous glow under the finger, so holding still still feels alive.
        if touchActive {
            let distance = hypot(dot.x - touchX, dot.y - touchY)
            if distance < proximityRadius {
                excitement = max(excitement, pow(1 - distance / proximityRadius, 1.8))
            }
        }

        for ripple in ripples {
            let distance = hypot(dot.x - ripple.x, dot.y - ripple.y)
            let delta = ripple.radius - distance
            guard delta > -rippleLeadWidth, delta < rippleWidth else { continue }

            // Ahead of the front it ramps in over 12pt; behind it, it fades out
            // over 55pt.
            let lead = delta < 0 ? max(0, 1 + delta / rippleLeadWidth) : 1
            let trail = delta >= 0 ? (1 - delta / rippleWidth) : 1
            // Clamped before the power: a negative base raised to 1.4 is NaN,
            // and one NaN dot poisons the frame.
            let amplitude = pow(max(0, 1 - ripple.radius / rippleMaxRadius), 1.4)
            excitement = max(excitement, lead * trail * amplitude)
        }
        return excitement
    }

    // MARK: Drawing

    var flashMix: Double {
        guard let flash else { return 0 }
        return max(0, 1 - (CACurrentMediaTime() - flash.start) / flashDuration)
    }

    var flashColour: SIMD3<Double>? { flash?.colour }

    func forEachDot(_ body: (Double, Double, Double) -> Void) {
        for dot in dots { body(dot.x, dot.y, dot.excited) }
    }
}

/// The animated dot field behind everything.
///
/// This is the app's only connection indicator: it tints red when the link
/// drops and pulses from its own centre while it stays down, which is why there
/// is no status light and no toast anywhere in this interface.
struct DotGrid: View {
    let effects: SurfaceEffects
    let isOffline: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                _ = timeline.date
                // CACurrentMediaTime throughout, the same clock the touch side
                // stamps with. Mixing it with a calendar date once made every
                // ripple arrive eight hundred million seconds old.
                let now = CACurrentMediaTime()
                effects.resize(width: size.width, height: size.height)
                effects.step(now: now, isOffline: isOffline)
                draw(context: context, size: size)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func draw(context: GraphicsContext, size: CGSize) {
        let mix = effects.flashMix
        let flashColour = effects.flashColour

        effects.forEachDot { x, y, excitement in
            // Applied to resting dots only. An excited dot keeps its full
            // brightness wherever it is, so a ripple still reaches the edges
            // intact — dimming those would make waves die before they arrive.
            let vignette = restingVignette(x: x, y: y, size: size)
            // Resting dots are the overwhelming majority and get a cheap path
            // with no size maths and no randomness.
            if excitement < 0.008 {
                let colour: Color
                if mix > 0, let flashColour {
                    colour = Color(red: flashColour.x, green: flashColour.y, blue: flashColour.z)
                        .opacity((SurfaceEffects.restingAlpha + 0.18 * mix) * vignette)
                } else if isOffline {
                    colour = Color(red: 1, green: 88 / 255, blue: 78 / 255)
                        .opacity(SurfaceEffects.restingAlphaOffline * vignette)
                } else {
                    colour = Color.white.opacity(SurfaceEffects.restingAlpha * vignette)
                }
                let r = SurfaceEffects.restingDiameter / 2
                context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r,
                                                    width: r * 2, height: r * 2)),
                             with: .color(colour))
                return
            }

            let diameter = SurfaceEffects.restingDiameter
                + pow(excitement, 1.8) * SurfaceEffects.peakSizeGain
            // A little noise at the peak keeps an excited dot from reading as a
            // solid disc.
            let flicker = Double.random(in: -0.11...0.11) * excitement
            // Ramps from the resting alpha to full, so the two paths meet
            // continuously — starting from a lower base would make a barely
            // excited dot dimmer than a resting one.
            let alpha = max(0, SurfaceEffects.restingAlpha
                + excitement * (1 - SurfaceEffects.restingAlpha) + flicker)

            var red = 1.0
            var green: Double
            var blue: Double
            if isOffline {
                let channel = (40 + 150 * (1 - excitement)) / 255
                green = channel
                blue = channel
            } else {
                let channel = (215 + 40 * excitement) / 255
                green = channel
                blue = channel
            }
            if mix > 0, let flashColour {
                red += (flashColour.x - red) * mix
                green += (flashColour.y - green) * mix
                blue += (flashColour.z - blue) * mix
            }

            let rect = CGRect(x: x - diameter / 2, y: y - diameter / 2,
                              width: diameter, height: diameter)
            context.fill(Path(ellipseIn: rect),
                         with: .color(Color(red: red, green: green, blue: blue).opacity(alpha)))
        }
    }
}

extension DotGrid {
    /// Fades the resting grid toward the screen's edges.
    ///
    /// The two axes are multiplied rather than taken at their minimum, so the
    /// corners — where both are falling — go darkest. Taking the minimum gives
    /// a rectangular frame instead of a vignette.
    func restingVignette(x: Double, y: Double, size: CGSize) -> Double {
        let margin = SurfaceEffects.vignetteMargin
        let horizontal = min(1, min(x, size.width - x) / margin)
        let vertical = min(1, min(y, size.height - y) / margin)
        let falloff = max(0, horizontal) * max(0, vertical)
        // Eased, so the transition into the dim region is not a visible ring.
        let eased = pow(falloff, 0.65)
        return SurfaceEffects.vignetteFloor
            + (1 - SurfaceEffects.vignetteFloor) * eased
    }
}

/// The blue field rising from the bottom of the screen.
///
/// Ported from the web client's `#ambient-glow`. It is the only colour in an
/// otherwise monochrome interface, and without it the surface reads as an empty
/// black rectangle — the dot grid alone is too sparse to give the screen a
/// bottom.
///
/// Suppressed while disconnected so the red state reads unambiguously rather
/// than fighting a blue wash for the same screen.
struct AmbientGlow: View {
    let isOffline: Bool

    private let accent = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)

    var body: some View {
        GeometryReader { proxy in
            // Wider than tall and centred just below the bottom edge, so what
            // shows is the top of a much larger ellipse rather than a circle
            // sitting in the corner.
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

extension SIMD3<Double> {
    /// System green, the web client's success pulse.
    static let success = SIMD3<Double>(52 / 255, 199 / 255, 89 / 255)
}
