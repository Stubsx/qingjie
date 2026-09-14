import AppKit
import QingJieCore

extension RectCorner {
    var cursor: NSCursor {
        switch self {
        case .topLeft, .bottomRight: return ResizeCursors.downward
        case .topRight, .bottomLeft: return ResizeCursors.upward
        }
    }
}

private enum ResizeCursors {
    static let downward = make(flipped: false)
    static let upward = make(flipped: true)
    private static func make(flipped: Bool) -> NSCursor {
        let image = NSImage(size: CGSize(width: 24, height: 24), flipped: false) { _ in
            let path = NSBezierPath()
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: flipped ? 24 - y : y) }
            path.move(to: point(5, 19)); path.line(to: point(19, 5))
            path.move(to: point(5, 12)); path.line(to: point(5, 19)); path.line(to: point(12, 19))
            path.move(to: point(12, 5)); path.line(to: point(19, 5)); path.line(to: point(19, 12))
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            NSColor.white.setStroke(); path.lineWidth = 4; path.stroke()
            NSColor.black.setStroke(); path.lineWidth = 2; path.stroke(); return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: 12, y: 12))
    }
}

/// The corners and a narrow border band resize the capture; its interior remains a canvas.
final class CaptureResizeHandles: NSView {
    var selection: CGRect = .zero { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var enabled = true { didSet { if enabled != oldValue { window?.invalidateCursorRects(for: self) } } }
    var onBegin: ((RectResizeHandle) -> Void)?
    var onDrag: ((CGPoint, Bool) -> Void)?
    var onEnd: (() -> Void)?
    private(set) var dragging = false
    private var dragOffset: CGPoint = .zero
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard enabled else { return nil }
        let local = convert(point, from: superview)
        return InteractionGeometry.resizeHandle(at: local, rect: selection) == nil ? nil : self
    }
    override func resetCursorRects() {
        guard enabled else { return }
        if selection.width > 18 {
            for y in [selection.minY, selection.maxY] {
                addCursorRect(CGRect(x: selection.minX + 9, y: y - 6, width: selection.width - 18, height: 12).intersection(bounds), cursor: .resizeUpDown)
            }
        }
        if selection.height > 18 {
            for x in [selection.minX, selection.maxX] {
                addCursorRect(CGRect(x: x - 6, y: selection.minY + 9, width: 12, height: selection.height - 18).intersection(bounds), cursor: .resizeLeftRight)
            }
        }
        for corner in RectCorner.allCases {
            let point = corner.point(in: selection)
            addCursorRect(CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18).intersection(bounds), cursor: corner.cursor)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        for corner in RectCorner.allCases {
            let point = corner.point(in: selection)
            let box = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            NSColor.white.setFill(); box.fill()
            NSColor(calibratedRed: 0.28, green: 0.60, blue: 0.39, alpha: 1).setStroke()
            let path = NSBezierPath(rect: box); path.lineWidth = 1.5; path.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard enabled, let handle = InteractionGeometry.resizeHandle(at: point, rect: selection) else { return }
        let anchor: CGPoint
        switch handle {
        case .corner(let corner): anchor = corner.point(in: selection)
        case .edge(.top): anchor = CGPoint(x: point.x, y: selection.minY)
        case .edge(.bottom): anchor = CGPoint(x: point.x, y: selection.maxY)
        case .edge(.left): anchor = CGPoint(x: selection.minX, y: point.y)
        case .edge(.right): anchor = CGPoint(x: selection.maxX, y: point.y)
        }
        // Preserve where the pointer grabbed the hit band, avoiding a jump on click.
        dragOffset = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y)
        dragging = true; onBegin?(handle)
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        onDrag?(CGPoint(x: point.x - dragOffset.x, y: point.y - dragOffset.y), event.modifierFlags.contains(.shift))
    }
    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        mouseDragged(with: event); dragging = false; onEnd?()
    }
    func stopDragging() { dragging = false }
}
