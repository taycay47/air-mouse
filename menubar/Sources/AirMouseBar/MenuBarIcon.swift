import AppKit

/// The logo mark, as the menu bar sees it.
///
/// Loaded as a **template** image, which is the whole reason this is a pair of
/// black-on-transparent PNGs rather than a picture of the app icon. macOS tints
/// a template itself: light on a dark menu bar, dark on a light one, and
/// inverted while the menu is open. Anything with its own colours — including
/// the app icon, backdrop and all — gets none of that and looks wrong in half
/// the places it appears.
///
/// Both representations are loaded explicitly rather than relying on
/// `NSImage(named:)` to find the `@2x` file, because this bundle is assembled by
/// hand and has no asset catalog for that lookup to consult.
enum MenuBarIcon {

    static let image: NSImage = {
        let image = NSImage()
        for name in ["menubar-icon", "menubar-icon@2x"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
                  let rep = NSImageRep(contentsOf: url)
            else { continue }
            image.addRepresentation(rep)
        }

        // Points, not pixels. Without this the image reports the @2x file's
        // pixel dimensions as its size and draws at double scale — a mark
        // towering over every other icon in the row.
        image.size = NSSize(width: 17, height: 18)
        image.isTemplate = true

        // A menu bar with no icon at all is worse than the wrong one, so fall
        // back to the symbol this replaced if the resources are missing.
        if image.representations.isEmpty {
            return NSImage(systemSymbolName: "cursorarrow.rays",
                           accessibilityDescription: "Air Mouse") ?? image
        }
        return image
    }()
}
