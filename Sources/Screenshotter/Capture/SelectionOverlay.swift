import AppKit
import QuartzCore

/// Shows a frozen copy of every screen and lets the user drag out a region or click a window.
@MainActor
final class SelectionOverlayController {
    private var panels: [OverlayPanel] = []
    private var completion: ((CaptureResult?) -> Void)?

    func begin(snapshots: [ScreenSnapshot], windowFrames: [CGRect], completion: @escaping (CaptureResult?) -> Void) {
        self.completion = completion
        let mouse = NSEvent.mouseLocation

        for snapshot in snapshots {
            let screenFrame = snapshot.screen.frame
            let localWindows = windowFrames.compactMap { frame -> CGRect? in
                let clipped = frame.intersection(screenFrame)
                guard !clipped.isNull, clipped.width > 40, clipped.height > 40 else { return nil }
                return clipped.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
            }
            let panel = OverlayPanel(frame: screenFrame)
            let view = SelectionView(snapshot: snapshot, windowFrames: localWindows)
            view.controller = self
            panel.contentView = view
            panel.setFrame(screenFrame, display: false)
            panels.append(panel)
        }

        NSApp.activate(ignoringOtherApps: true)
        for panel in panels { panel.orderFrontRegardless() }
        let keyPanel = panels.first { $0.frame.contains(mouse) } ?? panels.first
        keyPanel?.makeKeyAndOrderFront(nil)
        keyPanel?.makeFirstResponder(keyPanel?.contentView)
        for panel in panels {
            (panel.contentView as? SelectionView)?.updateHover(globalPoint: mouse)
        }
        NSCursor.crosshair.set()
    }

    func finish(with result: CaptureResult?) {
        guard let completion else { return }
        self.completion = nil
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        completion(result)
    }
}

final class OverlayPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Layer-hosting view: the frozen screen is the layer contents; dimming, highlight and size label are sublayers,
/// so mouse moves only touch a few small layers instead of redrawing a 5K bitmap.
final class SelectionView: NSView {
    weak var controller: SelectionOverlayController?

    private let snapshot: ScreenSnapshot
    private let windowFrames: [CGRect]

    private var hoverRect: CGRect?
    private var selection: CGRect?
    private var dragAnchor: CGPoint?
    private var lastDragPoint: CGPoint = .zero
    private var isDragging = false
    private var isMovingSelection = false

    private let dimLayer = CAShapeLayer()
    private let outlineLayer = CAShapeLayer()
    private let labelBackground = CALayer()
    private let labelText = CATextLayer()

    init(snapshot: ScreenSnapshot, windowFrames: [CGRect]) {
        self.snapshot = snapshot
        self.windowFrames = windowFrames
        super.init(frame: CGRect(origin: .zero, size: snapshot.screen.frame.size))

        let root = CALayer()
        root.contents = snapshot.image
        root.contentsGravity = .resize
        root.contentsScale = snapshot.screen.backingScaleFactor
        layer = root
        wantsLayer = true

        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.38).cgColor
        root.addSublayer(dimLayer)

        outlineLayer.fillColor = nil
        root.addSublayer(outlineLayer)

        labelBackground.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        labelBackground.cornerRadius = 5
        labelBackground.isHidden = true
        labelText.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        labelText.fontSize = 12
        labelText.foregroundColor = NSColor.white.cgColor
        labelText.alignmentMode = .center
        labelText.contentsScale = snapshot.screen.backingScaleFactor
        labelBackground.addSublayer(labelText)
        root.addSublayer(labelBackground)

