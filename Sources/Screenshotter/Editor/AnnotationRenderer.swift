import AppKit

/// Draws annotations into the current (flipped) NSGraphicsContext, in image-point coordinates.
/// Used both by the editor canvas and by the final export so they always look identical.
enum AnnotationRenderer {
    struct Context {
        /// Pixelated copy of the whole screenshot, drawn through the pixelate annotation's rect.
        var pixelated: NSImage?
        var imageBounds: CGRect
        /// Shadows ignore the CTM, so they must be scaled to device space by hand.
        var shadowScale: CGFloat
    }

    static func draw(_ a: Annotation, in context: Context) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let color = a.color.nsColor
        switch a.tool {
        case .arrow:
            applyShadow(context)
            color.setFill()
            arrowPath(from: a.start, to: a.end, lineWidth: a.lineWidth).fill()

        case .line:
            applyShadow(context)
            color.setStroke()
            let path = NSBezierPath()
            path.move(to: a.start)
            path.line(to: a.end)
            path.lineWidth = a.lineWidth
            path.lineCapStyle = .round
            path.stroke()

        case .rectangle:
            applyShadow(context)
            color.setStroke()
            let radius = min(a.lineWidth * 0.75, min(a.rect.width, a.rect.height) / 4)
            let path = NSBezierPath(roundedRect: a.rect, xRadius: radius, yRadius: radius)
            path.lineWidth = a.lineWidth
            path.lineJoinStyle = .round
            path.stroke()

        case .ellipse:
            applyShadow(context)
            color.setStroke()
            let path = NSBezierPath(ovalIn: a.rect)
            path.lineWidth = a.lineWidth
            path.stroke()

        case .pen:
            applyShadow(context)
            color.setStroke()
            let path = smoothPath(through: a.points)
            path.lineWidth = a.lineWidth
            path.stroke()

        case .highlighter:
            color.withAlphaComponent(0.4).setStroke()
            let path = smoothPath(through: a.points)
            path.lineWidth = a.renderedLineWidth
            path.lineCapStyle = .square
            path.stroke()

        case .text:
            applyShadow(context)
            let string = NSAttributedString(string: a.text, attributes: a.textAttributes)
            string.draw(with: CGRect(origin: a.start, size: a.textSize), options: [.usesLineFragmentOrigin, .usesFontLeading])

        case .pixelate:
            NSBezierPath(rect: a.rect).addClip()
            if let pixelated = context.pixelated {
                pixelated.draw(in: context.imageBounds, from: .zero, operation: .copy, fraction: 1,
                               respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
            } else {
                NSColor.gray.setFill()
                a.rect.fill()
            }

        case .select:
            break
        }
    }

    private static func applyShadow(_ context: Context) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 3 * context.shadowScale
        shadow.shadowOffset = NSSize(width: 0, height: -1 * context.shadowScale)
        shadow.set()
    }

    /// A tapered arrow (thin tail, full-width shaft near a sharp head), drawn as a single filled shape.
    static func arrowPath(from start: CGPoint, to end: CGPoint, lineWidth: CGFloat) -> NSBezierPath {
        let length = hypot(end.x - start.x, end.y - start.y)
        let path = NSBezierPath()
        guard length > 0.5 else { return path }

        let headLength = min(max(lineWidth * 3.6, 12), length * 0.6)
        let headHalfWidth = max(headLength * 0.62, lineWidth)
        let shaftHalfWidth = lineWidth / 2
        let tailHalfWidth = lineWidth * 0.2
        let neck = length - headLength * 0.85

        // Outline in a local frame where the arrow points along +x, then rotate into place.
        let local: [CGPoint] = [
            CGPoint(x: 0, y: -tailHalfWidth),
            CGPoint(x: neck, y: -shaftHalfWidth),
            CGPoint(x: length - headLength, y: -headHalfWidth),
            CGPoint(x: length, y: 0),
            CGPoint(x: length - headLength, y: headHalfWidth),
            CGPoint(x: neck, y: shaftHalfWidth),
            CGPoint(x: 0, y: tailHalfWidth),
        ]
        let angle = atan2(end.y - start.y, end.x - start.x)
        let cosA = cos(angle), sinA = sin(angle)
        let transformed = local.map { p in
            CGPoint(x: start.x + p.x * cosA - p.y * sinA, y: start.y + p.x * sinA + p.y * cosA)
        }
        path.move(to: transformed[0])
        for p in transformed.dropFirst() { path.line(to: p) }
        path.close()
        path.lineJoinStyle = .round
        return path
    }

    /// Quadratic smoothing through midpoints, so freehand strokes don't look jagged.
    static func smoothPath(through points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            if points.count == 2 { path.line(to: points[1]) } else { path.line(to: first) }
            return path
        }
        for i in 1..<points.count - 1 {
            let control = points[i]
            let next = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            let current = path.currentPoint
            // NSBezierPath only has cubic curves; convert the quadratic segment.
            path.curve(
                to: next,
                controlPoint1: CGPoint(x: current.x + 2 / 3 * (control.x - current.x), y: current.y + 2 / 3 * (control.y - current.y)),
                controlPoint2: CGPoint(x: next.x + 2 / 3 * (control.x - next.x), y: next.y + 2 / 3 * (control.y - next.y))
            )
        }
        path.line(to: points[points.count - 1])
        return path
    }
}
