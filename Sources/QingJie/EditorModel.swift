import AppKit
import SwiftUI
import Vision
import QingJieCore

enum MarkTool: String, CaseIterable, Identifiable {
    case select, rectangle, ellipse, arrow, pen, text, mosaic, crop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .select: return "选择"; case .rectangle: return "矩形"; case .ellipse: return "椭圆"
        case .arrow: return "箭头"; case .pen: return "画笔"; case .text: return "文字"
        case .mosaic: return "马赛克"; case .crop: return "裁剪"
        }
    }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"; case .rectangle: return "rectangle"; case .ellipse: return "oval"
        case .arrow: return "arrow.up.right"; case .pen: return "pencil.tip"; case .text: return "t.square"
        case .mosaic: return "square.grid.3x3.fill"; case .crop: return "crop"
        }
    }
}

struct Mark: Identifiable {
    var id = UUID()
    var tool: MarkTool
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var color: NSColor
    var width: CGFloat
    var text = ""
    var fontSize: CGFloat = 32
    var mosaicStyle: MosaicStyle = .gaussian

    var rect: CGRect { CaptureGeometry.rectangle(from: start, to: end) }
    var extent: CGRect {
        if tool == .text {
            let size = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)])
            return CGRect(origin: start, size: size)
        }
        if tool == .pen, let first = points.first {
            return points.reduce(CGRect(origin: first, size: CGSize(width: 1, height: 1))) {
                $0.union(CGRect(origin: $1, size: CGSize(width: 1, height: 1)))
            }.insetBy(dx: -width, dy: -width)
        }
        return rect.insetBy(dx: -width, dy: -width)
    }
    mutating func translate(x: CGFloat, y: CGFloat) {
        start.x += x; start.y += y; end.x += x; end.y += y
        points = points.map { CGPoint(x: $0.x + x, y: $0.y + y) }
    }
    func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        let radius = tolerance + width / 2
        switch tool {
        case .text: return extent.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .mosaic: return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .rectangle:
            let outer = rect.insetBy(dx: -radius, dy: -radius), inner = rect.insetBy(dx: radius, dy: radius)
            return outer.contains(point) && (inner.width <= 0 || inner.height <= 0 || !inner.contains(point))
        case .ellipse:
            let path = CGPath(ellipseIn: rect, transform: nil)
            return path.copy(strokingWithWidth: radius * 2, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(point)
        case .arrow:
            let angle = atan2(end.y - start.y, end.x - start.x)
            let length = min(max(16, width * 4), hypot(end.x - start.x, end.y - start.y) * 0.45)
            let a = CGPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6))
            let b = CGPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6))
            return [(start, end), (a, end), (end, b)].contains { InteractionGeometry.distance(point, toSegmentFrom: $0.0, to: $0.1) <= radius }
        case .pen:
            if points.count == 1, let first = points.first { return hypot(first.x - point.x, first.y - point.y) <= radius }
            return zip(points, points.dropFirst()).contains { InteractionGeometry.distance(point, toSegmentFrom: $0.0, to: $0.1) <= radius }
        case .select, .crop: return false
        }
    }
}

