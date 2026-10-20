import AppKit

enum AnnotationTool: String, CaseIterable, Identifiable, Codable {
    case select, arrow, line, rectangle, ellipse, pen, highlighter, text, pixelate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .text: "Text"
        case .pixelate: "Pixelate"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .pen: "scribble.variable"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .pixelate: "checkerboard.rectangle"
        }
    }

    var shortcut: Character {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .line: "l"
        case .rectangle: "r"
        case .ellipse: "o"
        case .pen: "p"
        case .highlighter: "h"
        case .text: "t"
        case .pixelate: "b"
        }
    }

    static func forShortcut(_ character: Character) -> AnnotationTool? {
        allCases.first { $0.shortcut == character }
    }

    var isFreehand: Bool { self == .pen || self == .highlighter }
    var isBoxShaped: Bool { self == .rectangle || self == .ellipse || self == .pixelate }
}

struct RGBAColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .systemRed
        self.init(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: c.alphaComponent)
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    static let red = RGBAColor(red: 1.0, green: 0.23, blue: 0.19)
    static let orange = RGBAColor(red: 1.0, green: 0.58, blue: 0.0)
    static let yellow = RGBAColor(red: 1.0, green: 0.84, blue: 0.0)
    static let green = RGBAColor(red: 0.20, green: 0.78, blue: 0.35)
    static let blue = RGBAColor(red: 0.0, green: 0.48, blue: 1.0)
    static let purple = RGBAColor(red: 0.69, green: 0.32, blue: 0.87)
    static let pink = RGBAColor(red: 1.0, green: 0.18, blue: 0.57)
    static let black = RGBAColor(red: 0.08, green: 0.08, blue: 0.08)
    static let white = RGBAColor(red: 1, green: 1, blue: 1)

    static let palette: [RGBAColor] = [.red, .orange, .yellow, .green, .blue, .purple, .pink, .black, .white]
}

enum StrokeSize: Int, CaseIterable, Codable, Identifiable {
    case small, medium, large

    var id: Int { rawValue }
    var title: String { ["Small", "Medium", "Large"][rawValue] }
    var lineWidth: CGFloat { [2, 4, 7][rawValue] }
    var fontSize: CGFloat { [16, 24, 36][rawValue] }
}

/// One mark on the screenshot. Geometry is in image points with a top-left origin.
struct Annotation: Identifiable, Codable, Equatable {
    var id = UUID()
    var tool: AnnotationTool
    var color: RGBAColor
    var size: StrokeSize
    /// Multiplier so marks stay visible on very large captures (which get viewed scaled down).
    var scaleFactor: CGFloat = 1
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var text: String = ""

    var lineWidth: CGFloat { size.lineWidth * scaleFactor }
    var fontSize: CGFloat { size.fontSize * scaleFactor }

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var font: NSFont { NSFont.systemFont(ofSize: fontSize, weight: .semibold) }

    var textAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color.nsColor]
    }

    var textSize: CGSize {
        let measured = NSAttributedString(string: text.isEmpty ? " " : text, attributes: textAttributes)
            .boundingRect(with: CGSize(width: 100_000, height: 100_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(measured.width), height: ceil(measured.height))
    }

    /// Area covered by the annotation, used for selection outlines.
    var bounds: CGRect {
        switch tool {
        case .text:
            return CGRect(origin: start, size: textSize)
        case .pen, .highlighter:
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
            let pad = renderedLineWidth / 2
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -pad, dy: -pad)
        default:
            return rect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        }
    }

    var renderedLineWidth: CGFloat {
        tool == .highlighter ? max(lineWidth * 4, 14 * scaleFactor) : lineWidth
    }

    /// Whether a just-drawn annotation is big enough to keep.
    var isMeaningful: Bool {
        switch tool {
        case .pen, .highlighter: return points.count > 1
        case .arrow, .line: return hypot(end.x - start.x, end.y - start.y) > 4
        case .text: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return rect.width > 3 && rect.height > 3
        }
    }

    mutating func offset(by delta: CGVector) {
        start = CGPoint(x: start.x + delta.dx, y: start.y + delta.dy)
        end = CGPoint(x: end.x + delta.dx, y: end.y + delta.dy)
        points = points.map { CGPoint(x: $0.x + delta.dx, y: $0.y + delta.dy) }
    }

    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        let t = tolerance + renderedLineWidth / 2
        switch tool {
        case .arrow, .line:
            return distance(from: p, toSegment: start, end) <= t
        case .pen, .highlighter:
            guard points.count > 1 else { return points.first.map { hypot($0.x - p.x, $0.y - p.y) <= t } ?? false }
            return zip(points, points.dropFirst()).contains { distance(from: p, toSegment: $0, $1) <= t }
        case .rectangle:
            let r = rect
            let outer = r.insetBy(dx: -t, dy: -t)
            let inner = r.insetBy(dx: t, dy: t)
            return outer.contains(p) && (inner.isEmpty || !inner.contains(p))
        case .ellipse:
            return isInsideEllipse(p, rect.insetBy(dx: -t, dy: -t))
                && !isInsideEllipse(p, rect.insetBy(dx: t, dy: t))
        case .text, .pixelate:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        case .select:
            return false
        }
    }

    private func isInsideEllipse(_ p: CGPoint, _ r: CGRect) -> Bool {
        guard r.width > 0, r.height > 0 else { return false }
        let nx = (p.x - r.midX) / (r.width / 2)
        let ny = (p.y - r.midY) / (r.height / 2)
        return nx * nx + ny * ny <= 1
    }
}

func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}
