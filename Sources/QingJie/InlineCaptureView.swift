import AppKit
import SwiftUI
import Combine
import QingJieCore

/// Annotates the frozen selection at its original screen position, without an editor window.
final class InlineCaptureView: NSView {
    private static let toolbarSize = CGSize(width: 780, height: 132)
    let model: EditorModel
    var selection: CGRect { model.captureSelection ?? .zero }
    let screenshot: CGImage
    let captureAppearance: ScreenshotAppearance
    private var pixelsPerPoint: CGFloat { CGFloat(screenshot.width) / bounds.width }
    let canvas: AnnotationCanvas
    let resizeHandles = CaptureResizeHandles(frame: .zero)
    private var resizeSnapshot: EditorSnapshot?
    private var resizingHandle: RectResizeHandle?
    var onFinish: (() -> Void)?
    var onExport: ((ScreenshotOutput) -> Void)?
    var onCancel: (() -> Void)?
    var onReselect: (() -> Void)?
    var onSavePanelChange: ((Bool) -> Void)?
    private let saver = ScreenshotSaver()
    private var saving = false
    private let onStartScrolling: ((CGRect, CGRect, CGImage) throws -> Void)?
    private var toolbar: NSView!
    private var textBox: NSScrollView?
    private var textView: CaptureTextView?
    private var changes: AnyCancellable?
    private var refreshScheduled = false
    private var monitor: Any?
    private var cursorTracking: NSTrackingArea?
    override var isFlipped: Bool { true }

