import AppKit
let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let s = CGFloat(pixels)
        NSColor(calibratedRed: 0.08, green: 0.32, blue: 0.28, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: s * 0.04, y: s * 0.04, width: s * 0.92, height: s * 0.92), xRadius: s * 0.21, yRadius: s * 0.21).fill()
        NSColor(calibratedRed: 0.79, green: 0.96, blue: 0.62, alpha: 1).setStroke()
        let path = NSBezierPath(); path.lineWidth = s * 0.07; path.lineCapStyle = .round; path.lineJoinStyle = .round
        let lo = s * 0.28, hi = s * 0.72, arm = s * 0.14
        for (x, y, dx, dy) in [(lo,lo,arm,arm),(hi,lo,-arm,arm),(lo,hi,arm,-arm),(hi,hi,-arm,-arm)] {
            path.move(to: NSPoint(x: x, y: y + dy)); path.line(to: NSPoint(x: x, y: y)); path.line(to: NSPoint(x: x + dx, y: y))
        }
        path.stroke()
        NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: s * 0.445, y: s * 0.445, width: s * 0.11, height: s * 0.11)).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
