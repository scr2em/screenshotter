import AppKit

enum Clipboard {
    /// Puts the image on the general pasteboard as PNG (preferred by most apps) and TIFF (for older ones).
    /// Encoding happens off the main thread; a large capture takes a moment to land on the clipboard.
    static func copy(_ image: CGImage, scale: CGFloat) {
        DispatchQueue.global(qos: .userInitiated).async {
            let png = ImageFiles.pngData(image, scale: scale)
            let rep = NSBitmapImageRep(cgImage: image)
            rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            let tiff = rep.tiffRepresentation
            DispatchQueue.main.async {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.declareTypes([.png, .tiff], owner: nil)
                if let png { pasteboard.setData(png, forType: .png) }
                if let tiff { pasteboard.setData(tiff, forType: .tiff) }
            }
        }
    }
}
