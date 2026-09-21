import SwiftUI

/// Liquid Glass where the OS has it, a material where it does not.
///
/// The app's deployment floor is iOS 16 so it still runs on older phones, and
/// Liquid Glass arrived in iOS 26. Rather than scatter availability checks
/// through every control, every surface goes through here — which also means
/// the fallback is defined once and cannot drift out of sympathy with the real
/// thing.
///
/// `interactive()` matters for the controls: it is what makes the glass respond
/// to touch the way the system's own does, and without it the buttons read as
/// stickers rather than as part of the platform.
extension View {

    @ViewBuilder
    func glassSurface(in shape: some Shape, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            if interactive {
                self.glassEffect(.regular.interactive(), in: shape)
            } else {
                self.glassEffect(.regular, in: shape)
            }
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 0.5))
        }
    }
}

/// Groups adjacent glass surfaces so they merge and refract as one piece rather
/// than as separate panes stacked on a background. Without it a row of buttons
/// looks like several sheets of glass; with it, one.
struct GlassGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer { content }
        } else {
            content
        }
    }
}