enum Raster {
    static func draw(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    static func draw(mark: Mark, base: CGImage, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(mark.color.cgColor); context.setFillColor(mark.color.cgColor)
        context.setLineWidth(mark.width); context.setLineCap(.round); context.setLineJoin(.round)
        switch mark.tool {
        case .rectangle: context.stroke(mark.rect)
        case .ellipse: context.strokeEllipse(in: mark.rect)
        case .arrow:
            let angle = atan2(mark.end.y - mark.start.y, mark.end.x - mark.start.x)
            let length = min(max(16, mark.width * 4), hypot(mark.end.x - mark.start.x, mark.end.y - mark.start.y) * 0.45)
            context.move(to: mark.start); context.addLine(to: mark.end)
            context.move(to: CGPoint(x: mark.end.x - length * cos(angle - .pi / 6), y: mark.end.y - length * sin(angle - .pi / 6)))
            context.addLine(to: mark.end)
            context.addLine(to: CGPoint(x: mark.end.x - length * cos(angle + .pi / 6), y: mark.end.y - length * sin(angle + .pi / 6)))
            context.strokePath()
        case .pen:
            guard let first = mark.points.first else { return }
            if mark.points.count < 2 { context.fillEllipse(in: CGRect(x: first.x - mark.width / 2, y: first.y - mark.width / 2, width: mark.width, height: mark.width)); return }
            context.move(to: first); mark.points.dropFirst().forEach { context.addLine(to: $0) }; context.strokePath()
        case .text:
            (mark.text as NSString).draw(at: mark.start, withAttributes: [
                .font: NSFont.systemFont(ofSize: mark.fontSize, weight: .semibold), .foregroundColor: mark.color
            ])
        case .mosaic:
            let rect = mark.rect.integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
            guard rect.width >= 1, rect.height >= 1 else { return }
            if mark.mosaicStyle == .solid {
                context.setFillColor(mark.color.withAlphaComponent(1).cgColor); context.fill(rect)
            } else if let patch = MosaicRenderer.image(base: base, rect: rect, style: mark.mosaicStyle, strength: mark.width) {
                context.interpolationQuality = mark.mosaicStyle == .pixelated ? .none : .high
                draw(patch, in: rect, context: context)
            } else {
                // A failed filter must not silently leave the requested cover transparent.
                context.setFillColor(mark.color.withAlphaComponent(1).cgColor); context.fill(rect)
            }
        case .select, .crop: break
        }
    }

    static func render(base: CGImage, marks: [Mark]) -> CGImage? {
        // Tag exports with sRGB so PNG/JPEG readers agree on colors across displays.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(base.height)); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height), context: context)
        marks.forEach { draw(mark: $0, base: base, context: context) }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

struct EditorSnapshot { var image: CGImage; var marks: [Mark]; var captureSelection: CGRect? = nil }

enum CanvasMode: String, CaseIterable { case fit = "适应窗口", width = "适应宽度", actual = "实际像素" }

final class EditorModel: ObservableObject {
    @Published var canvasMode: CanvasMode
    @Published var image: CGImage
    @Published var captureSelection: CGRect?
    @Published var marks: [Mark] = []
    @Published var tool: MarkTool = .arrow
    @Published var color: NSColor = NSColor(calibratedRed: 0.95, green: 0.30, blue: 0.24, alpha: 1)
    @Published var lineWidth: CGFloat = 5
    @Published var mosaicStyle: MosaicStyle = .gaussian
    @Published private(set) var isSamplingColor = false
    var onSamplingChange: ((Bool) -> Void)?
    @Published var fontSize: CGFloat = 36
    @Published var selectedID: UUID?
    @Published var undoStack: [EditorSnapshot] = []
    @Published var redoStack: [EditorSnapshot] = []
    @Published var message = "拖动绘制箭头 · 1–8 切换工具"
    @Published var textPoint: CGPoint?
    @Published var textInput = ""
    @Published var showingText = false
    @Published var recognizedText = ""
    @Published var showingOCR = false
    @Published var recognizing = false
    var onPin: ((CGImage) -> Void)?
    var onExport: ((CGImage) -> Void)?
    var onFileExport: ((URL) -> Void)?
    var imageSize: CGSize { CGSize(width: image.width, height: image.height) }
    var snapshot: EditorSnapshot { EditorSnapshot(image: image, marks: marks, captureSelection: captureSelection) }

    init(image: CGImage) {
        self.image = image
        canvasMode = image.height > image.width * 3 / 2 ? .width : .fit
    }
    var colorHex: String {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int((min(1, max(0, $0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
    }
    func sampleColor(using sample: (@escaping (NSColor?) -> Void) -> Void = { completion in
        // Give the window server one update to remove capture dimming before sampling the live screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSColorSampler().show(selectionHandler: completion) }
    }) {
        guard !isSamplingColor else { return }
        isSamplingColor = true; message = "点击屏幕吸取颜色 · Esc 取消取色"
        onSamplingChange?(true)
        sample { [weak self] chosen in
            guard let self else { return }
            if let chosen, let rgb = chosen.usingColorSpace(.sRGB) {
                color = rgb.withAlphaComponent(1); message = "已吸取 \(colorHex) · 应用于接下来添加的标注"
            } else { message = "已取消取色，颜色保持不变" }
            isSamplingColor = false; onSamplingChange?(false)
        }
    }
    func checkpoint(_ state: EditorSnapshot? = nil) {
        undoStack.append(state ?? snapshot)
        if undoStack.count > 40 { undoStack.removeFirst() }
        redoStack.removeAll()
    }
    func undo() {
        guard let state = undoStack.popLast() else { return }
        redoStack.append(snapshot); restore(state)
    }
    func redo() {
        guard let state = redoStack.popLast() else { return }
        undoStack.append(snapshot); restore(state)
    }
    func restore(_ state: EditorSnapshot) {
        image = state.image; marks = state.marks; captureSelection = state.captureSelection; selectedID = nil
    }
    func reframeCapture(_ rect: CGRect, screenshot: CGImage, displaySize: CGSize, from before: EditorSnapshot) {
        let pixels = CGSize(width: screenshot.width, height: screenshot.height)
        guard let old = before.captureSelection,
              let oldPixels = CaptureGeometry.pixelRect(selection: old, bounds: displaySize, pixels: pixels),
              let newPixels = CaptureGeometry.pixelRect(selection: rect, bounds: displaySize, pixels: pixels),
              let crop = screenshot.cropping(to: newPixels) else { return }
        // Align the overlay to actual pixel edges. Marks stay anchored to the frozen screen,
        // including temporarily clipped marks that can reappear when the selection expands.
        captureSelection = CGRect(x: newPixels.minX / pixels.width * displaySize.width,
                                  y: newPixels.minY / pixels.height * displaySize.height,
                                  width: newPixels.width / pixels.width * displaySize.width,
                                  height: newPixels.height / pixels.height * displaySize.height)
        image = crop
        marks = before.marks.map { mark in
            var mark = mark; mark.translate(x: oldPixels.minX - newPixels.minX, y: oldPixels.minY - newPixels.minY); return mark
        }
        selectedID = nil
    }
    func add(_ mark: Mark) { checkpoint(); marks.append(mark); selectedID = nil; message = "已添加\(mark.tool.title) · ⌘Z 撤销" }
    func deleteSelected() {
        guard let id = selectedID else { return }
        checkpoint(); marks.removeAll { $0.id == id }; selectedID = nil
    }
    func crop(_ rect: CGRect) {
        guard rect.width > 3, rect.height > 3,
              let pixels = CaptureGeometry.pixelRect(selection: rect, bounds: imageSize, pixels: imageSize),
              let result = rendered()?.cropping(to: pixels) else { return }
        checkpoint(); image = result; marks = []; selectedID = nil; tool = .arrow
        message = "已裁剪为 \(result.width) × \(result.height) · ⌘Z 可恢复"
    }
    func addText() {
        guard let point = textPoint, !textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        add(Mark(tool: .text, start: point, end: point, color: color, width: lineWidth, text: textInput, fontSize: fontSize))
        textInput = ""; textPoint = nil
    }
    func rendered() -> CGImage? { Raster.render(base: image, marks: marks) }
    @discardableResult func copy(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let result = rendered(), ClipboardImage.write(result, to: pasteboard) else { message = "复制失败：无法写入剪贴板"; return false }
        onExport?(result); message = "已复制到剪贴板，可直接粘贴到微信、文档或邮件"
        return true
    }
    private let screenshotSaver = ScreenshotSaver()
    @MainActor func save() {
        guard let result = rendered() else { return }
        screenshotSaver.present(result) { [weak self] outcome in
            switch outcome {
            case .saved(let url):
                if let export = self?.onFileExport { export(url) } else { self?.onExport?(result) }
                self?.message = "已保存：\(url.lastPathComponent)"
            case .cancelled: break
            case .failed(let reason): self?.message = "保存失败：\(reason)"
            }
        }
    }
    func recognize() {
        guard !recognizing, let result = rendered() else { return }
        recognizing = true; message = "正在本机识别文字…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]; request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(cgImage: result).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                DispatchQueue.main.async { self?.recognizedText = text; self?.recognizing = false; self?.showingOCR = true; self?.message = text.isEmpty ? "未识别到文字" : "文字识别完成" }
            } catch { DispatchQueue.main.async { self?.recognizing = false; self?.message = "识别失败：\(error.localizedDescription)" } }
        }
    }
}

enum ClipboardImage {
    static func writePNG(at url: URL, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return false }
        pasteboard.clearContents()
        return pasteboard.setData(data, forType: .png)
    }
    static func write(_ image: CGImage, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let data = Raster.png(image) else { return false }
        pasteboard.clearContents()
        return pasteboard.setData(data, forType: .png)
    }
}
