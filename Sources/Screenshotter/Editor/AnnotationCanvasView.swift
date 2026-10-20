import AppKit
import Combine

/// Displays the screenshot scaled to fit and handles drawing, selecting, moving and text editing.
final class AnnotationCanvasView: NSView, NSTextViewDelegate {
    let document: EditorDocument
    var onDone: (() -> Void)?
    var onCopy: (() -> Void)?

    private enum Handle {
        case start, end
        case corner(fixed: CGPoint)
    }

    private enum Interaction {
        case idle
        case drawing
        case moving(id: UUID, last: CGPoint)
        case resizing(id: UUID, handle: Handle)
    }

    private var interaction: Interaction = .idle
    private var draft: Annotation?
    private var cancellables = Set<AnyCancellable>()

    private var textView: NSTextView?
    private var editingAnnotation: Annotation?
    private var editingIsNew = false

    private let padding: CGFloat = 28

    init(document: EditorDocument) {
        self.document = document
        super.init(frame: .zero)

        document.objectWillChange
            .sink { [weak self] _ in self?.needsDisplay = true }
            .store(in: &cancellables)
        document.$tool
            .dropFirst()
            .sink { [weak self] _ in self?.toolDidChange() }
            .store(in: &cancellables)
        document.$color
            .combineLatest(document.$size)
            .dropFirst()
            .sink { [weak self] color, size in self?.styleDidChange(color: color, size: size) }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { document.undoManager }

    // MARK: Geometry

    var imageRect: CGRect {
        let size = document.imageSize
        let available = CGSize(width: max(bounds.width - padding * 2, 40), height: max(bounds.height - padding * 2, 40))
        let scale = min(1, available.width / size.width, available.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: ((bounds.width - width) / 2).rounded(), y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
    }

    var viewScale: CGFloat { imageRect.width / document.imageSize.width }

    private func imagePoint(_ viewPoint: CGPoint) -> CGPoint {
        let rect = imageRect, scale = viewScale
        return CGPoint(x: (viewPoint.x - rect.minX) / scale, y: (viewPoint.y - rect.minY) / scale)
    }

    private func viewPoint(_ imagePoint: CGPoint) -> CGPoint {
        let rect = imageRect, scale = viewScale
        return CGPoint(x: rect.minX + imagePoint.x * scale, y: rect.minY + imagePoint.y * scale)
    }

    private func viewRect(_ imageRect: CGRect) -> CGRect {
        let origin = viewPoint(imageRect.origin)
        return CGRect(origin: origin, size: CGSize(width: imageRect.width * viewScale, height: imageRect.height * viewScale))
    }

    private func imagePoint(for event: NSEvent) -> CGPoint {
        imagePoint(convert(event.locationInWindow, from: nil))
    }

    private func clampToImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), document.imageSize.width), y: min(max(p.y, 0), document.imageSize.height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let textView, let editingAnnotation {
            applyTextStyle(to: textView, annotation: editingAnnotation)
            layoutTextView()
        }
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()

        let rect = imageRect
        let scale = viewScale

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        NSColor.white.setFill()
        rect.fill()
        NSGraphicsContext.restoreGraphicsState()

        document.nsImage.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
                              hints: [.interpolation: NSImageInterpolation.high.rawValue])

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scale(by: scale)
        transform.concat()

        let needsPixelated = draft?.tool == .pixelate || document.annotations.contains { $0.tool == .pixelate }
        let context = AnnotationRenderer.Context(
            pixelated: needsPixelated ? document.pixelatedImage : nil,
            imageBounds: CGRect(origin: .zero, size: document.imageSize),
            shadowScale: scale
        )
        for annotation in document.annotations where annotation.id != editingAnnotation?.id {
            AnnotationRenderer.draw(annotation, in: context)
        }
        if let draft {
            AnnotationRenderer.draw(draft, in: context)
        }
        NSGraphicsContext.restoreGraphicsState()

