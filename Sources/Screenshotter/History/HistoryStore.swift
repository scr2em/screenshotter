import AppKit
import Combine

struct HistoryItem: Identifiable, Codable, Hashable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var pixelWidth: Int
    var pixelHeight: Int
    var scale: CGFloat
    /// Kept so a screenshot can be reopened and its annotations edited again.
    var annotations: [Annotation]

    static func == (lhs: HistoryItem, rhs: HistoryItem) -> Bool {
        lhs.id == rhs.id && lhs.updatedAt == rhs.updatedAt
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(updatedAt)
    }
}

/// Every capture is stored in its own folder:
///   original.png  – the untouched capture
///   final.png     – the annotated version (only when there are annotations)
///   thumb.png     – a small preview for the history grid and menu
///   meta.json     – the HistoryItem, including the editable annotations
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var items: [HistoryItem] = []

    let directory: URL
    private let ioQueue = DispatchQueue(label: "Screenshotter.history-io", qos: .utility)
    private var deletedIDs = Set<UUID>()
    private let thumbnailCache = NSCache<NSString, NSImage>()

    private init() {
        if let override = ProcessInfo.processInfo.environment["SCREENSHOTTER_HISTORY_DIR"] {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            directory = support.appendingPathComponent("Screenshotter/History", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    // MARK: Paths

    func folder(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    func originalURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("original.png") }
    func finalURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("final.png") }
    func thumbnailURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("thumb.png") }
    private func metaURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("meta.json") }

    /// The image to show/share: the annotated version if there is one.
    func imageURL(for item: HistoryItem) -> URL {
        item.annotations.isEmpty ? originalURL(for: item.id) : finalURL(for: item.id)
    }

    func item(withID id: UUID) -> HistoryItem? {
        items.first { $0.id == id }
    }

    // MARK: Mutations

    /// Records a fresh capture. Files are written in the background; the item shows up once they exist.
    @discardableResult
    func add(image: CGImage, scale: CGFloat) -> HistoryItem {
        let now = Date()
        let item = HistoryItem(
            id: UUID(), createdAt: now, updatedAt: now,
            pixelWidth: image.width, pixelHeight: image.height, scale: scale, annotations: []
        )
        let folder = folder(for: item.id)
        let originalURL = originalURL(for: item.id)
        let thumbnailURL = thumbnailURL(for: item.id)
        let metaURL = metaURL(for: item.id)
        let meta = try? Self.encoder.encode(item)

        ioQueue.async { [weak self] in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try ImageFiles.writePNG(image, scale: scale, to: originalURL)
                if let thumbnail = ImageFiles.thumbnail(of: image, maxPixelSize: 640) {
                    try ImageFiles.writePNG(thumbnail, scale: 1, to: thumbnailURL)
                }
                try meta?.write(to: metaURL, options: .atomic)
            } catch {
                NSLog("Screenshotter: failed to save capture: \(error)")
                return
            }
            DispatchQueue.main.async {
                self?.didAdd(item)
            }
        }
        return item
    }

    private func didAdd(_ item: HistoryItem) {
        if deletedIDs.contains(item.id) {
            deleteFiles(for: item.id)
            return
        }
        items.insert(item, at: 0)
        prune()
    }

    func update(id: UUID, annotations: [Annotation], rendered: CGImage, scale: CGFloat) {
        // The item may still be pending its first write; fall back to what we know.
        let existing = item(withID: id)
        guard existing?.annotations != annotations || existing == nil else { return }

        let finalURL = finalURL(for: id)
        let thumbnailURL = thumbnailURL(for: id)
        let metaURL = metaURL(for: id)

        ioQueue.async { [weak self] in
            do {
                if annotations.isEmpty {
                    try? FileManager.default.removeItem(at: finalURL)
                } else {
                    try ImageFiles.writePNG(rendered, scale: scale, to: finalURL)
                }
                if let thumbnail = ImageFiles.thumbnail(of: rendered, maxPixelSize: 640) {
                    try ImageFiles.writePNG(thumbnail, scale: 1, to: thumbnailURL)
                }
            } catch {
                NSLog("Screenshotter: failed to update capture: \(error)")
            }
            DispatchQueue.main.async {
                guard let self, let index = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[index].annotations = annotations
                self.items[index].updatedAt = Date()
                let item = self.items[index]
                let meta = try? Self.encoder.encode(item)
                self.ioQueue.async { try? meta?.write(to: metaURL, options: .atomic) }
            }
        }
    }

    func delete(id: UUID) {
        deletedIDs.insert(id)
        items.removeAll { $0.id == id }
        deleteFiles(for: id)
    }

    func clearAll() {
        let ids = items.map(\.id)
        for id in ids { delete(id: id) }
    }

    private func deleteFiles(for id: UUID) {
        let folder = folder(for: id)
        ioQueue.async { try? FileManager.default.removeItem(at: folder) }
    }

    func prune() {
        let limit = max(AppSettings.shared.historyLimit, 1)
        guard items.count > limit else { return }
        for item in items[limit...] { delete(id: item.id) }
    }

    // MARK: Reading

    func loadImage(for item: HistoryItem, original: Bool) -> CGImage? {
        ImageFiles.loadImage(at: original ? originalURL(for: item.id) : imageURL(for: item))
    }

    func thumbnail(for item: HistoryItem) async -> NSImage? {
        let key = "\(item.id.uuidString)-\(item.updatedAt.timeIntervalSince1970)" as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        let thumbURL = thumbnailURL(for: item.id)
        let fallbackURL = imageURL(for: item)
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            if let image = NSImage(contentsOf: thumbURL) { return image }
            guard let full = ImageFiles.loadImage(at: fallbackURL),
                  let small = ImageFiles.thumbnail(of: full, maxPixelSize: 640) else { return nil }
            return NSImage(cgImage: small, size: NSSize(width: small.width, height: small.height))
        }.value
        if let image { thumbnailCache.setObject(image, forKey: key) }
        return image
    }

    /// Synchronous variant for menus; only touches the small thumbnail file.
    func cachedThumbnail(for item: HistoryItem) -> NSImage? {
        let key = "\(item.id.uuidString)-\(item.updatedAt.timeIntervalSince1970)" as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: thumbnailURL(for: item.id)) else { return nil }
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    // MARK: Actions

    func copyToClipboard(_ item: HistoryItem) {
        guard let image = loadImage(for: item, original: false) else { return }
        Clipboard.copy(image, scale: item.scale)
    }

    func revealInFinder(_ item: HistoryItem) {
        NSWorkspace.shared.activateFileViewerSelecting([imageURL(for: item)])
    }

    func export(_ item: HistoryItem) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ImageFiles.defaultFileName(for: item.createdAt)
        panel.directoryURL = AppSettings.shared.saveFolderURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try FileManager.default.copyItem(at: imageURL(for: item), to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: Loading

    private func load() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        items = folders
            .compactMap { folder in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")) else { return nil }
                return try? Self.decoder.decode(HistoryItem.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
