import SwiftUI

// Liquid Glass where the system has it, the nearest material where it does not.
//
// Guarded twice: `#available` for the OS the app runs on (the floor is 13), and
// `#if compiler` for the SDK it is built with — the glass API does not exist in
// anything older than the macOS 26 SDK, and a build machine a version behind
// should produce a plainer app, not a failed build.

extension View {
    /// A resting surface: the PIN, a warning.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat = 16, tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(tint?.opacity(0.35)), in: .rect(cornerRadius: cornerRadius))
        } else {
            materialSurface(cornerRadius: cornerRadius, tint: tint)
        }
        #else
        materialSurface(cornerRadius: cornerRadius, tint: tint)
        #endif
    }

    private func materialSurface(cornerRadius: CGFloat, tint: Color?) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tint.map { AnyShapeStyle($0.opacity(0.14)) } ?? AnyShapeStyle(.quaternary))
        }
    }

    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            fallbackButtonStyle(prominent: prominent)
        }
        #else
        fallbackButtonStyle(prominent: prominent)
        #endif
    }

    @ViewBuilder
    private func fallbackButtonStyle(prominent: Bool) -> some View {
        if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}
