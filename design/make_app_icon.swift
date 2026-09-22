#!/usr/bin/env swift
// Renders the Air Mouse mark into app icons.
//
//   swift design/make_app_icon.swift
//
// The logo's single path from design/logo.svg is transcribed below rather than
// parsed. It is one path with two curves, it will not change often, and
// transcribing it means the icons regenerate with nothing installed beyond
// Xcode — no SVG toolchain, no checked-in binaries nobody can reproduce.
//
// Apple's rules this obeys:
//   - 1024×1024, and derived sizes for the places that still need them.
//   - Fully opaque. The App Store rejects an icon with an alpha channel, and a
//     transparent one renders black-on-black on a dark home screen anyway.
//   - Square, with no rounded corners drawn in. iOS applies the squircle mask
//     itself; baking one in gets it masked twice and leaves dark fringes.
//   - Artwork inset from the edges, so the mask cannot clip the mark.

import AppKit
import ImageIO
import UniformTypeIdentifiers

// The SVG's viewBox. Its bounds already account for the 16pt stroke, so the
// mark touches all four edges of this box.
let artboard = CGSize(width: 116, height: 123)
let strokeWidth: CGFloat = 16

/// How much of the icon's width the mark occupies. 62% keeps it clear of the
/// squircle mask on every platform while still reading as a bold mark rather
/// than a logo floating in a field of black.
let coverage: CGFloat = 0.62

func logoPath() -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 8.00191, y: 114.894))
    path.addLine(to: CGPoint(x: 46.8264, y: 15.6284))
    path.addCurve(to: CGPoint(x: 69.1777, y: 15.6284),
                  control1: CGPoint(x: 50.8049, y: 5.45637),
                  control2: CGPoint(x: 65.1992, y: 5.45639))
    path.addLine(to: CGPoint(x: 108.002, y: 114.894))
    path.addLine(to: CGPoint(x: 85.9209, y: 90.6155))
    path.addCurve(to: CGPoint(x: 58.0021, y: 78.2686),
                  control1: CGPoint(x: 78.7688, y: 82.7515),
                  control2: CGPoint(x: 68.6319, y: 78.2686))
    return path
}

func render(size: Int, opacity: CGFloat) -> CGImage? {
    let dimension = CGFloat(size)
    guard let context = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        // No alpha: opaque is required, and it is also what the mark was drawn
        // against.
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }

    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: dimension, height: dimension))

    // Fit the artboard into the coverage box, preserving aspect. The mark is
    // taller than it is wide, so height is what binds.
    let target = dimension * coverage
    let scale = min(target / artboard.width, target / artboard.height)
    let drawnWidth = artboard.width * scale
    let drawnHeight = artboard.height * scale

    context.saveGState()
    context.translateBy(x: (dimension - drawnWidth) / 2, y: (dimension - drawnHeight) / 2)
    context.scaleBy(x: scale, y: scale)
    // SVG's origin is top-left and Core Graphics' is bottom-left, so the
    // artboard is flipped rather than the coordinates being rewritten by hand.
    context.translateBy(x: 0, y: artboard.height)
    context.scaleBy(x: 1, y: -1)

    context.addPath(logoPath())
    context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: opacity)
    context.setLineWidth(strokeWidth)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()
    context.restoreGState()

    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "icon", code: 1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "icon", code: 2)
    }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

