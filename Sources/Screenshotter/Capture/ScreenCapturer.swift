import AppKit
import ScreenCaptureKit

/// A frozen image of one display, taken before the selection overlay appears.
struct ScreenSnapshot {
    let screen: NSScreen
    let image: CGImage

    /// Pixels per point.
    var scale: CGFloat { CGFloat(image.width) / screen.frame.width }
}

struct CaptureResult {
    let image: CGImage
    let scale: CGFloat
}

enum ScreenCapturer {
    @MainActor
    static func snapshotAllScreens() async throws -> [ScreenSnapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var snapshots: [ScreenSnapshot] = []
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else { continue }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.showsCursor = false
            config.captureResolution = .best
            config.colorSpaceName = CGColorSpace.sRGB

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            snapshots.append(ScreenSnapshot(screen: screen, image: image))
        }
        return snapshots
    }
}

enum WindowList {
    /// Frames of normal on-screen windows, front to back, in Cocoa global coordinates (origin bottom-left).
    static func visibleWindowFrames() -> [CGRect] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return info.compactMap { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 40, bounds.height > 40 else { return nil }
            if let alpha = window[kCGWindowAlpha as String] as? Double, alpha < 0.01 { return nil }
            return CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