    init(screenshot: CGImage, crop: CGImage, selection: CGRect, size: CGSize, appearance: ScreenshotAppearance = .init(),
         onStartScrolling: ((CGRect, CGRect, CGImage) throws -> Void)? = nil) {
        self.screenshot = screenshot; self.onStartScrolling = onStartScrolling
        self.captureAppearance = appearance
        model = EditorModel(image: crop); model.tool = .rectangle
        model.captureSelection = selection
        model.message = "拖动四角调整大小，边线移动选区 · 触碰标注即可拖动 · Enter 复制 · ⌘S 另存为"
        canvas = AnnotationCanvas(model: model)
        super.init(frame: CGRect(origin: .zero, size: size))
        canvas.drawsBackdrop = false; addSubview(canvas)
        // 框选完成后回到普通箭头；十字线只属于框选阶段和绘制中的画笔。
        canvas.crosshairForTools = false
        canvas.wantsLayer = true; canvas.layer?.masksToBounds = true
        canvas.layer?.cornerRadius = captureAppearance.roundedCorners ? captureAppearance.cornerRadius : 0
        addSubview(resizeHandles)
        resizeHandles.onBegin = { [weak self] in self?.beginResize($0) }
        resizeHandles.onDrag = { [weak self] in self?.resize(to: $0, square: $1) }
        resizeHandles.onEnd = { [weak self] in self?.endResize() }
        resizeHandles.onCursorUpdate = { [weak self] in self?.mouseMoved(with: $0) }
        canvas.onCursorUpdate = { [weak self] in self?.mouseMoved(with: $0) }
        canvas.onInteractionBegan = { [weak self] in self?.commitText() }
        canvas.onTextRequested = { [weak self] point in self?.beginText(at: point) }
        toolbar = NSHostingView(rootView: CaptureToolbar(model: model, supportsScrolling: onStartScrolling != nil,
                                                        startScrolling: { [weak self] in self?.startScrolling() }, finish: { [weak self] in self?.complete() },
                                                        save: { [weak self] in self?.saveAs() },
                                                        cancel: { [weak self] in self?.onCancel?() },
                                                        reselect: { [weak self] in self?.onReselect?() },
                                                        commitText: { [weak self] in self?.commitText() }))
        addSubview(toolbar)
        changes = model.objectWillChange.sink { [weak self] in
            guard let self, !refreshScheduled else { return }
            refreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                refreshScheduled = false; canvas.needsDisplay = true
                if !canvas.isInteracting { window?.invalidateCursorRects(for: canvas) }
                needsDisplay = true; needsLayout = true; layoutSubtreeIfNeeded()
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    static func renderToolbarPreview(tool: MarkTool) -> CGImage? {
        let model = EditorModel(image: DemoImage.make())
        model.add(Mark(tool: .rectangle, start: .zero, end: CGPoint(x: 100, y: 100), color: .red, width: 4))
        model.add(Mark(tool: .arrow, start: .zero, end: CGPoint(x: 100, y: 100), color: .red, width: 4))
        model.undo(); model.tool = tool; model.showingText = tool == .text
        model.message = "拖动四角调整大小，边线移动选区 · 触碰标注即可拖动 · Enter 复制 · ⌘S 另存为"
        let view = NSHostingView(rootView: CaptureToolbar(model: model, supportsScrolling: true, startScrolling: {}, finish: {},
                                                         save: {}, cancel: {}, reselect: {}, commitText: {}))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: toolbarSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; view.layoutSubtreeIfNeeded()
        defer { window.close() }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap); return bitmap.cgImage
    }
    override func layout() {
        super.layout()
        canvas.frame = selection
        canvas.displayScale = selection.width / model.imageSize.width
        canvas.layer?.cornerRadius = captureAppearance.roundedCorners ? min(captureAppearance.cornerRadius, min(selection.width, selection.height) / 2) : 0
        resizeHandles.frame = bounds; resizeHandles.selection = selection
        resizeHandles.enabled = !saving && !model.isSamplingColor
        toolbar.frame = CaptureGeometry.toolbarFrame(selection: selection, bounds: bounds.size, size: Self.toolbarSize)
        refreshCursor()
    }
    func beginResize(_ corner: RectCorner) {
        beginResize(.corner(corner))
    }
    func beginResize(_ handle: RectResizeHandle) {
        guard !saving, !model.isSamplingColor, !canvas.isInteracting else { return }
        commitText(); resizeSnapshot = model.snapshot; resizingHandle = handle
    }
    func resize(to point: CGPoint, square: Bool = false) {
        guard let before = resizeSnapshot, let rect = before.captureSelection, let resizingHandle else { return }
        let adjusted = InteractionGeometry.resize(rect, handle: resizingHandle, to: point, bounds: bounds, minimum: 3, square: square)
        guard adjusted != selection else { return }
        model.reframeCapture(adjusted, screenshot: screenshot, displaySize: bounds.size, from: before)
        needsDisplay = true; needsLayout = true; layoutSubtreeIfNeeded()
    }
    func endResize() {
        if let before = resizeSnapshot, before.captureSelection != selection { model.checkpoint(before) }
        resizeSnapshot = nil; resizingHandle = nil
    }
    @discardableResult private func cancelResize() -> Bool {
        guard let before = resizeSnapshot else { return false }
        model.restore(before); resizeHandles.stopDragging(); resizeSnapshot = nil; resizingHandle = nil
        needsDisplay = true; needsLayout = true; layoutSubtreeIfNeeded(); return true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate], owner: self)
        addTrackingArea(area); cursorTracking = area
    }
    func cursor(at point: CGPoint) -> NSCursor? {
        guard !saving, !model.isSamplingColor, bounds.contains(point) else { return nil }
        let handlePoint = resizeHandles.convert(point, from: self)
        if resizeHandles.dragging { return resizeHandles.cursor(at: handlePoint) }
        let canvasPoint = canvas.convert(point, from: self)
        if canvas.isInteracting { return canvas.cursor(at: canvasPoint) }
        // Route by the same frontmost view that receives a click; text editors and toolbar retain priority.
        let hit = hitTest(convert(point, to: superview))
        if hit === resizeHandles { return resizeHandles.cursor(at: handlePoint) }
        if hit === canvas { return canvas.cursor(at: canvasPoint) }
        if let textBox, let hit, hit === textBox || hit.isDescendant(of: textBox) { return nil }
        return .arrow
    }
    override func mouseMoved(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil))?.set()
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func cursorUpdate(with event: NSEvent) { mouseMoved(with: event) }
    private func refreshCursor() {
        guard let window, window.isKeyWindow, window.isVisible else { return }
        cursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))?.set()
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        Raster.draw(screenshot, in: bounds, context: context)
        context.setFillColor(NSColor.black.withAlphaComponent(0.46).cgColor); context.fill(bounds)
        context.setStrokeColor(NSColor(calibratedRed: 0.73, green: 0.94, blue: 0.62, alpha: 1).cgColor)
        let radius = captureAppearance.roundedCorners ? min(captureAppearance.cornerRadius, min(selection.width, selection.height) / 2) + 1.5 : 0
        context.setLineWidth(3)
        context.addPath(CGPath(roundedRect: selection.insetBy(dx: -1.5, dy: -1.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.strokePath()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window, event.window === window else { return event }
            if model.isSamplingColor || saving { return event }
            if event.keyCode == 53, cancelResize() || canvas.cancelInteraction() { refreshCursor(); return nil }
            if resizeSnapshot != nil || canvas.isInteracting { return nil }
            if event.keyCode == 1 && CaptureShortcut(event: event).modifiers == .command { saveAs(); return nil }
            // Native text editing retains normal typing, Return and ⌘C.
            if textBox != nil { return event }
            if event.isARepeat { return event }
            let modifiers = CaptureShortcut(event: event).modifiers
            if event.keyCode == 53 { onCancel?(); return nil }
            if [36, 76].contains(event.keyCode) && modifiers.isEmpty || event.keyCode == 8 && modifiers == .command {
                complete(); return nil
            }
            if event.keyCode == 6 && modifiers == .command { model.undo(); return nil }
            if event.keyCode == 6 && modifiers == [.command, .shift] { model.redo(); return nil }
            let shortcuts: [UInt16: MarkTool] = [18: .select, 19: .rectangle, 20: .ellipse, 21: .arrow, 23: .pen, 22: .text, 26: .mosaic]
            if modifiers.isEmpty, let tool = shortcuts[event.keyCode] {
                model.tool = tool; model.selectedID = nil; return nil
            }
            return event
        }
        window?.makeFirstResponder(canvas)
    }
    func startScrolling() {
        guard !model.isSamplingColor, !saving, resizeSnapshot == nil, !canvas.isInteracting, let onStartScrolling else { return }
        guard model.marks.isEmpty, !model.showingText else {
            model.message = "请先撤销标注，再开始长截图"; return
        }
        guard let pixels = CaptureGeometry.pixelRect(selection: selection, bounds: bounds.size,
                                                     pixels: CGSize(width: screenshot.width, height: screenshot.height)) else { return }
        do { try onStartScrolling(selection, pixels, model.image) }
        catch { model.message = "无法开始长截图：\(error.localizedDescription)" }
    }
    func complete(to pasteboard: NSPasteboard = .general) {
        guard !model.isSamplingColor, !saving, resizeSnapshot == nil, !canvas.isInteracting else { return }
        commitText()
        guard let result = model.rendered() else { model.message = "无法生成截图，请重试。"; return }
        do {
            let output = try captureAppearance.render(result, pixelsPerPoint: pixelsPerPoint)
            guard ClipboardImage.write(output, to: pasteboard) else { model.message = "复制失败：无法写入剪贴板"; return }
            onFinish?()
            onExport?(.copied(output))
        } catch { model.message = "美化失败：\(error.localizedDescription)"; return }
    }
    func saveAs(using present: ((CGImage, @escaping (ScreenshotSaver.Outcome) -> Void) -> Void)? = nil) {
        guard !model.isSamplingColor, !saving, resizeSnapshot == nil, !canvas.isInteracting else { return }
        commitText()
        guard let result = model.rendered() else { model.message = "无法生成截图，请重试。"; return }
        saving = true; onSavePanelChange?(true)
        let handler: (ScreenshotSaver.Outcome) -> Void = { [weak self] outcome in
            guard let self else { return }
            saving = false
            switch outcome {
            case .saved(let url): onFinish?(); onExport?(.saved(url))
            case .cancelled: onSavePanelChange?(false); model.message = "已取消保存，截图和标注仍保留。"
            case .failed(let reason): onSavePanelChange?(false); model.message = "保存失败：\(reason) · 可重试另存为"
            }
        }
        if let present { present(result, handler) }
        else { saver.present(result, appearance: captureAppearance, pixelsPerPoint: pixelsPerPoint, completion: handler) }
    }
    private func beginText(at point: CGPoint) {
        commitText()
        model.textPoint = point; model.showingText = true
        let editor = CaptureTextView()
        editor.isRichText = false; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: max(12, model.fontSize * canvas.displayScale), weight: .semibold)
        editor.textColor = model.color; editor.backgroundColor = .white
        editor.textContainerInset = NSSize(width: 7, height: 7)
        editor.onCommit = { [weak self] in self?.commitText() }
        editor.onCancel = { [weak self] in self?.endText() }
        let width = min(280, selection.width), height = min(100, selection.height)
        let x = min(max(selection.minX, selection.minX + point.x * canvas.displayScale), selection.maxX - width)
        let y = min(max(selection.minY, selection.minY + point.y * canvas.displayScale), selection.maxY - height)
        let scroll = NSScrollView(frame: CGRect(x: x, y: y, width: width, height: height))
        scroll.borderType = .lineBorder; scroll.hasVerticalScroller = true; scroll.documentView = editor
        editor.frame = CGRect(origin: .zero, size: scroll.contentSize)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        addSubview(scroll, positioned: .below, relativeTo: toolbar)
        textBox = scroll; textView = editor
        model.message = "输入文字 · Enter 换行 · ⌘Enter 或勾选按钮确认 · Esc 取消文字"
        window?.makeFirstResponder(editor)
    }
    private func commitText() {
        guard let textView else { return }
        model.textInput = textView.string; model.addText(); endText()
    }
    private func endText() {
        textBox?.removeFromSuperview(); textBox = nil; textView = nil
        model.showingText = false; model.textInput = ""; model.textPoint = nil
        model.message = "拖动四角调整大小，边线移动选区 · 触碰标注即可拖动 · Enter 复制 · ⌘S 另存为"
        window?.makeFirstResponder(canvas)
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

private final class CaptureTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        else if [36, 76].contains(event.keyCode), event.modifierFlags.contains(.command) { onCommit?() }
        else { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if [36, 76].contains(event.keyCode), event.modifierFlags.contains(.command) { onCommit?(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

private struct CaptureToolbar: View {
    @ObservedObject var model: EditorModel
    let supportsScrolling: Bool
    let startScrolling: () -> Void
    let finish: () -> Void
    let save: () -> Void
    let cancel: () -> Void
    let reselect: () -> Void
    let commitText: () -> Void
    private let tools: [MarkTool] = [.select, .rectangle, .ellipse, .arrow, .pen, .text, .mosaic]
    private let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .white, .black]
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                    Button { commitText(); model.tool = tool; model.selectedID = nil } label: {
                        MarkToolIcon(tool: tool)
                    }.buttonStyle(AnnotationIconButtonStyle(selected: model.tool == tool)).help("\(tool.title) · \(index + 1)").accessibilityLabel(tool.title)
                }
                Divider().frame(height: 22)
                Button { model.undo() } label: { AnnotationIcon(kind: .undo) }
                    .buttonStyle(AnnotationIconButtonStyle()).disabled(model.undoStack.isEmpty).help("撤销 ⌘Z").accessibilityLabel("撤销")
                Button { model.redo() } label: { AnnotationIcon(kind: .redo) }
                    .buttonStyle(AnnotationIconButtonStyle()).disabled(model.redoStack.isEmpty).help("重做 ⇧⌘Z").accessibilityLabel("重做")
                Spacer(minLength: 12)
                CaptureIconButton(kind: .reselect, title: "重新框选", help: "重新框选截图区域", action: reselect)
                CaptureIconButton(kind: .scrolling, title: "长截图",
                                  help: !supportsScrolling ? "静态图片不能滚动，可在使用指南中体验长截图" : !model.marks.isEmpty || model.showingText ? "请先结束文字输入并撤销标注，再开始长截图" : "沿用当前选区，开始自然滚动采集",
                                  action: startScrolling)
                    .disabled(!supportsScrolling || !model.marks.isEmpty || model.showingText || model.isSamplingColor)
                CaptureIconButton(kind: .close, title: "取消截图", help: "取消截图 · Esc", action: cancel)
                CaptureIconButton(kind: .save, title: "另存为", help: "另存为 · ⌘S", action: save)
                CaptureIconButton(kind: .copy, title: "完成复制", help: "完成并复制到剪贴板 · Enter / ⌘C", primary: true, action: finish)
            }
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                    Button { model.color = color } label: {
                        Circle().fill(Color(nsColor: color)).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(model.color == color ? Theme.green : .gray.opacity(0.3), lineWidth: model.color == color ? 2 : 1))
                    }.buttonStyle(AnnotationIconButtonStyle()).accessibilityLabel(color.accessibilityName)
                }
                }
                ScreenColorPickerButton(model: model, beforeSampling: commitText)
                CurrentAnnotationColor(model: model)
                if model.tool == .mosaic && model.mosaicStyle == .solid {
                    Text("使用当前颜色").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                } else {
                    Text(model.tool == .mosaic ? "强度" : "粗细").font(.system(size: 10))
                    Slider(value: $model.lineWidth, in: 2...16, step: 1).frame(width: 70).tint(Theme.green)
                }
                if model.tool == .text {
                    Text("字号").font(.system(size: 10))
                    Slider(value: $model.fontSize, in: 16...100, step: 2).frame(width: 65).tint(Theme.green)
                }
                Spacer(minLength: 0)
                if model.tool == .mosaic { MosaicStylePicker(model: model).frame(width: 110) }
                if model.showingText {
                    CaptureIconButton(kind: .confirm, title: "添加文字", help: "确认文字 · ⌘Enter", action: commitText)
                }
            }
            HStack(spacing: 8) {
                Text(model.message).font(.system(size: 11)).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(model.image.width) × \(model.image.height) px").font(.system(size: 12, design: .monospaced)).fixedSize()
            }.foregroundStyle(Theme.secondary)
        }.padding(12).frame(maxWidth: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 11))
            .foregroundStyle(Theme.green).preferredColorScheme(.light)
    }
}
