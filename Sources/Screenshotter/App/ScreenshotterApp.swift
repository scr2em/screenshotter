import AppKit

@main
@MainActor
enum ScreenshotterApp {
    // Held statically: NSApplication.delegate is weak.
    static let appDelegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = appDelegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
