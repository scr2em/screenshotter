// Draws the app icon and writes an .icns file.
// Usage: swift Scripts/make_icon.swift Resources/AppIcon.icns
import AppKit

let outputPath = CommandLine.arguments.dropFirst().first ?? "AppIcon.icns"

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Squircle-ish background following the macOS icon grid (824pt body inside 1024).
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSColor.black.setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [
        NSColor(srgbRed: 0.36, green: 0.42, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 0.22, green: 0.16, blue: 0.78, alpha: 1),
    ])!.draw(in: bodyPath, angle: -90)

    // Viewfinder corners.
    let frame = body.insetBy(dx: 150 * s, dy: 150 * s)
    let corner = 120 * s
    let brackets = NSBezierPath()
    for (x, y, dx, dy) in [
        (frame.minX, frame.minY, 1.0, 1.0), (frame.maxX, frame.minY, -1.0, 1.0),
        (frame.minX, frame.maxY, 1.0, -1.0), (frame.maxX, frame.maxY, -1.0, -1.0),
    ] {
        brackets.move(to: CGPoint(x: x, y: y + dy * corner))
        brackets.line(to: CGPoint(x: x, y: y))
        brackets.line(to: CGPoint(x: x + dx * corner, y: y))
    }
    brackets.lineWidth = 44 * s
    brackets.lineCapStyle = .round
    brackets.lineJoinStyle = .round
    NSColor.white.setStroke()
    brackets.stroke()

    // Annotation arrow.
    let start = CGPoint(x: frame.minX + 120 * s, y: frame.minY + 120 * s)
    let end = CGPoint(x: frame.maxX - 110 * s, y: frame.maxY - 110 * s)
    let length = hypot(end.x - start.x, end.y - start.y)
    let headLength = 190 * s, headHalf = 120 * s, shaftHalf = 30 * s, tailHalf = 10 * s
    let neck = length - headLength * 0.85
    let local = [
        CGPoint(x: 0, y: -tailHalf), CGPoint(x: neck, y: -shaftHalf), CGPoint(x: length - headLength, y: -headHalf),
        CGPoint(x: length, y: 0), CGPoint(x: length - headLength, y: headHalf), CGPoint(x: neck, y: shaftHalf),
        CGPoint(x: 0, y: tailHalf),
    ]
    let angle = atan2(end.y - start.y, end.x - start.x)
    let arrow = NSBezierPath()
    for (i, p) in local.enumerated() {
        let q = CGPoint(x: start.x + p.x * cos(angle) - p.y * sin(angle), y: start.y + p.x * sin(angle) + p.y * cos(angle))
        if i == 0 { arrow.move(to: q) } else { arrow.line(to: q) }
    }
    arrow.close()
    arrow.lineJoinStyle = .round
    NSGraphicsContext.saveGraphicsState()
    let arrowShadow = NSShadow()
    arrowShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    arrowShadow.shadowBlurRadius = 18 * s
    arrowShadow.shadowOffset = NSSize(width: 0, height: -6 * s)
    arrowShadow.set()
    NSColor(srgbRed: 1.0, green: 0.27, blue: 0.27, alpha: 1).setFill()
    arrow.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let rep = drawIcon(size: CGFloat(base * scale))
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", outputPath]
try process.run()
process.waitUntilExit()
try? fm.removeItem(at: iconset)
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(outputPath)")
