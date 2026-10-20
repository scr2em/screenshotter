import AppKit
import CoreGraphics

@MainActor
enum ScreenRecordingPermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Returns true if capture can proceed. Otherwise triggers the system prompt (first time) and explains what to do.
    static func ensureGranted() -> Bool {
        if isGranted { return true }
        if CGRequestScreenCaptureAccess() { return true }
        showInstructions()
        return false
    }

    static func showInstructions() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = """
            Screenshotter needs permission to capture your screen.

            Open System Settings → Privacy & Security → Screen & System Audio Recording, \
            turn on Screenshotter, then quit and reopen the app.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            openSystemSettings()
        }
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum CaptureSound {
    private static let sound: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        return NSSound(contentsOfFile: path, byReference: true)
    }()

    static func play() {
        sound?.stop()
        sound?.play()
    }
}
