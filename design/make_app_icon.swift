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
