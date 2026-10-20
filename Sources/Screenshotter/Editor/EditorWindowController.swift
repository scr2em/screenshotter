import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let editorDocument: EditorDocument
    var onClose: ((EditorWindowController) -> Void)?

    let canvas: AnnotationCanvasView
    private var isFinishing = false

    init(document: EditorDocument, createdAt: Date) {
        self.editorDocument = document
        canvas = AnnotationCanvasView(document: document)

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Screenshot"
        window.subtitle = createdAt.formatted(date: .abbreviated, time: .standard)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 720, height: 360)
        super.init(window: window)
        window.delegate = self

        let toolbar = NSHostingView(rootView: EditorToolbar(document: editorDocument, actions: EditorActions(
            copy: { [weak self] in self?.copyImage() },
            save: { [weak self] in self?.saveImage(nil) },
            done: { [weak self] in self?.done() },
            discard: { [weak self] in self?.discard() }
        )))
        canvas.onDone = { [weak self] in self?.done() }
        canvas.onCopy = { [weak self] in self?.copyImage() }

        let container = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toolbar)
        container.addSubview(canvas)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        window.initialFirstResponder = canvas

        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let toolbarHeight = toolbar.fittingSize.height
        let width = min(max(editorDocument.imageSize.width + 56, window.minSize.width), visible.width * 0.9)
        let height = min(max(editorDocument.imageSize.height + 56 + toolbarHeight, window.minSize.height), visible.height * 0.9)
        window.setContentSize(NSSize(width: width, height: height))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
    }

    // MARK: Actions

    func copyImage() {
        canvas.commitTextEditing()
        Clipboard.copy(editorDocument.renderFlattened(), scale: editorDocument.pixelScale)
    }

    @objc func saveImage(_ sender: Any?) {
        canvas.commitTextEditing()
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ImageFiles.defaultFileName()
        panel.directoryURL = AppSettings.shared.saveFolderURL
        panel.beginSheetModal(for: window) { [editorDocument] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try ImageFiles.writePNG(editorDocument.renderFlattened(), scale: editorDocument.pixelScale, to: url)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// Copy the annotated image, persist it, and close.
    @objc func done() {
        canvas.commitTextEditing()
        let rendered = editorDocument.renderFlattened()
        let settings = AppSettings.shared
        Clipboard.copy(rendered, scale: editorDocument.pixelScale)
        if settings.saveToFolder {
            let url = ImageFiles.uniqueURL(in: settings.saveFolderURL, fileName: ImageFiles.defaultFileName())
            let scale = editorDocument.pixelScale
            DispatchQueue.global(qos: .utility).async {
                try? ImageFiles.writePNG(rendered, scale: scale, to: url)
            }
        }
        persist(rendered: rendered)
        isFinishing = true
        close()
    }

    private func discard() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete this screenshot?"
        alert.informativeText = "It will be removed from your history."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            HistoryStore.shared.delete(id: self.editorDocument.itemID)
            self.isFinishing = true
            self.close()
        }
    }

    private func persist(rendered: CGImage? = nil) {
        HistoryStore.shared.update(
            id: editorDocument.itemID,
            annotations: editorDocument.annotations,
            rendered: rendered ?? editorDocument.renderFlattened(),
            scale: editorDocument.pixelScale
        )
    }

    // MARK: NSWindowDelegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        editorDocument.undoManager
    }

    func windowWillClose(_ notification: Notification) {
        if !isFinishing {
            // Closed without "Done": keep the edits in history, but leave the clipboard alone.
            canvas.commitTextEditing()
            persist()
        }
        onClose?(self)
    }
}
