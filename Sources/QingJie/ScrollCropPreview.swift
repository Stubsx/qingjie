import AppKit
import SwiftUI

/// The crop stays in source pixels while the scrollable preview keeps its full length.
struct ScrollCropPreview: NSViewRepresentable {
    let image: NSImage
    let sourceSize: CGSize
    let height: Int
    let enabled: Bool
    let onChange: (Int) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> ScrollCropScrollView { ScrollCropScrollView() }
    func updateNSView(_ view: ScrollCropScrollView, context: Context) {
        view.crop.image = image; view.crop.sourceSize = sourceSize
        view.crop.retainedHeight = height; view.crop.enabled = enabled
        view.crop.onChange = onChange; view.crop.onCancel = onCancel
        view.needsLayout = true; view.crop.needsDisplay = true
    }
}

final class ScrollCropScrollView: NSScrollView {
    let crop = ScrollCropDocumentView()
    private var positioned = false

    init() {
        super.init(frame: .zero)
        borderType = .noBorder; drawsBackground = false
        hasVerticalScroller = true; hasHorizontalScroller = false
        autohidesScrollers = true; scrollerStyle = .overlay
        documentView = crop
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        let width = contentView.bounds.width
        guard width > 0, crop.sourceSize.width > 0 else { return }
        crop.frame.size = CGSize(width: width, height: max(contentView.bounds.height,
            crop.sourceSize.height * width / crop.sourceSize.width + ScrollCropDocumentView.padding * 2))
        if !positioned, contentView.bounds.height > 0 {
            contentView.scroll(to: CGPoint(x: 0, y: max(0, crop.cutY + ScrollCropDocumentView.padding - contentView.bounds.height)))
            reflectScrolledClipView(contentView); positioned = true
        }
    }
}

final class ScrollCropDocumentView: NSView {
    static let padding: CGFloat = 16
    var image: NSImage?
    var sourceSize = CGSize(width: 1, height: 1)
    var retainedHeight = 1 { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var enabled = true { didSet { if !enabled { stopDragging() } } }
    var onChange: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    private var dragging = false
    private var dragOffset: CGFloat = 0
    private var scrollTimer: Timer?
    var scale: CGFloat { bounds.width / max(1, sourceSize.width) }
    var cutY: CGFloat { Self.padding + CGFloat(retainedHeight) * scale }
    private var imageRect: CGRect {
        CGRect(x: 0, y: Self.padding, width: bounds.width, height: sourceSize.height * scale)
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true); setAccessibilityRole(.slider)
        setAccessibilityLabel("长图裁剪下边框")
        setAccessibilityHelp("向上拖动下边框，保留上方内容。")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSColor.black.withAlphaComponent(0.38).setFill()
        CGRect(x: 0, y: cutY, width: bounds.width, height: max(0, imageRect.maxY - cutY)).fill()
        let green = NSColor(calibratedRed: 0.10, green: 0.40, blue: 0.32, alpha: 1)
        green.setStroke()
        let outline = NSBezierPath(rect: CGRect(x: 1, y: Self.padding, width: max(0, bounds.width - 2), height: max(1, cutY - Self.padding)))
        outline.lineWidth = 1; outline.stroke()
        let edge = NSBezierPath(); edge.move(to: CGPoint(x: 0, y: cutY)); edge.line(to: CGPoint(x: bounds.width, y: cutY))
        edge.lineWidth = 2; edge.stroke()
        green.setFill()
        NSBezierPath(roundedRect: CGRect(x: bounds.midX - 28, y: cutY - 7, width: 56, height: 14), xRadius: 7, yRadius: 7).fill()
        NSColor.white.setFill()
        CGRect(x: bounds.midX - 12, y: cutY - 2, width: 24, height: 1).fill()
        CGRect(x: bounds.midX - 12, y: cutY + 1, width: 24, height: 1).fill()
    }

    override func resetCursorRects() {
        if enabled { addCursorRect(CGRect(x: 0, y: cutY - 14, width: bounds.width, height: 28), cursor: .resizeUpDown) }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard enabled, abs(point.y - cutY) <= 14 else { return }
        window?.makeFirstResponder(self); dragging = true; dragOffset = point.y - cutY
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.continueScrolling() }
        scrollTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        moveBottom(to: convert(event.locationInWindow, from: nil).y - dragOffset)
    }
    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        moveBottom(to: convert(event.locationInWindow, from: nil).y - dragOffset); stopDragging()
    }
    func moveBottom(to y: CGFloat) {
        guard enabled, y.isFinite, scale > 0 else { return }
        let row = min(sourceSize.height, max(1, ((y - Self.padding) / scale).rounded()))
        retainedHeight = Int(row); onChange?(retainedHeight)
    }
    private func continueScrolling() {
        guard dragging, let window, let scroll = enclosingScrollView else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let clip = scroll.contentView, visible = clip.bounds
        let distance: CGFloat
        if point.y < visible.minY + 24 { distance = -min(24, max(2, (visible.minY + 24 - point.y) / 3)) }
        else if point.y > visible.maxY - 24 { distance = min(24, max(2, (point.y - visible.maxY + 24) / 3)) }
        else { return }
        let y = min(max(0, bounds.height - visible.height), max(0, visible.minY + distance))
        guard y != visible.minY else { return }
        clip.scroll(to: CGPoint(x: 0, y: y)); scroll.reflectScrolledClipView(clip)
        moveBottom(to: convert(window.mouseLocationOutsideOfEventStream, from: nil).y - dragOffset)
    }
    private func stopDragging() { dragging = false; scrollTimer?.invalidate(); scrollTimer = nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { stopDragging() } }
    override func accessibilityValue() -> Any? { "保留 \(retainedHeight) 像素" }
    override func accessibilityPerformIncrement() -> Bool {
        guard enabled else { return false }; moveBottom(to: cutY + scale); return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard enabled else { return false }; moveBottom(to: cutY - scale); return true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        if event.keyCode == 126 { _ = accessibilityPerformDecrement(); return }
        if event.keyCode == 125 { _ = accessibilityPerformIncrement(); return }
        super.keyDown(with: event)
    }
}