        refreshLayers()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self
        ))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    // MARK: Hover

    func updateHover(globalPoint: CGPoint) {
        let local = CGPoint(x: globalPoint.x - snapshot.screen.frame.minX, y: globalPoint.y - snapshot.screen.frame.minY)
        updateHover(at: bounds.contains(local) ? local : nil)
    }

    private func updateHover(at point: CGPoint?) {
        guard !isDragging else { return }
        hoverRect = point.map { p in windowFrames.first { $0.contains(p) } ?? bounds }
        refreshLayers()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        updateHover(at: location(of: event))
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(at: location(of: event))
    }

    override func mouseExited(with event: NSEvent) {
        updateHover(at: nil)
    }

    // MARK: Dragging

    override func mouseDown(with event: NSEvent) {
        // Keyboard modifiers (Space, Esc) should go to the screen being dragged on.
        window?.makeKey()
        let point = location(of: event)
        dragAnchor = point
        lastDragPoint = point
        isDragging = false
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = dragAnchor else { return }
        let point = location(of: event)

        if !isDragging {
            guard hypot(point.x - anchor.x, point.y - anchor.y) >= 3 else { return }
            isDragging = true
            hoverRect = nil
        }

        if isMovingSelection, let current = selection {
            // Space held: move the whole selection instead of resizing it (same as the native tool).
            var moved = current.offsetBy(dx: point.x - lastDragPoint.x, dy: point.y - lastDragPoint.y)
            moved.origin.x = min(max(moved.minX, 0), bounds.width - moved.width)
            moved.origin.y = min(max(moved.minY, 0), bounds.height - moved.height)
            dragAnchor = CGPoint(x: anchor.x + moved.minX - current.minX, y: anchor.y + moved.minY - current.minY)
            selection = moved
        } else {
            var dx = point.x - anchor.x
            var dy = point.y - anchor.y
            if event.modifierFlags.contains(.shift) {
                let side = max(abs(dx), abs(dy))
                dx = dx < 0 ? -side : side
                dy = dy < 0 ? -side : side
            }
            let rect = CGRect(x: min(anchor.x, anchor.x + dx), y: min(anchor.y, anchor.y + dy), width: abs(dx), height: abs(dy))
            selection = rect.intersection(bounds)
        }
        lastDragPoint = point
        refreshLayers()
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragAnchor = nil
            isDragging = false
        }
        if isDragging {
            if let rect = selection?.integral, rect.width >= 4, rect.height >= 4 {
                complete(with: rect)
            } else {
                selection = nil
                refreshLayers()
            }
        } else {
            // A plain click captures the highlighted window, or the whole screen over the desktop.
            let point = location(of: event)
            complete(with: windowFrames.first { $0.contains(point) } ?? bounds)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.finish(with: nil)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: // Escape
            controller?.finish(with: nil)
        case 49: // Space
            isMovingSelection = true
        case 36, 76: // Return / Enter
            if let rect = selection?.integral, rect.width >= 4, rect.height >= 4 {
                complete(with: rect)
            }
        default:
            break
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { isMovingSelection = false }
    }

    // MARK: Helpers

    private func location(of event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    private func complete(with rect: CGRect) {
        let rect = rect.intersection(bounds)
        let scale = snapshot.scale
        let pixelRect = CGRect(
            x: rect.minX * scale,
            y: (bounds.height - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
        guard let cropped = snapshot.image.cropping(to: pixelRect) else {
            controller?.finish(with: nil)
            return
        }
        controller?.finish(with: CaptureResult(image: cropped, scale: scale))
    }

    private func refreshLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        dimLayer.frame = bounds
        outlineLayer.frame = bounds

        let dimPath = CGMutablePath()
        dimPath.addRect(bounds)

        if let selection {
            dimPath.addRect(selection)
            outlineLayer.path = CGPath(rect: selection.insetBy(dx: -0.5, dy: -0.5), transform: nil)
            outlineLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
            outlineLayer.fillColor = nil
            outlineLayer.lineWidth = 1
            showLabel(for: selection)
        } else if let hoverRect {
            dimPath.addRect(hoverRect)
            outlineLayer.path = CGPath(rect: hoverRect.insetBy(dx: 1.5, dy: 1.5), transform: nil)
            outlineLayer.strokeColor = NSColor.controlAccentColor.cgColor
            outlineLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            outlineLayer.lineWidth = 3
            labelBackground.isHidden = true
        } else {
            outlineLayer.path = nil
            labelBackground.isHidden = true
        }
        dimLayer.path = dimPath
    }

    private func showLabel(for rect: CGRect) {
        let text = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
        labelText.string = text
        let textSize = (text as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        let size = CGSize(width: ceil(textSize.width) + 14, height: 22)

        var origin = CGPoint(x: rect.maxX - size.width, y: rect.minY - size.height - 6)
        if origin.y < 4 { origin.y = rect.minY + 6 }
        origin.x = min(max(origin.x, 4), bounds.width - size.width - 4)

        labelBackground.frame = CGRect(origin: origin, size: size)
        labelText.frame = CGRect(x: 0, y: (size.height - ceil(textSize.height)) / 2 - 1, width: size.width, height: ceil(textSize.height))
        labelBackground.isHidden = false
    }
}
