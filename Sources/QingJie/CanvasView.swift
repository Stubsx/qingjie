import AppKit
import SwiftUI
import QingJieCore

struct EditorCanvas: NSViewRepresentable {
    @ObservedObject var model: EditorModel
    func makeNSView(context: Context) -> CanvasScrollView { CanvasScrollView(model: model) }
    func updateNSView(_ view: CanvasScrollView, context: Context) { view.refresh() }
}

final class CanvasScrollView: NSScrollView {
    let canvas: AnnotationCanvas
    private var lastMode: CanvasMode?
    private var lastImageSize: CGSize = .zero
    init(model: EditorModel) {
        canvas = AnnotationCanvas(model: model)
        super.init(frame: .zero)
        drawsBackground = false; hasVerticalScroller = true; hasHorizontalScroller = true
        autohidesScrollers = true; borderType = .noBorder; documentView = canvas
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    override func layout() {
        super.layout()
        let size = canvas.model.imageSize, viewport = contentSize
        guard viewport.width > 64, viewport.height > 64 else { return }
        let scale: CGFloat
        switch canvas.model.canvasMode {
        case .fit: scale = min((viewport.width - 64) / size.width, (viewport.height - 64) / size.height, 1)
        case .width: scale = min((viewport.width - 64) / size.width, 1)
        case .actual: scale = 1 / max(1, window?.backingScaleFactor ?? 1)
        }
        canvas.displayScale = max(0.001, scale)
        let documentSize = CGSize(width: max(viewport.width, size.width * scale + 64), height: max(viewport.height, size.height * scale + 64))
        if canvas.frame.size != documentSize { canvas.setFrameSize(documentSize) }
        canvas.needsDisplay = true
    }
    func refresh() {
        let reset = lastMode != canvas.model.canvasMode || lastImageSize != canvas.model.imageSize
        lastMode = canvas.model.canvasMode; lastImageSize = canvas.model.imageSize
        needsLayout = true; layoutSubtreeIfNeeded(); canvas.needsDisplay = true
        if reset { contentView.scroll(to: .zero); reflectScrolledClipView(contentView) }
        if !canvas.isInteracting { window?.invalidateCursorRects(for: canvas) }
    }
}

final class AnnotationCanvas: NSView {
    let model: EditorModel
    var drawsBackdrop = true
    var onTextRequested: ((CGPoint) -> Void)?
    var onInteractionBegan: (() -> Void)?
    var draft: Mark?
    var dragOrigin: CGPoint?
    var moveSnapshot: EditorSnapshot?
    var originalMark: Mark?
    private var resizeCorner: RectCorner?
    private var tracking: NSTrackingArea?
    var isInteracting: Bool { draft != nil || originalMark != nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var displayScale: CGFloat = 1
    var imageFrame: CGRect {
        let size = CGSize(width: model.imageSize.width * displayScale, height: model.imageSize.height * displayScale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    init(model: EditorModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    override func resetCursorRects() { addCursorRect(bounds, cursor: model.tool == .select ? .arrow : .crosshair) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .cursorUpdate], owner: self)
        addTrackingArea(area); tracking = area
    }
    private func mark(at point: CGPoint) -> Mark? { model.marks.last { $0.contains(point, tolerance: 5 / displayScale) } }
    private func handle(at point: CGPoint) -> RectCorner? {
        guard let selected = model.marks.first(where: { $0.id == model.selectedID }),
              [.rectangle, .ellipse, .mosaic].contains(selected.tool) else { return nil }
        return InteractionGeometry.corner(at: point, rect: selected.rect, radius: 7 / displayScale)
    }
    override func mouseMoved(with event: NSEvent) {
        guard !isInteracting else { return }
        let local = convert(event.locationInWindow, from: nil)
        let point = CaptureGeometry.imagePoint(local, displayedIn: imageFrame, imageSize: model.imageSize)
        if imageFrame.contains(local), let corner = handle(at: point) { corner.cursor.set() }
        else if imageFrame.contains(local), mark(at: point) != nil { NSCursor.openHand.set() }
        else { (model.tool == .select ? NSCursor.arrow : .crosshair).set() }
    }
    override func cursorUpdate(with event: NSEvent) { mouseMoved(with: event) }
    override func draw(_ dirtyRect: NSRect) {
        if drawsBackdrop { NSColor(calibratedWhite: 0.925, alpha: 1).setFill(); bounds.fill() }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // A quiet checkerboard makes image boundaries and transparency visible.
        let frame = imageFrame
        context.saveGState()
        if drawsBackdrop { context.setShadow(offset: CGSize(width: 0, height: 3), blur: 18, color: NSColor.black.withAlphaComponent(0.12).cgColor) }
        context.setFillColor(NSColor.white.cgColor); context.fill(frame); context.restoreGState()
        context.saveGState(); context.clip(to: frame)
        context.setFillColor(NSColor(calibratedWhite: 0.96, alpha: 1).cgColor)
        let visible = dirtyRect.intersection(frame)
        for y in stride(from: frame.minY + max(0, floor((visible.minY - frame.minY) / 12)) * 12, to: min(frame.maxY, visible.maxY), by: 12) {
            for x in stride(from: frame.minX + max(0, floor((visible.minX - frame.minX) / 12)) * 12, to: min(frame.maxX, visible.maxX), by: 12) {
                if (Int((x - frame.minX) / 12) + Int((y - frame.minY) / 12)) % 2 == 0 { context.fill(CGRect(x: x, y: y, width: 12, height: 12)) }
            }
        }
        context.translateBy(x: frame.minX, y: frame.minY)
        let scale = frame.width / model.imageSize.width; context.scaleBy(x: scale, y: scale)
        Raster.draw(model.image, in: CGRect(origin: .zero, size: model.imageSize), context: context)
        for mark in model.marks { Raster.draw(mark: mark, base: model.image, context: context) }
        if let draft {
            if draft.tool == .crop {
                context.setFillColor(NSColor.black.withAlphaComponent(0.30).cgColor)
                let path = CGMutablePath(); path.addRect(CGRect(origin: .zero, size: model.imageSize)); path.addRect(draft.rect)
                context.addPath(path); context.fillPath(using: .evenOdd)
                context.setStrokeColor(NSColor.white.cgColor); context.setLineWidth(2 / scale); context.stroke(draft.rect)
            } else { Raster.draw(mark: draft, base: model.image, context: context) }
        }
        if let mark = model.marks.first(where: { $0.id == model.selectedID }) {
            context.setStrokeColor(NSColor.systemTeal.cgColor); context.setLineWidth(1.5 / scale)
            context.setLineDash(phase: 0, lengths: [5 / scale, 3 / scale]); context.stroke(mark.extent.insetBy(dx: -5 / scale, dy: -5 / scale))
            context.setLineDash(phase: 0, lengths: [])
            if [.rectangle, .ellipse, .mosaic].contains(mark.tool) {
                for corner in RectCorner.allCases {
                    let point = corner.point(in: mark.rect)
                    let handle = CGRect(x: point.x - 4 / scale, y: point.y - 4 / scale, width: 8 / scale, height: 8 / scale)
                    context.setFillColor(NSColor.white.cgColor); context.fill(handle); context.stroke(handle)
                }
            }
        }
        context.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        guard !model.isSamplingColor else { return }
        onInteractionBegan?()
        window?.makeFirstResponder(self)
        let local = convert(event.locationInWindow, from: nil)
        guard imageFrame.contains(local) else { model.selectedID = nil; return }
        let point = CaptureGeometry.imagePoint(local, displayedIn: imageFrame, imageSize: model.imageSize)
        dragOrigin = point
        if let corner = handle(at: point), let selected = model.marks.first(where: { $0.id == model.selectedID }) {
            originalMark = selected; moveSnapshot = model.snapshot; resizeCorner = corner; corner.cursor.set()
        } else if let hit = mark(at: point) {
            model.selectedID = hit.id; originalMark = hit; moveSnapshot = model.snapshot
            NSCursor.closedHand.set()
        } else if model.tool == .select {
            model.selectedID = nil
        } else if model.tool == .text {
            if let onTextRequested { onTextRequested(point) }
            else { model.textPoint = point; model.textInput = ""; model.showingText = true }
        } else {
            model.selectedID = nil
            draft = Mark(tool: model.tool, start: point, end: point, points: [point], color: model.color, width: model.lineWidth, fontSize: model.fontSize, mosaicStyle: model.mosaicStyle)
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        let point = CaptureGeometry.imagePoint(convert(event.locationInWindow, from: nil), displayedIn: imageFrame, imageSize: model.imageSize)
        if let origin = dragOrigin, var mark = originalMark,
           let index = model.marks.firstIndex(where: { $0.id == mark.id }) {
            if let resizeCorner {
                let rect = InteractionGeometry.resize(mark.rect, corner: resizeCorner, to: point,
                                                       bounds: CGRect(origin: .zero, size: model.imageSize),
                                                       square: event.modifierFlags.contains(.shift))
                mark.start = rect.origin; mark.end = CGPoint(x: rect.maxX, y: rect.maxY)
            } else { mark.translate(x: point.x - origin.x, y: point.y - origin.y); NSCursor.closedHand.set() }
            model.marks[index] = mark
        } else if var current = draft {
            if event.modifierFlags.contains(.shift), [.rectangle, .ellipse].contains(current.tool) {
                let dx = point.x - current.start.x, dy = point.y - current.start.y
                let length = min(abs(dx), abs(dy))
                current.end = CGPoint(x: current.start.x + (dx >= 0 ? length : -length), y: current.start.y + (dy >= 0 ? length : -length))
            } else { current.end = point }
            current.points.append(point); draft = current
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if isInteracting { mouseDragged(with: event) }
        if let draft {
            if draft.tool == .crop { model.crop(draft.rect) }
            else if draft.tool == .pen || hypot(draft.end.x - draft.start.x, draft.end.y - draft.start.y) > 3 { model.add(draft) }
        } else if let before = moveSnapshot, let original = originalMark,
                  let after = model.marks.first(where: { $0.id == original.id }),
                  after.start != original.start || after.end != original.end || after.points != original.points {
            model.checkpoint(before)
        }
        draft = nil; dragOrigin = nil; moveSnapshot = nil; originalMark = nil; resizeCorner = nil; needsDisplay = true
        window?.invalidateCursorRects(for: self); mouseMoved(with: event)
    }
    @discardableResult func cancelInteraction() -> Bool {
        guard isInteracting else { return false }
        if let moveSnapshot { model.restore(moveSnapshot) }
        draft = nil; dragOrigin = nil; moveSnapshot = nil; originalMark = nil; resizeCorner = nil; needsDisplay = true
        return true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { model.deleteSelected() }
        else if event.keyCode == 53 { cancelInteraction(); model.selectedID = nil; needsDisplay = true }
        else { super.keyDown(with: event) }
    }
}
