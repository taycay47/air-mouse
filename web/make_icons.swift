#!/usr/bin/env swift
// Generates the PWA / home-screen icons into web/icons/.
//
//   swift web/make_icons.swift
//
// Kept in the repo so the icons are reproducible rather than being binary blobs
// nobody can regenerate. Uses the same SF Symbol as the menu bar item, so the
// phone icon and the Mac status item read as the same product.
//
// Draws into a CGContext rather than using NSImage.lockFocus: this runs as a
// command-line script with no window server connection, where lockFocus fails.
//
// iOS applies its own rounded-rect mask to apple-touch-icon, so these are drawn
// as full-bleed opaque squares with no pre-rounded corners — a pre-rounded icon
// gets clipped twice and ends up with dark fringes in the corners.

import AppKit
import ImageIO
import UniformTypeIdentifiers

let symbolName = "cursorarrow.rays"
let sizes = [180, 192, 512, 1024]

let outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("web/icons", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(size: Int) -> CGImage? {
    let dimension = CGFloat(size)
    guard let context = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Matches the web client's --bg, so the icon and the app surface agree.
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: dimension, height: dimension))

    // paletteColors tints the glyph white without needing a template-image
    // compositing pass.
    let config = NSImage.SymbolConfiguration(pointSize: dimension * 0.52, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Air Mouse")?
        .withSymbolConfiguration(config) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

    let glyph = NSRect(
        x: (dimension - symbol.size.width) / 2,
        y: (dimension - symbol.size.height) / 2,
        width: symbol.size.width,
        height: symbol.size.height
    )
    symbol.draw(in: glyph)

    return context.makeImage()
}

for size in sizes {
    let url = outDir.appendingPathComponent("icon-\(size).png")
    guard let image = render(size: size),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        FileHandle.standardError.write(Data("failed to render \(size)px\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("failed to write \(url.path)\n".utf8))
        exit(1)
    }
    print("wrote icon-\(size).png")
}