// iOS app icon. One 1024 png; Xcode derives every other size it needs.
let appIcon = root.appendingPathComponent("ios/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: appIcon, withIntermediateDirectories: true)

// The mark is drawn at 70% white in the source. That is right on a screen the
// eye has adjusted to, but an icon is seen cold against a bright home screen,
// where 70% grey reads as switched-off. Full white for the icon only.
guard let icon = render(size: 1024, opacity: 1.0) else { exit(1) }
try write(icon, to: appIcon.appendingPathComponent("icon-1024.png"))
print("wrote ios/Assets.xcassets/AppIcon.appiconset/icon-1024.png")

// The web client's home-screen icons, from the same mark, so the PWA and the
// native app are recognisably one product.
let webIcons = root.appendingPathComponent("web/icons")
try FileManager.default.createDirectory(at: webIcons, withIntermediateDirectories: true)
for size in [180, 192, 512, 1024] {
    guard let image = render(size: size, opacity: 1.0) else { exit(1) }
    try write(image, to: webIcons.appendingPathComponent("icon-\(size).png"))
    print("wrote web/icons/icon-\(size).png")
}

// The disk image's backdrop, from the same path as everything above — which is
// the reason it lives in this script rather than beside make_dmg.sh. A second
// transcription of the mark is a second thing to forget to update.
//
// It echoes the app deliberately: black, with the same blue glow rising from
// the bottom that the phone client has behind its dot grid. Opening the DMG
// should look like the beginning of the app, not like a generic installer.

/// Finder's window, in points. The icons sit at (170, 200) and (490, 200)
/// measured from the top left, which make_dmg.sh sets to match.
let dmgSize = CGSize(width: 660, height: 420)
let iconRowFromTop: CGFloat = 200

func renderBackground(scale: CGFloat) -> CGImage? {
    let width = Int(dmgSize.width * scale)
    let height = Int(dmgSize.height * scale)
    guard let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }

    context.scaleBy(x: scale, y: scale)
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(origin: .zero, size: dmgSize))

    // The ambient glow, centred below the bottom edge so only its top shows —
    // the same construction as AmbientGlow in the iOS client.
    let accent = CGColor(red: 10 / 255, green: 132 / 255, blue: 255 / 255, alpha: 1)
    if let space = CGColorSpace(name: CGColorSpace.sRGB),
       let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            accent.copy(alpha: 0.30)!, accent.copy(alpha: 0.16)!,
            accent.copy(alpha: 0.05)!, accent.copy(alpha: 0.00)!,
        ] as CFArray,
        locations: [0.0, 0.24, 0.50, 0.78]) {
        context.saveGState()
        // Wider than tall, so what shows is the top of a large ellipse rather
        // than a circle sitting in the corner.
        context.translateBy(x: dmgSize.width / 2, y: 0)
        context.scaleBy(x: 1.6, y: 1.0)
        context.drawRadialGradient(
            gradient,
            startCenter: .zero, startRadius: 0,
            endCenter: .zero, endRadius: dmgSize.height * 0.85,
            options: [])
        context.restoreGState()
    }

    // The mark, small, above the icons.
    let markHeight: CGFloat = 40
    let markScale = markHeight / artboard.height
    let markWidth = artboard.width * markScale
    context.saveGState()
    context.translateBy(x: (dmgSize.width - markWidth) / 2,
                        y: dmgSize.height - 54 - markHeight)
    context.scaleBy(x: markScale, y: markScale)
    context.translateBy(x: 0, y: artboard.height)
    context.scaleBy(x: 1, y: -1)
    context.addPath(logoPath())
    context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.82)
    context.setLineWidth(strokeWidth)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()
    context.restoreGState()

    // An arrow between the two icons, saying what to do without a word of text.
    // Flipped into Core Graphics' bottom-left origin from Finder's top-left one.
    let arrowY = dmgSize.height - iconRowFromTop
    context.saveGState()
    context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.22)
    context.setLineWidth(2)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: 268, y: arrowY))
    context.addLine(to: CGPoint(x: 392, y: arrowY))
    context.move(to: CGPoint(x: 376, y: arrowY + 12))
    context.addLine(to: CGPoint(x: 392, y: arrowY))
    context.addLine(to: CGPoint(x: 376, y: arrowY - 12))
    context.strokePath()
    context.restoreGState()

    return context.makeImage()
}

