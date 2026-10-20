#if DEBUG
import AppKit

/// Debug-only self test: drives the editor with synthetic events and writes offscreen snapshots.
///   SCREENSHOTTER_HISTORY_DIR=/tmp/h .build/debug/Screenshotter --debug-harness /tmp/out
@MainActor
enum DebugHarness {
    private static var failures = 0

    static func runIfRequested(delegate: AppDelegate) -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--debug-harness"), index + 1 < args.count else { return false }
        let output = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApp.setActivationPolicy(.regular)
        Task { await run(output: output, delegate: delegate) }
        return true
    }

    private static func run(output: URL, delegate: AppDelegate) async {
        let image = sampleScreenshot(size: CGSize(width: 900, height: 560), scale: 2)
        await testEditor(image: image, output: output)
        testOverlay(output: output)
        await testHistory(image: image, output: output, delegate: delegate)
        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Editor

    private static func testEditor(image: CGImage, output: URL) async {
        AppSettings.shared.lastColor = .red
        AppSettings.shared.lastSize = .medium
        let document = EditorDocument(itemID: UUID(), image: image, pixelScale: 2)
        let controller = EditorWindowController(document: document, createdAt: Date())
        controller.show()
        await pause(0.3)
        let canvas = controller.canvas

        document.tool = .arrow
        drag(canvas, from: CGPoint(x: 90, y: 450), to: CGPoint(x: 330, y: 260))
        document.tool = .rectangle
        drag(canvas, from: CGPoint(x: 380, y: 110), to: CGPoint(x: 640, y: 250))
        document.tool = .ellipse
        document.color = .green
        drag(canvas, from: CGPoint(x: 660, y: 320), to: CGPoint(x: 860, y: 470))
        document.tool = .highlighter
        document.color = .yellow
        drag(canvas, through: (0...20).map { CGPoint(x: 260 + CGFloat($0) * 9, y: 172) })
        document.tool = .pixelate
        drag(canvas, from: CGPoint(x: 410, y: 300), to: CGPoint(x: 620, y: 345))
        document.tool = .pen
        document.color = .purple
        drag(canvas, through: (0...30).map { CGPoint(x: 80 + CGFloat($0) * 6, y: 520 + sin(CGFloat($0) / 3) * 12) })

        document.tool = .text
        document.color = .blue
        document.size = .large
        click(canvas, at: CGPoint(x: 410, y: 400))
        check(canvas.window?.firstResponder is NSTextView, "text tool starts an inline editor")
        (canvas.window?.firstResponder as? NSTextView)?.insertText("Look here!", replacementRange: NSRange(location: NSNotFound, length: 0))
        await pause(0.1)
        snapshot(controller.window!, to: output.appendingPathComponent("editor-text-editing.png"))
        click(canvas, at: CGPoint(x: 10, y: 10)) // clicking elsewhere commits the text
        check(!(canvas.window?.firstResponder is NSTextView), "commit click doesn't open another text box")
        check(document.annotations.count == 7, "7 annotations drawn (got \(document.annotations.count))")
        check(document.annotations.last?.text == "Look here!", "text committed")

        document.undoManager.undo()
        check(document.annotations.count == 6, "undo removes the text")
        document.undoManager.redo()
        check(document.annotations.count == 7, "redo restores the text")

        // Select the rectangle by its outline, move it, recolor it, resize it.
        document.tool = .select
        click(canvas, at: CGPoint(x: 380, y: 230))
        let rectID = document.annotations[1].id
        check(document.selectedID == rectID, "clicking the rectangle outline selects it")
        drag(canvas, from: CGPoint(x: 380, y: 230), to: CGPoint(x: 400, y: 250))
        let moved = document.annotation(withID: rectID)!
        check(abs(moved.rect.minX - 400) < 1 && abs(moved.rect.minY - 130) < 1, "drag moves the selection (got \(moved.rect))")
        document.color = .blue
        check(document.annotation(withID: rectID)?.color == .blue, "color change applies to the selection")
        drag(canvas, from: CGPoint(x: 660, y: 270), to: CGPoint(x: 700, y: 290))
        let resized = document.annotation(withID: rectID)!
        check(abs(resized.rect.maxX - 700) < 1 && abs(resized.rect.maxY - 290) < 1, "corner handle resizes (got \(resized.rect))")
        document.undoManager.undo()
        check(abs(document.annotation(withID: rectID)!.rect.maxX - 660) < 1, "undo reverts the resize")

        // Clicking empty space with the select tool deselects; Delete removes the selection.
        click(canvas, at: CGPoint(x: 870, y: 40))
        check(document.selectedID == nil, "clicking empty space deselects")
        click(canvas, at: CGPoint(x: 90, y: 450))
        check(document.selectedAnnotation?.tool == .arrow, "clicking the arrow selects it")
        key(canvas, keyCode: 51, characters: "\u{7F}")
        check(!document.annotations.contains { $0.tool == .arrow }, "Delete removes the selected arrow")
        document.undoManager.undo()

        key(canvas, keyCode: 15, characters: "r")
        check(document.tool == .rectangle, "R switches to the rectangle tool")
        key(canvas, keyCode: 19, characters: "2")
        check(document.color == RGBAColor.palette[1], "2 picks the second palette color")
        document.tool = .select
        document.selectedID = nil

        await pause(0.1)
        snapshot(controller.window!, to: output.appendingPathComponent("editor.png"))

        let flattened = document.renderFlattened()
        check(flattened.width == image.width && flattened.height == image.height, "export keeps full resolution")
        try? ImageFiles.writePNG(flattened, scale: 2, to: output.appendingPathComponent("flattened.png"))

        // A tiny capture still gets a usable window.
        let small = sampleScreenshot(size: CGSize(width: 180, height: 90), scale: 2)
        let smallController = EditorWindowController(document: EditorDocument(itemID: UUID(), image: small, pixelScale: 2), createdAt: Date())
        smallController.show()
        await pause(0.2)
        snapshot(smallController.window!, to: output.appendingPathComponent("editor-small.png"))
        smallController.window?.orderOut(nil)
        controller.window?.orderOut(nil)
    }

    // MARK: Overlay

    private static func testOverlay(output: URL) {
        guard let screen = NSScreen.main else { return }
        let size = screen.frame.size
        let image = sampleScreenshot(size: size, scale: screen.backingScaleFactor, desktop: true)
        let windowFrame = CGRect(x: size.width * 0.18, y: size.height * 0.2, width: size.width * 0.5, height: size.height * 0.55)
        let view = SelectionView(snapshot: ScreenSnapshot(screen: screen, image: image), windowFrames: [windowFrame])

        view.updateHover(globalPoint: CGPoint(x: screen.frame.minX + windowFrame.midX, y: screen.frame.minY + windowFrame.midY))
        renderLayer(of: view, to: output.appendingPathComponent("overlay-hover.png"))

        let start = CGPoint(x: size.width * 0.3, y: size.height * 0.65)
        let end = CGPoint(x: size.width * 0.62, y: size.height * 0.35)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: start, windowNumber: 0))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: end, windowNumber: 0))
        renderLayer(of: view, to: output.appendingPathComponent("overlay-selecting.png"))
    }

    // MARK: History & settings

    private static func testHistory(image: CGImage, output: URL, delegate: AppDelegate) async {
        let store = HistoryStore.shared
        guard ProcessInfo.processInfo.environment["SCREENSHOTTER_HISTORY_DIR"] != nil else {
            print("skipping history (set SCREENSHOTTER_HISTORY_DIR)")
            return
        }
        store.clearAll()
        await pause(0.3)
        let first = store.add(image: sampleScreenshot(size: CGSize(width: 400, height: 300), scale: 2), scale: 2)
        store.add(image: sampleScreenshot(size: CGSize(width: 1200, height: 500), scale: 2), scale: 2)
        store.add(image: image, scale: 2)
        await pause(1.0)
        check(store.items.count == 3, "history has 3 items (got \(store.items.count))")

        let annotated = EditorDocument(itemID: first.id, image: store.loadImage(for: first, original: true)!, pixelScale: 2)
        annotated.add(annotated.newAnnotation(tool: .rectangle, at: CGPoint(x: 40, y: 40)).with { $0.end = CGPoint(x: 300, y: 200) })
        store.update(id: first.id, annotations: annotated.annotations, rendered: annotated.renderFlattened(), scale: 2)
        await pause(0.8)
        check(store.item(withID: first.id)?.annotations.count == 1, "annotations persisted to history")
        check(FileManager.default.fileExists(atPath: store.finalURL(for: first.id).path), "annotated PNG written")

        delegate.showHistory()
        await pause(1.5)
        if let window = NSApp.windows.first(where: { $0.title == "Screenshot History" }) {
            snapshot(window, to: output.appendingPathComponent("history.png"))
            window.orderOut(nil)
        }

        delegate.showSettings()
        await pause(0.6)
        if let window = NSApp.windows.first(where: { $0.title == "Screenshotter Settings" }) {
            snapshot(window, to: output.appendingPathComponent("settings.png"))
            window.orderOut(nil)
        }
    }

    // MARK: Event helpers

    private static func windowPoint(_ canvas: AnnotationCanvasView, imagePoint p: CGPoint) -> CGPoint {
        let rect = canvas.imageRect
        let viewPoint = CGPoint(x: rect.minX + p.x * canvas.viewScale, y: rect.minY + p.y * canvas.viewScale)
        return canvas.convert(viewPoint, to: nil)
    }

    private static func mouseEvent(_ type: NSEvent.EventType, at location: CGPoint, windowNumber: Int, clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
        )!
    }

    private static func drag(_ canvas: AnnotationCanvasView, from: CGPoint, to: CGPoint) {
        drag(canvas, through: (0...10).map { i in
            CGPoint(x: from.x + (to.x - from.x) * CGFloat(i) / 10, y: from.y + (to.y - from.y) * CGFloat(i) / 10)
        })
    }

    private static func drag(_ canvas: AnnotationCanvasView, through points: [CGPoint]) {
        let number = canvas.window!.windowNumber
        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: windowPoint(canvas, imagePoint: points[0]), windowNumber: number))
        for p in points.dropFirst() {
            canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: windowPoint(canvas, imagePoint: p), windowNumber: number))
        }
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: windowPoint(canvas, imagePoint: points.last!), windowNumber: number))
    }

    private static func click(_ canvas: AnnotationCanvasView, at p: CGPoint) {
        let number = canvas.window!.windowNumber
        let location = windowPoint(canvas, imagePoint: p)
        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: location, windowNumber: number))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: location, windowNumber: number))
    }

    private static func key(_ canvas: AnnotationCanvasView, keyCode: UInt16, characters: String) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: canvas.window!.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        )!
        canvas.keyDown(with: event)
    }

    private static func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "✓" : "✗") \(message)")
        if !condition { failures += 1 }
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    // MARK: Snapshots

    private static func snapshot(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func renderLayer(of view: NSView, to url: URL) {
        guard let layer = view.layer else { return }
        let scale: CGFloat = 1
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        if let image = context.makeImage() {
            try? ImageFiles.writePNG(image, scale: 1, to: url)
        }
    }

    /// A fake app window on a gradient, so annotations have something realistic to sit on.
    private static func sampleScreenshot(size: CGSize, scale: CGFloat, desktop: Bool = false) -> CGImage {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

        NSGradient(colors: [NSColor(srgbRed: 0.85, green: 0.55, blue: 0.45, alpha: 1), NSColor(srgbRed: 0.35, green: 0.3, blue: 0.6, alpha: 1)])!
            .draw(in: CGRect(origin: .zero, size: size), angle: 60)

        let window = desktop
            ? CGRect(x: size.width * 0.18, y: size.height * 0.25, width: size.width * 0.5, height: size.height * 0.55)
            : CGRect(origin: .zero, size: size).insetBy(dx: min(30, size.width * 0.08), dy: min(24, size.height * 0.1))
        let body = NSBezierPath(roundedRect: window, xRadius: 10, yRadius: 10)
        NSColor.white.setFill()
        body.fill()
        NSColor(white: 0.93, alpha: 1).setFill()
        CGRect(x: window.minX, y: window.minY, width: window.width, height: min(28, window.height / 4)).fill()
        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: window.minX + 12 + CGFloat(i) * 18, y: window.minY + 9, width: 11, height: 11)).fill()
        }
        let sidebar = CGRect(x: window.minX, y: window.minY + 28, width: min(180, window.width / 4), height: window.height - 28)
        NSColor(white: 0.96, alpha: 1).setFill()
        sidebar.fill()
        let font = NSFont.systemFont(ofSize: 13)
        var y = window.minY + 50
        var line = 0
        while y < window.maxY - 20 {
            let text = line % 4 == 0 ? "Section \(line / 4 + 1) — Quarterly overview" : "Lorem ipsum dolor sit amet, consectetur adipiscing elit \(line)."
            (text as NSString).draw(at: CGPoint(x: sidebar.maxX + 20, y: y), withAttributes: [
                .font: line % 4 == 0 ? NSFont.boldSystemFont(ofSize: 15) : font,
                .foregroundColor: NSColor(white: 0.15, alpha: 1),
            ])
            y += 26
            line += 1
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }
}

private extension Annotation {
    func with(_ body: (inout Annotation) -> Void) -> Annotation {
        var copy = self
        body(&copy)
        return copy
    }
}
#endif
