import AppKit
import Combine

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var hotKey: KeyCombo { didSet { store(hotKey, forKey: Keys.hotKey) } }
    @Published var openEditorAfterCapture: Bool { didSet { defaults.set(openEditorAfterCapture, forKey: Keys.openEditor) } }
    @Published var copyToClipboard: Bool { didSet { defaults.set(copyToClipboard, forKey: Keys.copyToClipboard) } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: Keys.playSound) } }
    @Published var saveToFolder: Bool { didSet { defaults.set(saveToFolder, forKey: Keys.saveToFolder) } }
    @Published var saveFolderPath: String { didSet { defaults.set(saveFolderPath, forKey: Keys.saveFolderPath) } }
    @Published var historyLimit: Int { didSet { defaults.set(historyLimit, forKey: Keys.historyLimit) } }

    // Remembered editor style, so the next screenshot starts with the last-used tool and colors.
    @Published var lastTool: AnnotationTool { didSet { defaults.set(lastTool.rawValue, forKey: Keys.lastTool) } }
    @Published var lastColor: RGBAColor { didSet { store(lastColor, forKey: Keys.lastColor) } }
    @Published var lastSize: StrokeSize { didSet { defaults.set(lastSize.rawValue, forKey: Keys.lastSize) } }

    /// True while the settings window is recording a new shortcut; the global hotkey is suspended meanwhile.
    @Published var isRecordingHotKey = false

    var saveFolderURL: URL { URL(fileURLWithPath: (saveFolderPath as NSString).expandingTildeInPath, isDirectory: true) }

    private init() {
        defaults.register(defaults: [
            Keys.openEditor: true,
            Keys.copyToClipboard: true,
            Keys.playSound: true,
            Keys.saveToFolder: false,
            Keys.saveFolderPath: "~/Desktop",
            Keys.historyLimit: 200,
        ])
        hotKey = Self.load(KeyCombo.self, forKey: Keys.hotKey, from: defaults) ?? .default
        openEditorAfterCapture = defaults.bool(forKey: Keys.openEditor)
        copyToClipboard = defaults.bool(forKey: Keys.copyToClipboard)
        playSound = defaults.bool(forKey: Keys.playSound)
        saveToFolder = defaults.bool(forKey: Keys.saveToFolder)
        saveFolderPath = defaults.string(forKey: Keys.saveFolderPath) ?? "~/Desktop"
        historyLimit = defaults.integer(forKey: Keys.historyLimit)
        lastTool = defaults.string(forKey: Keys.lastTool).flatMap(AnnotationTool.init(rawValue:)) ?? .arrow
        lastColor = Self.load(RGBAColor.self, forKey: Keys.lastColor, from: defaults) ?? .red
        lastSize = StrokeSize(rawValue: defaults.integer(forKey: Keys.lastSize)) ?? .medium
    }

    private func store<T: Encodable>(_ value: T, forKey key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, forKey key: String, from defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private enum Keys {
        static let hotKey = "hotKey"
        static let openEditor = "openEditorAfterCapture"
        static let copyToClipboard = "copyToClipboard"
        static let playSound = "playSound"
        static let saveToFolder = "saveToFolder"
        static let saveFolderPath = "saveFolderPath"
        static let historyLimit = "historyLimit"
        static let lastTool = "lastTool"
        static let lastColor = "lastColor"
        static let lastSize = "lastSize"
    }
}
