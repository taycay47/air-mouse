import SwiftUI
import UIKit
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
    /// The trailing fade on a status pulse. Wider than a touch ripple's, so it
    /// reads as a swell rather than a thin ring travelling — but only a little.
    /// At 150 the band was so deep that the whole lower half lit at once, which
    /// destroyed the very thing it was meant to show: where it came from.
    private let statusTrailWidth: Double = 80
    /// How far up the screen a status pulse climbs, as a fraction of its height.
    /// It dies around the middle. Reaching the top meant the wave was always
    /// somewhere, and a signal that is always present signals nothing.
    private let statusReach: Double = 0.5
    /// The leading edge is far sharper than the trail: a ripple arrives as an
    /// edge and leaves as a fade, which is what makes it read as travelling
    /// rather than as a circle being scaled up.
    private let rippleLeadWidth: Double = 12
    /// Snappy up, slow down — roughly half a second of afterglow.
    private let riseRate: Double = 0.35
    private let decayRate: Double = 0.10
    /// While disconnected the surface pulses from the bottom edge, so the lost
    /// connection is signalled by the thing the user is already looking at.
    /// Longer than a touch ripple's lifetime, so pulses overlap slightly and
    /// the surface breathes rather than blinking.
    private let offlinePulseInterval: Double = 1.7
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
        /// Where this ripple stops, and how wide its trail is.
        ///
        /// Per ripple rather than global, which is what lets a status pulse
        /// cross the whole screen while a touch ripple stays local — *without*
        /// a second set of equations. Speed, easing, the sharp leading edge and
        /// the amplitude curve are all still shared; only the extent differs.
        /// These were constants that happened to have one value, and now they
        /// are parameters that happen to have two.
        let maxRadius: Double
        let trailWidth: Double
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
        spawnStatusPulse()
    }

    /// A pulse that belongs to the surface rather than to a finger.
    ///
    /// From the bottom edge, centred: the same place the ambient glow rises
    /// from and the end of the screen the hand is at, so status reads as coming
    /// *from* the interface rather than from an arbitrary point in the middle
    /// of it.
    private func spawnStatusPulse() {
        spawnRipple(x: width / 2, y: height,
                    // Short enough that the amplitude curve — which falls over
                    // the ripple's own reach — actually falls somewhere
                    // visible. Over a screen-height reach the same curve is so
                    // gradual that the pulse never appears to fade at all.
                    maxRadius: height * statusReach,
                    trailWidth: statusTrailWidth)
    }

    private func spawnRipple(x: Double, y: Double,
                             maxRadius: Double? = nil,
                             trailWidth: Double? = nil) {
        ripples.append(Ripple(x: x, y: y, radius: 0,
                              maxRadius: maxRadius ?? rippleMaxRadius,
                              trailWidth: trailWidth ?? rippleWidth))
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
            spawnStatusPulse()
        }

        for index in ripples.indices {
            ripples[index].radius += rippleSpeed * dt
        }
        ripples.removeAll { $0.radius >= $0.maxRadius + $0.trailWidth }
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
            guard delta > -rippleLeadWidth, delta < ripple.trailWidth else { continue }

            // Ahead of the front it ramps in over 12pt; behind it, it fades out
            // over the length of its own trail.
            let lead = delta < 0 ? max(0, 1 + delta / rippleLeadWidth) : 1
            let trail = delta >= 0 ? (1 - delta / ripple.trailWidth) : 1
            // Clamped before the power: a negative base raised to 1.4 is NaN,
            // and one NaN dot poisons the frame.
            let amplitude = pow(max(0, 1 - ripple.radius / ripple.maxRadius), 1.4)
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

/// How much of the screen the keyboard is covering, right now.
///
/// The system keyboard lives in its own window above the app, so nothing can
/// actually be drawn behind it. What can be done is to move the light *to its
/// edge*, which is what reads as a backlight.
@MainActor
final class KeyboardInset: ObservableObject {
    @Published private(set) var height: CGFloat = 0

    private var observers: [NSObjectProtocol] = []

    init() {
        let centre = NotificationCenter.default
        // willChangeFrame rather than willShow: it also fires for the height
        // changing under a predictive bar or an emoji switch, which willShow
        // does not, and a glow parked at the old height is worse than one that
        // never moved.
        observers.append(centre.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                    as? CGRect else { return }
                let screen = UIScreen.main.bounds.height
                MainActor.assumeIsolated { self?.height = max(0, screen - frame.origin.y) }
            })
        observers.append(centre.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.height = 0 }
            })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

/// The blue field rising from the bottom of the screen.
///
/// Ported from the web client's `#ambient-glow`. It is the only colour in an
/// otherwise monochrome interface, and without it the surface reads as an empty
/// black rectangle — the dot grid alone is too sparse to give the screen a
/// bottom.
///
/// It rises with the keyboard. Anchored to the screen's bottom edge it was
/// almost entirely hidden behind one, taking the only colour in the interface
/// with it; anchored to the keyboard's top edge, the same light spills out from
/// behind the glass and the keyboard looks lit rather than pasted on. It also
/// brightens while lifted, because a glass surface sitting on top of it eats
/// most of what it emits.
///
/// Suppressed while disconnected so the red state reads unambiguously rather
/// than fighting a blue wash for the same screen.
struct AmbientGlow: View {
    let isOffline: Bool
    /// Height of whatever is covering the bottom of the screen, in points.
    var bottomInset: CGFloat = 0

    private let accent = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)

    var body: some View {
        GeometryReader { proxy in
            let fieldHeight = proxy.size.height * 0.62
            let baseline = proxy.size.height - bottomInset
            // Wider than tall and centred just below its own baseline, so what
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
            .frame(width: proxy.size.width, height: fieldHeight)
            .position(x: proxy.size.width / 2, y: baseline - fieldHeight / 2)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .opacity(isOffline ? 0 : (bottomInset > 0 ? 0.68 : 0.42))
        .animation(.easeInOut(duration: 0.5), value: isOffline)
        // Matched to the keyboard's own curve closely enough that the light
        // travels with it instead of chasing it.
        .animation(.easeOut(duration: 0.3), value: bottomInset)
    }
}

extension SIMD3<Double> {
    /// System green, the web client's success pulse.
    static let success = SIMD3<Double>(52 / 255, 199 / 255, 89 / 255)
}
