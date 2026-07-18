import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Generates a QR code entirely with CoreImage — no network call, no third-party
/// service, unlike the api.qrserver.com dependency this replaces elsewhere.
func qrImage(for string: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"

    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))

    let rep = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
}
