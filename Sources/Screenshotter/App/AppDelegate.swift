import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings.shared
    private let history = HistoryStore.shared
    private let hotKeys = HotKeyCenter()
    private let overlay = SelectionOverlayController()

    private var statusItem: NSStatusItem!
    private var captureMenuItem: NSMenuItem!
    private var recentMenu = NSMenu(title: "Recent")
    private var cancellables = Set<AnyCancellable>()
    private var hotKeyRegistered = false

    private var isCapturing = false
    private var previousApp: NSRunningApplication?

    private var editors: [EditorWindowController] = []
    private var historyWindow: NSWindow?
    private var settingsWindow: NSWindow?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(delegate: self)
        #if DEBUG
        if DebugHarness.runIfRequested(delegate: self) { return }
        #endif
        setUpStatusItem()

        hotKeys.onPress = { [weak self] in self?.captureArea() }
        settings.$hotKey
            .combineLatest(settings.$isRecordingHotKey)
            .sink { [weak self] combo, isRecording in
                guard let self else { return }
                if isRecording {
                    hotKeys.unregister()
                } else {
                    hotKeyRegistered = hotKeys.register(combo)
                    if !hotKeyRegistered {
                        NSLog("Screenshotter: could not register shortcut %@ (already in use?)", combo.displayString)
                    }
                }
                updateCaptureMenuItem(combo)
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil
        )

        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            // Start at login by default; the toggle in Settings turns it off.
            do {
                try SMAppService.mainApp.register()
            } catch {
                NSLog("Screenshotter: could not enable launch at login: %@", error.localizedDescription)
            }
            showSettings()
            if !ScreenRecordingPermission.isGranted {
                _ = CGRequestScreenCaptureAccess()
            }
        }
    }

    /// Opening the app again (Finder, Spotlight) shows the history.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showHistory()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Screenshotter")
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()
        captureMenuItem = NSMenuItem(title: "Capture Area", action: #selector(captureAreaFromMenu), keyEquivalent: "")
        captureMenuItem.target = self
        menu.addItem(captureMenuItem)
        menu.addItem(item("Capture Full Screen", #selector(captureFullScreenFromMenu)))
        menu.addItem(.separator())

        let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        recentMenu.delegate = self
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)
        menu.addItem(item("Show History…", #selector(showHistory), key: "y"))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Screenshotter", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        return item
    }

    private func updateCaptureMenuItem(_ combo: KeyCombo) {
        guard let captureMenuItem else { return }
        if let key = combo.menuKeyEquivalent {
            captureMenuItem.keyEquivalent = key
            captureMenuItem.keyEquivalentModifierMask = combo.modifierFlags
        } else {
            captureMenuItem.keyEquivalent = ""
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let recent = history.items.prefix(8)
        if recent.isEmpty {
            let empty = NSMenuItem(title: "No screenshots yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for entry in recent {
            let title = entry.createdAt.formatted(date: .omitted, time: .shortened)
                + "  ·  \(entry.pixelWidth) × \(entry.pixelHeight)"
            let menuItem = NSMenuItem(title: title, action: #selector(openRecent(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = entry.id
            if let thumbnail = history.cachedThumbnail(for: entry) {
                let ratio = thumbnail.size.width / max(thumbnail.size.height, 1)
                let size = ratio >= 1 ? NSSize(width: 64, height: 64 / ratio) : NSSize(width: 40 * ratio, height: 40)
                let resized = NSImage(size: size, flipped: false) { rect in
                    thumbnail.draw(in: rect)
                    return true
                }
                menuItem.image = resized
            }
            menu.addItem(menuItem)
        }
        menu.addItem(.separator())
        let copyLast = NSMenuItem(title: "Copy Latest", action: #selector(copyLatest), keyEquivalent: "")
        copyLast.target = self
        menu.addItem(copyLast)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let entry = history.item(withID: id) else { return }
        openEditor(for: entry)
    }

    @objc private func copyLatest() {
        if let latest = history.items.first { history.copyToClipboard(latest) }
    }

    // MARK: Capture

    @objc func captureAreaFromMenu() {
        // Let the menu finish closing so it isn't in the capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.captureArea() }
    }

    @objc func captureFullScreenFromMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.captureFullScreen() }
    }

    func captureArea() {
        guard !isCapturing, ScreenRecordingPermission.ensureGranted() else { return }
        isCapturing = true
        previousApp = NSWorkspace.shared.frontmostApplication
        let windowFrames = WindowList.visibleWindowFrames()

        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshots = try await ScreenCapturer.snapshotAllScreens()
                guard !snapshots.isEmpty else { throw CaptureError.noDisplays }
                overlay.begin(snapshots: snapshots, windowFrames: windowFrames) { [weak self] result in
                    guard let self else { return }
                    isCapturing = false
                    if let result {
                        handleCapture(result)
                    } else {
                        restorePreviousApp()
                    }
                }
            } catch {
                isCapturing = false
                showCaptureError(error)
            }
        }
    }

    func captureFullScreen() {
        guard !isCapturing, ScreenRecordingPermission.ensureGranted() else { return }
        isCapturing = true
        previousApp = NSWorkspace.shared.frontmostApplication
        let mouse = NSEvent.mouseLocation

        Task {
            defer { isCapturing = false }
            do {
                let snapshots = try await ScreenCapturer.snapshotAllScreens()
                guard let snapshot = snapshots.first(where: { $0.screen.frame.contains(mouse) }) ?? snapshots.first else {
                    throw CaptureError.noDisplays
                }
                handleCapture(CaptureResult(image: snapshot.image, scale: snapshot.scale))
            } catch {
                showCaptureError(error)
            }
        }
    }

    private func handleCapture(_ result: CaptureResult) {
        if settings.playSound { CaptureSound.play() }
        let entry = history.add(image: result.image, scale: result.scale)
        if settings.copyToClipboard {
            Clipboard.copy(result.image, scale: result.scale)
        }

        if settings.openEditorAfterCapture {
            let document = EditorDocument(itemID: entry.id, image: result.image, pixelScale: result.scale)
            presentEditor(document: document, createdAt: entry.createdAt)
        } else {
            if settings.saveToFolder {
                let url = ImageFiles.uniqueURL(in: settings.saveFolderURL, fileName: ImageFiles.defaultFileName())
                DispatchQueue.global(qos: .utility).async {
                    try? ImageFiles.writePNG(result.image, scale: result.scale, to: url)
                }
            }
            restorePreviousApp()
        }
    }

    private func restorePreviousApp() {
        let hasOwnWindows = !editors.isEmpty || historyWindow?.isVisible == true || settingsWindow?.isVisible == true
        if !hasOwnWindows, let previousApp, previousApp != NSRunningApplication.current {
            previousApp.activate()
        }
        previousApp = nil
    }

    private func showCaptureError(_ error: Error) {
        if !ScreenRecordingPermission.isGranted {
            ScreenRecordingPermission.showInstructions()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Couldn't capture the screen"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private enum CaptureError: LocalizedError {
        case noDisplays
        var errorDescription: String? { "No displays were available to capture." }
    }

    // MARK: Windows

    func openEditor(for entry: HistoryItem) {
        if let existing = editors.first(where: { $0.editorDocument.itemID == entry.id }) {
            showWindow(existing.window)
            return
        }
        guard let image = history.loadImage(for: entry, original: true) else {
            NSSound.beep()
            return
        }
        let document = EditorDocument(itemID: entry.id, image: image, pixelScale: entry.scale, annotations: entry.annotations)
        presentEditor(document: document, createdAt: entry.createdAt)
    }

    private func presentEditor(document: EditorDocument, createdAt: Date) {
        let controller = EditorWindowController(document: document, createdAt: createdAt)
        controller.onClose = { [weak self] closed in
            self?.editors.removeAll { $0 === closed }
        }
        editors.append(controller)
        // Cascade so multiple editors don't stack exactly on top of each other.
        if editors.count > 1, let previous = editors.dropLast().last?.window, let window = controller.window {
            window.setFrameTopLeftPoint(NSPoint(x: previous.frame.minX + 24, y: previous.frame.maxY - 24))
        }
        becomeRegularApp()
        controller.show()
    }

    @objc func showHistory() {
        if historyWindow == nil {
            let view = HistoryView(store: history, settings: settings) { [weak self] entry in
                self?.openEditor(for: entry)
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Screenshot History"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 900, height: 620))
            window.center()
            window.setFrameAutosaveName("HistoryWindow")
            historyWindow = window
        }
        showWindow(historyWindow)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings) { [weak self] in self?.hotKeyRegistered ?? true }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Screenshotter Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        showWindow(settingsWindow)
    }

    private func showWindow(_ window: NSWindow?) {
        becomeRegularApp()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Show a Dock icon (and allow ⌘-Tab) only while one of our windows is open.
    private func becomeRegularApp() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        let ownWindows = [historyWindow, settingsWindow].compactMap { $0 } + editors.compactMap(\.window)
        guard ownWindows.contains(closing) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let stillOpen = ([historyWindow, settingsWindow].compactMap { $0 } + editors.compactMap(\.window))
                .contains { $0.isVisible && $0 !== closing }
            if !stillOpen {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
