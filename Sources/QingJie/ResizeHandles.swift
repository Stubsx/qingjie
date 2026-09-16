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

extension RectResizeHandle {
    func cursor(dragging: Bool) -> NSCursor {
        switch self {
        case .corner(let corner): return corner.cursor
        case .edge: return dragging ? .closedHand : .openHand
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

/// The corners resize the capture, the narrow border band moves it; its interior remains a canvas.
final class CaptureResizeHandles: NSView {
    var selection: CGRect = .zero { didSet { if selection != oldValue { needsDisplay = true } } }
    var enabled = true
    var onBegin: ((RectResizeHandle) -> Void)?
    var onDrag: ((CGPoint, Bool) -> Void)?
    var onEnd: (() -> Void)?
    var onCursorUpdate: ((NSEvent) -> Void)?
    private var activeHandle: RectResizeHandle?
    var dragging: Bool { activeHandle != nil }
    private var dragOffset: CGPoint = .zero
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return handle(at: local) == nil ? nil : self
    }
    private func handle(at point: CGPoint) -> RectResizeHandle? {
        guard enabled, bounds.contains(point) else { return nil }
        return InteractionGeometry.resizeHandle(at: point, rect: selection)
    }
    func cursor(at point: CGPoint) -> NSCursor? {
        // Hover and mouse-down share the same geometry, including corner priority.
        (activeHandle ?? handle(at: point))?.cursor(dragging: dragging)
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
        guard let handle = handle(at: point) else { return }
        // Anchor corners to themselves; edges carry the whole rect, so track the pointer from its origin.
        let anchor: CGPoint
        switch handle {
        case .corner(let corner): anchor = corner.point(in: selection); corner.cursor.set()
        case .edge: anchor = selection.origin; NSCursor.closedHand.set()
        }
        // Preserve where the pointer grabbed the hit band, avoiding a jump on click.
        dragOffset = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y)
        activeHandle = handle; onBegin?(handle)
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        onDrag?(CGPoint(x: point.x - dragOffset.x, y: point.y - dragOffset.y), event.modifierFlags.contains(.shift))
        activeHandle?.cursor(dragging: true).set()
    }
    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        mouseDragged(with: event); activeHandle = nil; onEnd?()
        // 松手后立即恢复悬停光标，不等下一次移动。
        onCursorUpdate?(event)
    }
    func stopDragging() { activeHandle = nil }
}
