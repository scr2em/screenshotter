import AppKit
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins

/// State of one open screenshot: the base image, its annotations, the active tool/style and undo history.
@MainActor
final class EditorDocument: ObservableObject {
    let itemID: UUID
    let image: CGImage
    /// Pixels per point of `image`.
    let pixelScale: CGFloat
    let imageSize: CGSize
    let nsImage: NSImage
    let sizeMultiplier: CGFloat
    let undoManager = UndoManager()

    @Published private(set) var annotations: [Annotation]
    @Published var tool: AnnotationTool {
        didSet {
            if tool != .select { selectedID = nil }
            AppSettings.shared.lastTool = tool
        }
    }
    @Published var color: RGBAColor {
        didSet {
            applyStyleToSelection()
            if !isSyncingStyle { AppSettings.shared.lastColor = color }
        }
    }
    @Published var size: StrokeSize {
        didSet {
            applyStyleToSelection()
            if !isSyncingStyle { AppSettings.shared.lastSize = size }
        }
    }
    @Published var selectedID: UUID? {
        didSet {
            // Reflect the selected annotation's style in the toolbar without re-applying it.
            guard let selected = selectedAnnotation else { return }
            isSyncingStyle = true
            color = selected.color
            size = selected.size
            isSyncingStyle = false
        }
    }

    private var isSyncingStyle = false
    private var liveChangeSnapshot: [Annotation]?

    private(set) lazy var pixelatedImage: NSImage? = Self.makePixelated(image, size: imageSize, pixelScale: pixelScale)

    init(itemID: UUID, image: CGImage, pixelScale: CGFloat, annotations: [Annotation] = []) {
        self.itemID = itemID
        self.image = image
        self.pixelScale = pixelScale
        self.imageSize = CGSize(width: CGFloat(image.width) / pixelScale, height: CGFloat(image.height) / pixelScale)
        self.nsImage = NSImage(cgImage: image, size: imageSize)
        self.sizeMultiplier = min(max(max(imageSize.width, imageSize.height) / 1400, 1), 2.5)
        self.annotations = annotations
        undoManager.groupsByEvent = false

        let settings = AppSettings.shared
        self.tool = settings.lastTool == .select ? .arrow : settings.lastTool
        self.color = settings.lastColor
        self.size = settings.lastSize
    }

    var selectedAnnotation: Annotation? {
        selectedID.flatMap { id in annotations.first { $0.id == id } }
    }

    func annotation(withID id: UUID) -> Annotation? {
        annotations.first { $0.id == id }
    }

    func newAnnotation(tool: AnnotationTool, at point: CGPoint) -> Annotation {
        Annotation(tool: tool, color: color, size: size, scaleFactor: sizeMultiplier, start: point, end: point, points: [point])
    }

    /// Topmost annotation under the point.
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Annotation? {
        annotations.last { $0.hitTest(point, tolerance: tolerance) }
    }

    // MARK: Undoable edits

    func add(_ annotation: Annotation) {
        setAnnotations(annotations + [annotation], actionName: "Add \(annotation.tool.title)")
    }

    func update(_ annotation: Annotation, actionName: String) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        var copy = annotations
        copy[index] = annotation
        setAnnotations(copy, actionName: actionName)
    }

    func remove(id: UUID) {
        if selectedID == id { selectedID = nil }
        setAnnotations(annotations.filter { $0.id != id }, actionName: "Delete")
    }

    func deleteSelected() {
        if let selectedID { remove(id: selectedID) }
    }

    func setAnnotations(_ newValue: [Annotation], actionName: String) {
        let oldValue = annotations
        guard oldValue != newValue else { return }
        annotations = newValue
        if let selectedID, !newValue.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        // Each edit is its own undo step, independent of how AppKit groups events.
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated {
                document.setAnnotations(oldValue, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }

    /// Dragging changes many times per second; record a single undo step for the whole gesture.
    func beginLiveChange() {
        liveChangeSnapshot = annotations
    }

    func liveUpdate(id: UUID, _ body: (inout Annotation) -> Void) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        body(&annotations[index])
    }

    func endLiveChange(actionName: String) {
        guard let snapshot = liveChangeSnapshot else { return }
        liveChangeSnapshot = nil
        let final = annotations
        annotations = snapshot
        setAnnotations(final, actionName: actionName)
    }

    private func applyStyleToSelection() {
        guard !isSyncingStyle, var selected = selectedAnnotation,
              selected.color != color || selected.size != size else { return }
        selected.color = color
        selected.size = size
        update(selected, actionName: "Change Style")
    }

    // MARK: Rendering

    /// Flattens the annotations onto the screenshot at full pixel resolution.
    func renderFlattened() -> CGImage {
        guard !annotations.isEmpty else { return image }
        let width = image.width, height = image.height
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Switch to top-left-origin image points, which is what annotations are stored in.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: pixelScale, y: -pixelScale)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let renderContext = AnnotationRenderer.Context(
            pixelated: annotations.contains { $0.tool == .pixelate } ? pixelatedImage : nil,
            imageBounds: CGRect(origin: .zero, size: imageSize),
            shadowScale: pixelScale
        )
        for annotation in annotations {
            AnnotationRenderer.draw(annotation, in: renderContext)
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage() ?? image
    }

    private static func makePixelated(_ image: CGImage, size: CGSize, pixelScale: CGFloat) -> NSImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.pixellate()
        filter.inputImage = input.clampedToExtent()
        filter.scale = Float(12 * pixelScale)
        filter.center = .zero
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let cgImage = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: size)
    }
}