        if editingAnnotation == nil, let selected = document.selectedAnnotation {
            drawSelectionChrome(for: selected)
        }
    }

    private func drawSelectionChrome(for annotation: Annotation) {
        let accent = NSColor.controlAccentColor
        if annotation.tool != .arrow && annotation.tool != .line {
            let outline = NSBezierPath(rect: viewRect(annotation.bounds).insetBy(dx: -4, dy: -4))
            outline.lineWidth = 1
            outline.setLineDash([4, 3], count: 2, phase: 0)
            accent.setStroke()
            outline.stroke()
        }
        for (_, point) in handles(for: annotation) {
            let center = viewPoint(point)
            let knob = NSBezierPath(ovalIn: CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9))
            NSColor.white.setFill()
            knob.fill()
            knob.lineWidth = 1.5
            accent.setStroke()
            knob.stroke()
        }
    }

    // MARK: Handles

    private func handles(for a: Annotation) -> [(Handle, CGPoint)] {
        switch a.tool {
        case .arrow, .line:
            return [(.start, a.start), (.end, a.end)]
        case .rectangle, .ellipse, .pixelate:
            let r = a.rect
            return [
                (.corner(fixed: CGPoint(x: r.maxX, y: r.maxY)), CGPoint(x: r.minX, y: r.minY)),
                (.corner(fixed: CGPoint(x: r.minX, y: r.maxY)), CGPoint(x: r.maxX, y: r.minY)),
                (.corner(fixed: CGPoint(x: r.maxX, y: r.minY)), CGPoint(x: r.minX, y: r.maxY)),
                (.corner(fixed: CGPoint(x: r.minX, y: r.minY)), CGPoint(x: r.maxX, y: r.maxY)),
            ]
        default:
            return []
        }
    }

    private func handle(of annotation: Annotation, at point: CGPoint) -> Handle? {
        let tolerance = 8 / viewScale
        return handles(for: annotation).first { hypot($0.1.x - point.x, $0.1.y - point.y) <= tolerance }?.0
    }

    /// Shift: snap lines to 45° and make boxes square.
    private func constrained(from origin: CGPoint, to p: CGPoint, tool: AnnotationTool) -> CGPoint {
        let dx = p.x - origin.x, dy = p.y - origin.y
        if tool == .arrow || tool == .line {
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            let length = hypot(dx, dy)
            return CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
        }
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: origin.x + (dx < 0 ? -side : side), y: origin.y + (dy < 0 ? -side : side))
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if textView != nil {
            commitTextEditing()
            return
        }
        window?.makeFirstResponder(self)
        let point = imagePoint(for: event)
        let tolerance = 5 / viewScale

        switch document.tool {
        case .select:
            if let selected = document.selectedAnnotation, let handle = handle(of: selected, at: point) {
                document.beginLiveChange()
                interaction = .resizing(id: selected.id, handle: handle)
            } else if let hit = document.hitTest(point, tolerance: tolerance) {
                document.selectedID = hit.id
                if event.clickCount == 2, hit.tool == .text {
                    beginTextEditing(hit, isNew: false)
                    return
                }
                document.beginLiveChange()
                interaction = .moving(id: hit.id, last: point)
            } else {
                document.selectedID = nil
            }

        case .text:
            if let hit = document.hitTest(point, tolerance: tolerance), hit.tool == .text {
                beginTextEditing(hit, isNew: false)
            } else {
                var annotation = document.newAnnotation(tool: .text, at: clampToImage(point))
                annotation.start.y -= annotation.fontSize * 0.6
                beginTextEditing(annotation, isNew: true)
            }

        default:
            document.selectedID = nil
            draft = document.newAnnotation(tool: document.tool, at: clampToImage(point))
            interaction = .drawing
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = imagePoint(for: event)
        let shift = event.modifierFlags.contains(.shift)

        switch interaction {
        case .idle:
            return

        case .drawing:
            guard var current = draft else { return }
            let clamped = clampToImage(point)
            if current.tool.isFreehand {
                if let last = current.points.last, hypot(clamped.x - last.x, clamped.y - last.y) < 1.5 / viewScale { return }
                current.points.append(clamped)
            } else {
                current.end = shift ? constrained(from: current.start, to: clamped, tool: current.tool) : clamped
            }
            draft = current

        case let .moving(id, last):
            document.liveUpdate(id: id) { $0.offset(by: CGVector(dx: point.x - last.x, dy: point.y - last.y)) }
            interaction = .moving(id: id, last: point)

        case let .resizing(id, handle):
            document.liveUpdate(id: id) { a in
                switch handle {
                case .start:
                    a.start = shift ? constrained(from: a.end, to: point, tool: a.tool) : point
                case .end:
                    a.end = shift ? constrained(from: a.start, to: point, tool: a.tool) : point
                case let .corner(fixed):
                    a.start = fixed
                    a.end = shift ? constrained(from: fixed, to: point, tool: a.tool) : point
                }
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch interaction {
        case .idle:
            break
        case .drawing:
            if let draft, draft.isMeaningful { document.add(draft) }
            draft = nil
        case .moving:
            document.endLiveChange(actionName: "Move")
        case .resizing:
            document.endLiveChange(actionName: "Resize")
        }
        interaction = .idle
        needsDisplay = true
    }

    override func resetCursorRects() {
        let cursor: NSCursor = switch document.tool {
        case .select: .arrow
        case .text: .iBeam
        default: .crosshair
        }
        addCursorRect(imageRect, cursor: cursor)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if modifiers.isEmpty, let character = event.charactersIgnoringModifiers?.lowercased().first {
            if let tool = AnnotationTool.forShortcut(character) {
                document.tool = tool
                return
            }
            if let digit = character.wholeNumberValue, (1...RGBAColor.palette.count).contains(digit) {
                document.color = RGBAColor.palette[digit - 1]
                return
            }
        }

        switch Int(event.keyCode) {
        case 51, 117: // Delete, Forward Delete
            document.deleteSelected()
        case 53: // Escape
            document.selectedID = nil
        case 36, 76: // Return, Enter
            onDone?()
        case 123, 124, 125, 126: // Arrow keys nudge the selection
            guard let id = document.selectedID else { return }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let delta: CGVector = switch Int(event.keyCode) {
            case 123: CGVector(dx: -step, dy: 0)
            case 124: CGVector(dx: step, dy: 0)
            case 125: CGVector(dx: 0, dy: step)
            default: CGVector(dx: 0, dy: -step)
            }
            document.beginLiveChange()
            document.liveUpdate(id: id) { $0.offset(by: delta) }
            document.endLiveChange(actionName: "Move")
        default:
            super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) {
        onCopy?()
    }

    @objc func delete(_ sender: Any?) {
        document.deleteSelected()
    }

    // MARK: Document observation

    private func toolDidChange() {
        commitTextEditing()
        window?.invalidateCursorRects(for: self)
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func styleDidChange(color: RGBAColor, size: StrokeSize) {
        guard let textView, var annotation = editingAnnotation else { return }
        annotation.color = color
        annotation.size = size
        editingAnnotation = annotation
        applyTextStyle(to: textView, annotation: annotation)
        layoutTextView()
    }

    // MARK: Text editing

    private func beginTextEditing(_ annotation: Annotation, isNew: Bool) {
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.string = annotation.text

        self.textView = textView
        editingAnnotation = annotation
        editingIsNew = isNew
        document.selectedID = nil

        applyTextStyle(to: textView, annotation: annotation)
        addSubview(textView)
        layoutTextView()
        window?.makeFirstResponder(textView)
        if !isNew { textView.selectAll(nil) }
        needsDisplay = true
    }

    private func applyTextStyle(to textView: NSTextView, annotation: Annotation) {
        let font = NSFont.systemFont(ofSize: annotation.fontSize * viewScale, weight: .semibold)
        let color = annotation.color.nsColor
        textView.font = font
        textView.textColor = color
        textView.insertionPointColor = color
        textView.typingAttributes = [.font: font, .foregroundColor: color]
    }

    private func layoutTextView() {
        guard let textView, var annotation = editingAnnotation else { return }
        annotation.text = textView.string
        var size = annotation.textSize
        let lineHeight = ceil(annotation.font.ascender - annotation.font.descender + annotation.font.leading)
        if annotation.text.hasSuffix("\n") { size.height += lineHeight }
        size.height = max(size.height, lineHeight)
        textView.frame = CGRect(
            origin: viewPoint(annotation.start),
            size: CGSize(width: ceil(size.width * viewScale) + 6, height: ceil(size.height * viewScale) + 2)
        )
    }

    func commitTextEditing() {
        guard let textView, var annotation = editingAnnotation else { return }
        self.textView = nil
        editingAnnotation = nil
        textView.delegate = nil
        let text = textView.string
        textView.removeFromSuperview()
        window?.makeFirstResponder(self)

        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        annotation.text = text
        if editingIsNew {
            if !isEmpty { document.add(annotation) }
        } else if isEmpty {
            document.remove(id: annotation.id)
        } else {
            document.update(annotation, actionName: "Edit Text")
        }
        needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        layoutTextView()
    }

    func textDidEndEditing(_ notification: Notification) {
        commitTextEditing()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                commitTextEditing()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            commitTextEditing()
            return true
        default:
            return false
        }
    }
}

extension AnnotationCanvasView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(delete(_:)): document.selectedID != nil
        default: true
        }
    }
}