let dmgDir = root.appendingPathComponent("menubar/dmg")
try FileManager.default.createDirectory(at: dmgDir, withIntermediateDirectories: true)
for (scale, name) in [(CGFloat(1), "background.png"), (CGFloat(2), "background@2x.png")] {
    guard let image = renderBackground(scale: scale) else { exit(1) }
    try write(image, to: dmgDir.appendingPathComponent(name))
    print("wrote menubar/dmg/\(name)")
}

// A classic iconset for the Mac app.
//
// The Mac bundle would rather have the Icon Composer .icon compiled by actool,
// which yields the layered light/dark/tinted appearances macOS 26 composites
// itself. But that needs Xcode 26, and a CI runner pinned to an older Xcode has
// an actool that cannot read the format at all — which is exactly how the first
// v0.2.0 release failed.
//
// So the same mark is also emitted as a plain iconset here. build_app.sh turns
// it into an .icns with iconutil, which has shipped in the Command Line Tools
// forever, and uses it whenever actool could not. The result is an app that
// always has an icon, and a better one where the toolchain allows.
let iconset = root.appendingPathComponent("menubar/Resources/AirMouse.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
// The sizes iconutil expects, spelled the way it expects them.
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2),
                        (128, 1), (128, 2), (256, 1), (256, 2),
                        (512, 1), (512, 2)] {
    guard let image = render(size: points * scale, opacity: 1.0) else { exit(1) }
    let suffix = scale == 2 ? "@2x" : ""
    let name = "icon_\(points)x\(points)\(suffix).png"
    try write(image, to: iconset.appendingPathComponent(name))
}
print("wrote menubar/Resources/AirMouse.iconset (10 sizes)")

// The menu bar mark.
//
// A *template* image: drawn in black with everything else transparent, and
// flagged as such at load time, which is what lets macOS tint it — light on a
// dark menu bar, dark on a light one, and inverted while the menu is open. A
// coloured icon gets none of that and looks wrong in half the situations it
// appears in.
//
// Rendered here rather than drawn in the app so there is still exactly one
// transcription of the logo's path. The backdrop is deliberately absent: in the
// menu bar the mark is the whole icon.

/// 18pt tall inside the menu bar's 22pt, which is the conventional size — the
/// glyph reads as part of the row rather than looming over it.
let menuBarHeight: CGFloat = 18

func renderMenuBarMark(scale: CGFloat) -> CGImage? {
    let aspect = artboard.width / artboard.height
    let width = Int((menuBarHeight * aspect * scale).rounded())
    let height = Int((menuBarHeight * scale).rounded())

    guard let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        // With alpha, unlike the app icon: a template image is read through its
        // alpha channel, and an opaque one would be a black rectangle.
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // A half-point of inset so antialiasing at the extremes is not clipped.
    // The artboard's bounds already include the stroke, so the mark otherwise
    // touches all four edges.
    let inset = 0.5 * scale
    let drawnHeight = CGFloat(height) - inset * 2
    let markScale = drawnHeight / artboard.height

    context.translateBy(x: (CGFloat(width) - artboard.width * markScale) / 2, y: inset)
    context.scaleBy(x: markScale, y: markScale)
    context.translateBy(x: 0, y: artboard.height)
    context.scaleBy(x: 1, y: -1)

    context.addPath(logoPath())
    context.setStrokeColor(red: 0, green: 0, blue: 0, alpha: 1)
    context.setLineWidth(strokeWidth)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()

    return context.makeImage()
}

let barIcons = root.appendingPathComponent("menubar/Resources")
try FileManager.default.createDirectory(at: barIcons, withIntermediateDirectories: true)
for (scale, name) in [(CGFloat(1), "menubar-icon.png"), (CGFloat(2), "menubar-icon@2x.png")] {
    guard let image = renderMenuBarMark(scale: scale) else { exit(1) }
    try write(image, to: barIcons.appendingPathComponent(name))
    print("wrote menubar/Resources/\(name)")
}
