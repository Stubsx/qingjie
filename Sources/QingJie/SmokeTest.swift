import AppKit
import Vision
import QingJieCore

enum SmokeTest {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        if !condition() { throw Failure(description: label) }
        print("PASS: \(label)")
    }
    @MainActor static func run() throws {
        try checkShortcutRecorder()
        try checkInlineCaptureAndPermissionDrag()
        try checkSelectionToScrolling()
        try checkWindowSelection()
        try checkInAppWindowSelection()
        try checkBrowserContentSelection()
        try checkCaptureResizing()
        try checkCaptureEdgeDragging()
        try checkDirectAnnotationEditing()
        try checkScreenshotSaving()
        try checkScreenshotAppearance()
        try checkCaptureHistory()
        try checkMosaicStylesAndSampling()
        let source = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 160, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let red = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), green = NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1)
        let blue = NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1), white = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
        let black = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1)
        for y in 0..<160 {
            for x in 0..<240 {
                source.setColor(y < 80 ? (x < 120 ? red : green) : (x < 120 ? blue : white), atX: x, y: y)
            }
        }
        let base = source.cgImage!
        let roundtrip = Raster.render(base: base, marks: [])!
        let rep = NSBitmapImageRep(cgImage: roundtrip)
        func close(_ a: NSColor, _ b: NSColor) -> Bool {
            // Compare encoded RGB channels; colorAt reports calibrated colors even for tagged sRGB bitmaps.
            let a = a.numberOfComponents < 3 ? a.usingColorSpace(.deviceRGB)! : a
            let b = b.numberOfComponents < 3 ? b.usingColorSpace(.deviceRGB)! : b
            return abs(a.redComponent - b.redComponent) < 0.04 && abs(a.greenComponent - b.greenComponent) < 0.04 && abs(a.blueComponent - b.blueComponent) < 0.04
        }
        try require(close(rep.colorAt(x: 20, y: 20)!, .red), "渲染保留左上角像素和方向")
        try require(close(rep.colorAt(x: 20, y: 140)!, .blue), "渲染保留左下角像素和方向")
        let box = Mark(tool: .rectangle, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 65, y: 50), color: .black, width: 4)
        let marked = NSBitmapImageRep(cgImage: Raster.render(base: base, marks: [box])!)
        try require(close(marked.colorAt(x: 35, y: 10)!, .black), "矩形标注按左上坐标导出")
        try require(close(marked.colorAt(x: 35, y: 150)!, .blue), "标注不会错误翻转到底部")
        let model = EditorModel(image: base)
        model.add(box); model.crop(CGRect(x: 0, y: 80, width: 120, height: 80))
        try require(model.image.width == 120 && model.image.height == 80 && model.marks.isEmpty, "裁剪按原始像素并合并标注")
        try require(close(NSBitmapImageRep(cgImage: model.image).colorAt(x: 20, y: 20)!, .blue), "裁剪选中正确的下半部分")
        model.undo(); try require(model.image.width == 240 && model.marks.count == 1, "撤销裁剪恢复原图和标注")
        model.undo(); try require(model.marks.isEmpty, "撤销添加标注")
        model.redo(); try require(model.marks.count == 1, "重做恢复标注")
        model.redo(); try require(model.image.width == 120, "重做恢复裁剪")
        model.undo(); model.add(box); try require(model.redoStack.isEmpty, "新操作清空重做分支")

        let patterned = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 160, bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<160 { for x in 0..<160 { patterned.setColor((x + y) % 2 == 0 ? black : white, atX: x, y: y) } }
        let mosaic = Mark(tool: .mosaic, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 140, y: 140), color: .red, width: 6, mosaicStyle: .pixelated)
        let mosaicRep = NSBitmapImageRep(cgImage: Raster.render(base: patterned.cgImage!, marks: [mosaic])!)
        try require(close(mosaicRep.colorAt(x: 25, y: 25)!, mosaicRep.colorAt(x: 26, y: 25)!), "马赛克合并高频像素")
        try require(close(mosaicRep.colorAt(x: 0, y: 0)!, .black) && close(mosaicRep.colorAt(x: 1, y: 0)!, .white), "马赛克不影响选区外像素")

        let text = Mark(tool: .text, start: CGPoint(x: 125, y: 10), end: .zero, color: .black, width: 3, text: "Test", fontSize: 24)
        let textRep = NSBitmapImageRep(cgImage: Raster.render(base: base, marks: [text])!)
        var dark = 0
        for y in 10..<45 { for x in 125..<200 { if close(textRep.colorAt(x: x, y: y)!, .black) { dark += 1 } } }
        try require(dark > 30, "文字在正确位置栅格化")
        let png = Raster.png(roundtrip)!
        let decoded = NSBitmapImageRep(data: png)!
        try require(decoded.pixelsWide == 240 && decoded.pixelsHigh == 160, "PNG 导出保持原始尺寸")
        try require(close(decoded.colorAt(x: 20, y: 140)!, .blue), "PNG 编解码保留像素")
        let jpeg = NSBitmapImageRep(cgImage: roundtrip).representation(using: .jpeg, properties: [.compressionFactor: 0.95])!
        try require(NSBitmapImageRep(data: jpeg)?.pixelsWide == 240, "JPEG 导出可重新打开")
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: DemoImage.make()).perform([request])
        let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined()
        try require(recognized.contains("QINGJIE"), "Vision 本机 OCR 可识别示例图")
        let longSource = DemoScrollSource()
        let stitcher = try VerticalStitcher(first: longSource.frame())
        var scrollSteps = 0
        while longSource.offset < longSource.document.height - longSource.viewportHeight {
            let previousOffset = longSource.offset
            longSource.advance()
            let outcome = try stitcher.append(longSource.frame())
            guard outcome == .appended(longSource.offset - previousOffset) else {
                throw Failure(description: "中文文档第 \(scrollSteps + 1) 段拼接不正确：\(outcome)")
            }
            scrollSteps += 1
        }
        try require(scrollSteps > 4, "中文排版示例连续滚动至文档末尾")
        let longImage = try stitcher.compose()
        try require(longImage.width == longSource.document.width && longImage.height == longSource.document.height, "完整长截图尺寸包含末尾不足一屏的内容")
        let expectedLong = longSource.document.cropping(to: CGRect(x: 0, y: 0, width: longImage.width, height: longImage.height))!
        let actualPNG = Raster.png(Raster.render(base: longImage, marks: [])!)!
        let expectedPNG = Raster.png(Raster.render(base: expectedLong, marks: [])!)!
        try require(actualPNG == expectedPNG, "真实排版长图与原始文档逐像素一致")
        let bottomRepeat = try stitcher.append(longSource.frame())
        try require(bottomRepeat == .unchanged, "文档到底后不会追加重复内容")
        let preview = try stitcher.preview()
        try require(preview.height <= 260 && preview.width <= 160, "完整长图预览保持固定内存规模")
        let detailedPreview = try stitcher.preview(maximumHeight: 4096, maximumWidth: 640)
        try require(detailedPreview.width <= 640 && detailedPreview.height <= 4096 && detailedPreview.height > preview.height,
                    "长截图大预览提高细节分辨率并保持明确内存上限")
        for image in [preview, detailedPreview] {
            let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            try require(stride(from: 3, to: image.width * image.height * 4, by: 4).allSatisfy { bytes[$0] == 255 },
                        "中文长图 \(image.width) × \(image.height) 预览没有半透明横向接缝")
        }
        try require(EditorModel(image: longImage).canvasMode == .width, "长图编辑默认按宽度显示")
        let chromeSource = DemoChromeScrollSource()
        let firstChrome = chromeSource.frame()
        let chromeStitcher = try VerticalStitcher(first: firstChrome)
        let manualStitcher = try VerticalStitcher(first: firstChrome, contentRegion: chromeSource.contentRegion)
        while chromeSource.offset < chromeSource.document.height - chromeSource.viewportHeight {
            let previousOffset = chromeSource.offset
            chromeSource.advance()
            let frame = chromeSource.frame()
            let expected = StitchOutcome.appended(chromeSource.offset - previousOffset)
            guard try chromeStitcher.append(frame) == expected, try manualStitcher.append(frame) == expected else {
                throw Failure(description: "含固定顶栏和两侧目录的中文文档拼接失败，offset=\(chromeSource.offset)")
            }
        }
        let chromeImage = try chromeStitcher.compose()
        try require(chromeStitcher.width == chromeSource.document.width && chromeStitcher.outputRegion.minX == CGFloat(chromeSource.left),
                    "自动裁掉左右侧栏，同时沿背景分界保留内容区留白")
        let completeChrome = chromeSource.complete()
        let expectedChrome = completeChrome.cropping(to: CGRect(x: chromeStitcher.outputRegion.minX, y: 0, width: CGFloat(chromeStitcher.width), height: CGFloat(chromeImage.height)))!
        try require(Raster.png(Raster.render(base: chromeImage, marks: [])!) == Raster.png(Raster.render(base: expectedChrome, marks: [])!),
                    "固定顶栏底栏各保留一次，中文长图接缝逐像素一致")
        let manualImage = try manualStitcher.compose()
        try require(Raster.png(Raster.render(base: manualImage, marks: [])!) == expectedPNG, "手动内容区保留完整原文档及左右留白")
        let animated = DemoChromeScrollSource(animatesSidebars: true)
        let animatedFirst = animated.frame()
        let motionStitcher = try VerticalStitcher(first: animatedFirst)
        while animated.offset < animated.document.height - animated.viewportHeight {
            let before = animated.offset
            animated.advance()
            let result = try motionStitcher.append(animated.frame())
            guard result == .appended(animated.offset - before) else {
                throw Failure(description: "动画侧栏中的中文内容自动识别失败，offset=\(animated.offset)，结果=\(result)")
            }
        }
        let motionImage = try motionStitcher.compose()
        try require(motionStitcher.usesMotionRecognition, "中文页面通过分块位移识别排除持续刷新的双侧栏")
        try require(motionImage.width == animated.document.width, "运动识别保留正文完整宽度与留白")
        try require(Raster.png(Raster.render(base: motionImage, marks: [])!) == Raster.png(Raster.render(base: chromeImage, marks: [])!),
                    "侧栏动画不污染成品，正文及顶栏底栏逐像素一致")
        if let index = CommandLine.arguments.firstIndex(of: "--output"), index + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for tool in [MarkTool.rectangle, .mosaic, .text] {
                if let preview = InlineCaptureView.renderToolbarPreview(tool: tool) {
                    try Raster.png(preview)!.write(to: url.appendingPathComponent("toolbar-\(tool.rawValue).png"))
                }
            }
            try Raster.png(DemoImage.make())!.write(to: url.appendingPathComponent("demo.png"))
            try Raster.png(textRep.cgImage!)!.write(to: url.appendingPathComponent("render-check.png"))
            try Raster.png(longImage)!.write(to: url.appendingPathComponent("long-demo.png"))
            try Raster.png(detailedPreview)!.write(to: url.appendingPathComponent("scroll-preview.png"))
            if let hud = ScrollCaptureSession.renderHUDPreview(first: longImage, preview: detailedPreview) {
                try Raster.png(hud)!.write(to: url.appendingPathComponent("scroll-long-hud-preview.png"))
            }
            try Raster.png(firstChrome)!.write(to: url.appendingPathComponent("fixed-layout-before.png"))
            try Raster.png(chromeImage)!.write(to: url.appendingPathComponent("fixed-layout-long.png"))
            try Raster.png(animatedFirst)!.write(to: url.appendingPathComponent("motion-layout-before.png"))
            try Raster.png(motionImage)!.write(to: url.appendingPathComponent("motion-layout-long.png"))
            if let hud = ScrollCaptureSession.renderHUDPreview(first: firstChrome) {
                try Raster.png(hud)!.write(to: url.appendingPathComponent("scroll-hud-preview.png"))
            }
            if let permission = PermissionHelpController.renderPreview() {
                try Raster.png(permission)!.write(to: url.appendingPathComponent("permission-drag-preview.png"))
            }
            if let settings = ShortcutSettingsView.renderPreview() {
                try Raster.png(settings)!.write(to: url.appendingPathComponent("shortcut-settings-preview.png"))
            }
            if let settings = AppearanceSettingsView.renderPreview() {
                try Raster.png(settings)!.write(to: url.appendingPathComponent("appearance-settings-preview.png"))
            }
            let decorated = try ScreenshotAppearance(roundedCorners: true, shadow: true).render(DemoImage.make(), pixelsPerPoint: 2)
            try Raster.png(decorated)!.write(to: url.appendingPathComponent("appearance-png.png"))
        }
    }

    @MainActor private static func checkScreenshotSaving() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = DemoImage.make(), rect = CGRect(x: 20, y: 30, width: 280, height: 200)
        let crop = base.cropping(to: CGRect(x: 40, y: 60, width: 560, height: 400))!
        let inline = InlineCaptureView(screenshot: base, crop: crop, selection: rect, size: CGSize(width: 1000, height: 700))
        inline.model.add(Mark(tool: .mosaic, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 80, y: 90), color: .black, width: 4, mosaicStyle: .solid))
        let expected = inline.model.rendered()!, clipboard = NSPasteboard.general.changeCount
        let png = root.appendingPathComponent("截图.png"), jpeg = root.appendingPathComponent("长图.jpg")
        try ScreenshotSaver.write(expected, to: png); try ScreenshotSaver.write(expected, to: jpeg)
        let saved = NSBitmapImageRep(data: try Data(contentsOf: png))!
        try require(saved.pixelsWide == 560 && saved.pixelsHigh == 400 && Raster.png(saved.cgImage!) == Raster.png(expected), "另存为 PNG 保留原始尺寸、标注及无损像素")
        let jpg = NSBitmapImageRep(data: try Data(contentsOf: jpeg))!
        try require(jpg.pixelsWide == 560 && jpg.pixelsHigh == 400, "另存为 JPEG 使用正确格式和像素尺寸")
        var failed = false
        do { try ScreenshotSaver.write(expected, to: root.appendingPathComponent("missing/image.png")) } catch { failed = true }
        try require(failed && FileManager.default.fileExists(atPath: png.path), "写入失败会报告错误并保留已有文件")
        var visibility: [Bool] = [], completions = 0, pending: ((ScreenshotSaver.Outcome) -> Void)?
        inline.onSavePanelChange = { visibility.append($0) }; inline.onFinish = { completions += 1 }
        inline.saveAs { image, callback in pending = callback }
        var duplicate = false
        inline.saveAs { _, _ in duplicate = true }; inline.complete()
        try require(!duplicate && completions == 0 && visibility == [true], "保存面板打开时不会重复保存或提前完成复制")
        pending?(.cancelled)
        try require(visibility == [true, false] && completions == 0 && inline.model.marks.count == 1, "取消另存为恢复原选区和已有标注")
        inline.saveAs { _, callback in callback(.failed("测试磁盘写入失败")) }
        try require(completions == 0 && inline.model.message.contains("测试磁盘写入失败") && inline.model.marks.count == 1, "保存失败显示原因并允许原图重试")
        inline.saveAs { _, callback in callback(.saved(png)) }
        try require(completions == 1 && NSPasteboard.general.changeCount == clipboard, "另存为成功后关闭截图，剪贴板保持不变")
    }

    @MainActor private static func checkCaptureHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QingJie-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(historyDirectory: root.appendingPathComponent("History"))
        state.page = .settings
        let clipboard = NSPasteboard.withUniqueName(); defer { clipboard.releaseGlobally() }
        let base = DemoImage.make(), rect = CGRect(x: 20, y: 30, width: 280, height: 200)
        let crop = base.cropping(to: CGRect(x: 40, y: 60, width: 560, height: 400))!
        let appearance = ScreenshotAppearance(roundedCorners: true, shadow: true)
        let inline = InlineCaptureView(screenshot: base, crop: crop, selection: rect,
                                       size: CGSize(width: 1000, height: 700), appearance: appearance)
        inline.model.add(Mark(tool: .mosaic, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 200, y: 80), color: .black, width: 4, mosaicStyle: .solid))
        var finished = false, recordedAfterFinish = false
        inline.onFinish = { finished = true }
        inline.onExport = { recordedAfterFinish = finished; state.remember($0) }
        try require(state.history.isEmpty, "框选与标注过程中不会提前创建历史")
        inline.complete(to: clipboard)
        let copiedData = clipboard.data(forType: .png)!, item = state.history.first
        let recordedData = try item.map { try Data(contentsOf: $0.url) }
        try require(state.history.count == 1 && recordedData == copiedData && recordedAfterFinish,
                    "复制成功先关闭截图，再静默记录与剪贴板一致的标注圆角阴影成品")
        try require(state.page == .settings && AppState(historyDirectory: state.historyDirectory).history.count == 1,
                    "记录不切换工作台页面，重新启动仍能加载历史")
        let savedState = AppState(historyDirectory: root.appendingPathComponent("SavedHistory"))
        let saving = InlineCaptureView(screenshot: base, crop: crop, selection: rect,
                                       size: CGSize(width: 1000, height: 700), appearance: appearance)
        saving.onExport = { savedState.remember($0) }
        saving.saveAs { _, callback in callback(.cancelled) }
        saving.saveAs { _, callback in callback(.failed("测试写入失败")) }
        try require(savedState.history.isEmpty, "取消另存为及保存失败均不生成历史")
        let png = root.appendingPathComponent("saved.png")
        try ScreenshotSaver.write(crop, to: png, appearance: appearance, pixelsPerPoint: 2)
        saving.saveAs { _, callback in callback(.saved(png)) }
        let pngData = try Data(contentsOf: png)
        let savedHistoryData = try savedState.history.first.map { try Data(contentsOf: $0.url) }
        try require(savedState.history.count == 1 && savedHistoryData == pngData,
                    "另存为成功记录实际 PNG 文件，透明圆角阴影不丢失或重复添加")
        let jpeg = root.appendingPathComponent("saved.jpg")
        try ScreenshotSaver.write(crop, to: jpeg, appearance: appearance, pixelsPerPoint: 2)
        savedState.remember(.saved(jpeg))
        let jpegHistory = savedState.history.first.flatMap { NSImage(contentsOf: $0.url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        try require(savedState.history.count == 2 && jpegHistory?.width == crop.width && jpegHistory?.height == crop.height,
                    "JPEG 历史保留实际导出矩形尺寸，不重新套用 PNG 美化")
        let blocked = root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let unavailable = AppState(historyDirectory: blocked.appendingPathComponent("History"))
        unavailable.remember(.copied(crop))
        try require(unavailable.history.isEmpty && !unavailable.notice.isEmpty && clipboard.data(forType: .png) == copiedData,
                    "历史写入失败给出原因，不破坏已经成功的剪贴板内容")
        let bounded = AppState(historyDirectory: root.appendingPathComponent("BoundedHistory"))
        for index in 0..<32 { bounded.remember(recoveryFrame(offset: index * 9).cropping(to: CGRect(x: 0, y: 0, width: 16, height: 16))!) }
        let files = try FileManager.default.contentsOfDirectory(at: bounded.historyDirectory, includingPropertiesForKeys: nil)
        try require(bounded.history.count == 30 && files.count == 30 && AppState(historyDirectory: bounded.historyDirectory).history.count == 30,
                    "历史在磁盘和重启后均最多保留最近 30 张")
    }

    @MainActor private static func checkScreenshotAppearance() throws {
        let suite = "QingJie.appearance-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ScreenshotAppearanceSettings(defaults: defaults)
        try require(settings.value == ScreenshotAppearance(), "首次升级不自动改变已有截图外观")
        settings.roundedCorners = true; settings.shadow = true
        try require(ScreenshotAppearanceSettings(defaults: defaults).value == ScreenshotAppearance(roundedCorners: true, shadow: true),
                    "升级缺少参数键时沿用 R12 和原有阴影，并保留开关状态")
        settings.cornerRadius = 28; settings.shadowBlur = 20; settings.shadowOffset = 10; settings.shadowOpacity = 0.45
        let style = settings.value
        try require(ScreenshotAppearanceSettings(defaults: defaults).value == style, "圆角与阴影四个自定义参数持久保存，重新加载结果一致")
        settings.roundedCorners = false
        settings.resetParameters()
        try require(style.roundedCorners && !settings.value.roundedCorners, "截图开始时锁定外观，后续设置不改变当前截图")
        try require(settings.value == ScreenshotAppearance(shadow: true) && ScreenshotAppearanceSettings(defaults: defaults).value == settings.value,
                    "恢复美化默认参数保留两个开关，并持久保存默认值")
        defaults.set(-500, forKey: "QingJie.appearance.cornerRadius")
        defaults.set(9000, forKey: "QingJie.appearance.shadowBlur")
        defaults.set("invalid", forKey: "QingJie.appearance.shadowOffset")
        let recovered = ScreenshotAppearanceSettings(defaults: defaults).value
        try require(recovered.cornerRadius == 0 && recovered.shadowBlur == 48 && recovered.shadowOffset == 6,
                    "过期或损坏的美化参数会收敛到有效范围，预览及输出不崩溃")
        let base = DemoImage.make(), rect = CGRect(x: 20, y: 30, width: 280, height: 200)
        let crop = base.cropping(to: CGRect(x: 40, y: 60, width: 560, height: 400))!
        let inline = InlineCaptureView(screenshot: base, crop: crop, selection: rect, size: CGSize(width: 1000, height: 700), appearance: style)
        inline.layout()
        try require(inline.canvas.layer?.cornerRadius == 28, "原位选区预览使用用户设置的圆角大小")
        inline.model.add(Mark(tool: .rectangle, start: CGPoint(x: 40, y: 40), end: CGPoint(x: 200, y: 150), color: .red, width: 4))
        let raw = inline.model.rendered()!, rawPNG = Raster.png(raw)
        let expected = try style.render(raw, pixelsPerPoint: CGFloat(base.width) / 1000)
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        var completions = 0; inline.onFinish = { completions += 1 }
        inline.complete(to: pasteboard)
        try require(pasteboard.data(forType: .png) == Raster.png(expected) && completions == 1, "原位标注完成复制使用同一美化渲染，PNG 保留透明阴影")
        try require(Raster.png(inline.model.rendered()!) == rawPNG && inline.selection == rect, "美化不改动选区、原图或标注坐标")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = root.appendingPathComponent("styled.png"), jpeg = root.appendingPathComponent("styled.jpg"), plain = root.appendingPathComponent("plain.jpg")
        try ScreenshotSaver.write(raw, to: png, appearance: style, pixelsPerPoint: CGFloat(base.width) / 1000)
        let pngData = try Data(contentsOf: png)
        try require(pngData == pasteboard.data(forType: .png), "PNG 保存与剪贴板的美化结果逐字节一致")
        try ScreenshotSaver.write(raw, to: jpeg, appearance: style, pixelsPerPoint: 2)
        try ScreenshotSaver.write(raw, to: plain)
        let jpegData = try Data(contentsOf: jpeg), plainData = try Data(contentsOf: plain)
        try require(jpegData == plainData && NSBitmapImageRep(data: jpegData)!.pixelsWide == raw.width, "JPEG 保持原始矩形和像素尺寸，不产生透明黑角或阴影留白")
    }

    @MainActor private static func checkSelectionToScrolling() throws {
        let base = DemoImage.make(), rect = CGRect(x: 30, y: 40, width: 280, height: 200)
        let crop = base.cropping(to: CGRect(x: 60, y: 80, width: 560, height: 400))!
        var starts = 0
        let inline = InlineCaptureView(screenshot: base, crop: crop, selection: rect, size: CGSize(width: 1000, height: 700), onStartScrolling: { _, _, _ in starts += 1 })
        let clipboardChange = NSPasteboard.general.changeCount
        try require(starts == 0, "普通框选只显示工具栏，不自动启动长截图")
        inline.startScrolling()
        try require(starts == 1 && inline.selection == rect && inline.model.image === crop, "点击长截图使用原选区和原始像素，不重新框选")
        try require(NSPasteboard.general.changeCount == clipboardChange, "切换长截图不会提前复制到剪贴板")
        inline.model.add(Mark(tool: .rectangle, start: .zero, end: CGPoint(x: 50, y: 50), color: .red, width: 4))
        inline.startScrolling()
        try require(starts == 1 && inline.model.marks.count == 1, "已有标注时保留内容，不静默丢弃并进入长截图")
        inline.model.undo(); inline.startScrolling()
        try require(starts == 2, "撤销标注后可以沿用选区开始长截图")
        inline.model.showingText = true; inline.startScrolling()
        try require(starts == 2, "输入文字时不会丢失输入并进入长截图")
        inline.model.showingText = false
        var finishSampling: ((NSColor?) -> Void)?
        inline.model.sampleColor { finishSampling = $0 }; inline.startScrolling()
        try require(starts == 2, "取色期间不能同时开启长截图")
        finishSampling?(nil)
        let unavailable = InlineCaptureView(screenshot: base, crop: crop, selection: rect, size: CGSize(width: 1000, height: 700), onStartScrolling: { _, _, _ in
            throw NSError(domain: "QingJieSmokeTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "显示器不可用"])
        })
        unavailable.startScrolling()
        try require(unavailable.selection == rect && unavailable.model.message.contains("显示器不可用"), "长截图准备失败会保留选区并显示重试原因")
    }

    @MainActor private static func checkMosaicStylesAndSampling() throws {
        let source = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 160, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let red = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), green = NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1)
        let blue = NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1), white = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
        for y in 0..<160 { for x in 0..<240 {
            source.setColor(y < 80 ? (x < 120 ? red : green) : (x < 120 ? blue : white), atX: x, y: y)
        } }
        let base = source.cgImage!, model = EditorModel(image: source.cgImage!)
        var mark = Mark(tool: .mosaic, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 230, y: 150), color: .black, width: 2)
        try require(model.mosaicStyle == .gaussian && mark.mosaicStyle == .gaussian, "新截图和新马赛克默认高斯模糊")
        func rendered(_ mark: Mark) -> NSBitmapImageRep { NSBitmapImageRep(cgImage: Raster.render(base: base, marks: [mark])!) }
        func rgb(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor {
            // colorAt labels encoded channels as calibrated RGB, even when the CGImage is tagged sRGB.
            let color = rep.colorAt(x: x, y: y)!
            return color.numberOfComponents >= 3 ? color : color.usingColorSpace(.deviceRGB)!
        }
        let mild = rendered(mark)
        let top = rgb(mild, 119, 25), bottom = rgb(mild, 119, 135)
        try require(top.redComponent > 0.1 && top.greenComponent > 0.1 && top.blueComponent < 0.03,
                    "高斯模糊在硬边缘形成平滑混色")
        try require(bottom.blueComponent > 0.9 && bottom.redComponent > 0.1,
                    "Core Image 的上下坐标与截图一致")
        mark.width = 12
        let strong = rendered(mark)
        try require(rgb(strong, 90, 25).greenComponent > rgb(mild, 90, 25).greenComponent + 0.1,
                    "增大高斯强度会扩大模糊范围")
        try require(rgb(strong, 5, 5).redComponent > 0.99 && rgb(strong, 5, 5).greenComponent < 0.01,
                    "高斯滤镜不会改变框选范围外像素")
        let sampleColor = NSColor(srgbRed: 0.2, green: 0.6, blue: 0.8, alpha: 0.2)
        mark.mosaicStyle = .solid; mark.color = sampleColor
        let solid = rendered(mark), covered = rgb(solid, 20, 20)
        try require(abs(covered.redComponent - 0.2) < 0.015 && abs(covered.greenComponent - 0.6) < 0.015 && abs(covered.blueComponent - 0.8) < 0.015 && covered.alphaComponent > 0.99,
                    "纯色遮挡使用当前自定义颜色，并强制完全不透明")
        mark.color = .black
        try require(rgb(rendered(mark), 200, 130).redComponent < 0.01, "选择黑色可以完全遮盖原图")
        let edgeSource = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40, bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<40 { for x in 0..<40 { edgeSource.setColor(white, atX: x, y: y) } }
        let edgeMark = Mark(tool: .mosaic, start: .zero, end: CGPoint(x: 40, y: 40), color: .red, width: 16)
        let edge = NSBitmapImageRep(cgImage: Raster.render(base: edgeSource.cgImage!, marks: [edgeMark])!)
        try require(rgb(edge, 0, 0).redComponent > 0.99 && rgb(edge, 0, 0).alphaComponent > 0.99,
                    "图片边缘的高斯模糊不产生黑边或透明边")
        for style in MosaicStyle.allCases { mark.mosaicStyle = style; model.add(mark) }
        let before = Raster.png(model.rendered()!)
        model.undo(); model.redo()
        try require(model.marks.map(\.mosaicStyle) == MosaicStyle.allCases && Raster.png(model.rendered()!) == before,
                    "三种样式保存在各自标注中，撤销重做保持成品")
        model.mosaicStyle = .pixelated; model.color = .systemYellow
        try require(Raster.png(model.rendered()!) == before, "更改下一次使用的样式和颜色不修改已有标注")

        var states: [Bool] = [], pending: ((NSColor?) -> Void)?
        model.onSamplingChange = { states.append($0) }
        model.sampleColor { pending = $0 }
        var duplicateOpened = false
        model.sampleColor { _ in duplicateOpened = true }
        try require(model.isSamplingColor && states == [true] && !duplicateOpened, "取色开始时隐藏截图遮罩，重复点击不会启动第二次取色")
        pending?(sampleColor)
        try require(!model.isSamplingColor && states == [true, false] && model.colorHex == "#3399CC" && model.color.alphaComponent == 1,
                    "取色完成后恢复截图并保留 sRGB 自定义颜色")
        let original = model.color
        model.sampleColor { $0(nil) }
        try require(!model.isSamplingColor && states == [true, false, true, false] && model.color == original,
                    "Esc 取消取色会恢复截图并保留原颜色")
    }

    @MainActor private static func checkInlineCaptureAndPermissionDrag() throws {
        try require(HotKeys.verifyDispatcherDelivery(), "Carbon 全局分发目标可接收本应用事件，并忽略其他签名（非物理按键测试）")
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        clipboard.writeObjects([InstalledApp.pasteboardItem()])
        let urls = clipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        try require(urls?.first == InstalledApp.url && InstalledApp.url.path == "/Applications/轻截.app", "授权拖拽载荷为固定安装位置的 app 文件 URL")
        let base = DemoImage.make()
        let crop = base.cropping(to: CGRect(x: 80, y: 70, width: 640, height: 440))!
        let inline = InlineCaptureView(screenshot: base, crop: crop, selection: CGRect(x: 40, y: 35, width: 320, height: 220),
                                       size: CGSize(width: 1000, height: 700))
        inline.layout()
        try require(inline.canvas.frame == inline.selection && inline.canvas.displayScale == 0.5, "标注画布保持原选区位置和 Retina 像素比例")
        inline.model.add(Mark(tool: .mosaic, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 240, y: 100), color: .red, width: 8))
        inline.model.add(Mark(tool: .arrow, start: CGPoint(x: 60, y: 190), end: CGPoint(x: 300, y: 300), color: .red, width: 6))
        inline.model.add(Mark(tool: .text, start: CGPoint(x: 250, y: 100), end: .zero, color: .black, width: 3, text: "屏幕内标注", fontSize: 26))
        let expected = Raster.png(inline.model.rendered()!)!
        var completions = 0, exported: Data?
        inline.onFinish = { completions += 1 }
        inline.onExport = { if case .copied(let image) = $0 { exported = Raster.png(image) } }
        inline.complete(to: clipboard)
        let data = clipboard.data(forType: .png)
        try require(data == expected && completions == 1, "屏幕内标注完成后复制合成图，再触发关闭回调")
        let decoded = data.flatMap { NSBitmapImageRep(data: $0) }
        try require(decoded?.pixelsWide == 640 && decoded?.pixelsHigh == 440, "剪贴板仅含原始选区，不含遮罩边框或工具栏")
        try require(exported == expected, "屏幕截图完成传递最终成品，用于静默记录历史")
        inline.model.undo(); inline.model.redo()
        try require(Raster.png(inline.model.rendered()!) == expected, "屏幕内撤销重做保留马赛克箭头和文字成品")
    }

    @MainActor private static func checkCaptureResizing() throws {
        let base = DemoImage.make(), size = CGSize(width: CGFloat(base.width) / 2, height: CGFloat(base.height) / 2)
        let rect = CGRect(x: 100, y: 80, width: 300, height: 200)
        let crop = base.cropping(to: CGRect(x: 200, y: 160, width: 600, height: 400))!
        var scrollRect: CGRect?, scrollPixels: CGRect?, scrollSize: CGSize?
        let inline = InlineCaptureView(screenshot: base, crop: crop, selection: rect, size: size, onStartScrolling: { rect, pixels, crop in
            scrollRect = rect; scrollPixels = pixels; scrollSize = CGSize(width: crop.width, height: crop.height)
        })
        let host = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: true)
        host.isReleasedWhenClosed = false; host.contentView = inline
        defer { host.contentView = nil; host.close() }
        inline.layout()
        try require(inline.hitTest(inline.convert(CGPoint(x: 101, y: 81), to: inline.superview)) === inline.resizeHandles
                    && inline.hitTest(inline.convert(CGPoint(x: 250, y: 150), to: inline.superview)) === inline.canvas,
                    "截图四角优先接收调整操作，内部仍交给标注画布")
        inline.model.add(Mark(tool: .text, start: CGPoint(x: 80, y: 60), end: CGPoint(x: 80, y: 60), color: .red, width: 3, text: "保持位置"))
        let before = inline.model.snapshot
        inline.beginResize(.topLeft); inline.resize(to: CGPoint(x: 50, y: 40)); inline.endResize(); inline.layout()
        try require(inline.selection == CGRect(x: 50, y: 40, width: 350, height: 240) && inline.model.image.width == 700 && inline.model.image.height == 480,
                    "选区向外调整使用冻结原图，Retina 尺寸与工具栏同步")
        try require(inline.model.marks[0].start == CGPoint(x: 180, y: 140) && inline.canvas.displayScale == 0.5,
                    "调整截图四角后标注保持屏幕位置与大小")
        inline.model.undo()
        try require(inline.selection == rect && inline.model.image === before.image && inline.model.marks[0].start == before.marks[0].start,
                    "一次撤销同时恢复截图范围、像素和标注位置")
        inline.model.redo()
        try require(inline.model.image.width == 700 && inline.selection.minX == 50, "重做恢复调整后的截图范围")
        inline.beginResize(.bottomRight); inline.resize(to: CGPoint(x: 120, y: 100)); inline.endResize()
        try require(inline.model.marks.count == 1, "缩小截图只裁切显示，不删除范围外标注")
        inline.model.undo(); inline.model.undo(); inline.model.undo()
        try require(inline.model.marks.isEmpty && inline.selection == rect, "混合标注和选区调整的撤销顺序正确")
        inline.beginResize(.bottomRight); inline.resize(to: CGPoint(x: 450, y: 330)); inline.endResize()
        inline.startScrolling()
        try require(scrollRect == CGRect(x: 100, y: 80, width: 350, height: 250) && scrollPixels == CGRect(x: 200, y: 160, width: 700, height: 500)
                    && scrollSize == CGSize(width: 700, height: 500), "调整选区后长截图使用新的范围及首帧，未保留旧闭包坐标")
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        inline.complete(to: pasteboard)
        let exported = pasteboard.data(forType: .png).flatMap { NSBitmapImageRep(data: $0) }
        try require(exported?.pixelsWide == 700 && exported?.pixelsHigh == 500, "调整选区后复制按新像素范围导出")
    }

    @MainActor private static func checkCaptureEdgeDragging() throws {
        let image = DemoImage.make(), size = CGSize(width: image.width / 2, height: image.height / 2)
        let rect = CGRect(x: 100, y: 80, width: 300, height: 200)
        let inline = InlineCaptureView(screenshot: image, crop: image.cropping(to: CGRect(x: 200, y: 160, width: 600, height: 400))!,
                                       selection: rect, size: size)
        let host = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: true)
        host.isReleasedWhenClosed = false; host.contentView = inline
        defer { host.contentView = nil; host.close() }
        inline.layout()
        let handles = inline.resizeHandles
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: handles.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                              windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        }
        let gestures: [(CGPoint, CGPoint, CGRect)] = [
            (CGPoint(x: 220, y: 84), CGPoint(x: 290, y: 44), CGRect(x: 100, y: 40, width: 300, height: 240)),
            (CGPoint(x: 104, y: 170), CGPoint(x: 64, y: 190), CGRect(x: 60, y: 80, width: 340, height: 200)),
            (CGPoint(x: 396, y: 170), CGPoint(x: 436, y: 140), CGRect(x: 100, y: 80, width: 340, height: 200)),
            (CGPoint(x: 320, y: 276), CGPoint(x: 370, y: 316), CGRect(x: 100, y: 80, width: 300, height: 240))
        ]
        try require(gestures.allSatisfy { handles.hitTest(inline.convert($0.0, to: handles.superview)) === handles }
                    && handles.hitTest(CGPoint(x: 250, y: 150)) == nil,
                    "整条选区边线的窄范围可拖动，内部不拦截标注事件")
        handles.enabled = false
        try require(handles.hitTest(CGPoint(x: 220, y: 84)) == nil, "保存或取色时选区边线不抢占鼠标")
        handles.enabled = true
        handles.mouseDown(with: event(.leftMouseDown, CGPoint(x: 220, y: 84)))
        handles.mouseUp(with: event(.leftMouseUp, CGPoint(x: 220, y: 84)))
        try require(inline.selection == rect && inline.model.undoStack.isEmpty, "只点击边线附近不会跳动或增加撤销记录")
        inline.model.add(Mark(tool: .text, start: CGPoint(x: 80, y: 60), end: CGPoint(x: 80, y: 60), color: .red, width: 3, text: "固定位置"))
        let snapshot = inline.model.snapshot, undoCount = inline.model.undoStack.count
        for (start, end, expected) in gestures {
            handles.mouseDown(with: event(.leftMouseDown, start))
            handles.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)))
            handles.mouseDragged(with: event(.leftMouseDragged, end)); handles.mouseUp(with: event(.leftMouseUp, end))
            try require(inline.selection == expected && inline.model.image.width == Int(expected.width * 2)
                        && inline.model.image.height == Int(expected.height * 2) && inline.model.undoStack.count == undoCount + 1,
                        "边线拖动 \(start) → \(end) 保持单轴与 Retina 像素，一次拖动只记一次撤销")
            let mark = inline.model.marks[0]
            try require(expected.minX + mark.start.x / 2 == 140 && expected.minY + mark.start.y / 2 == 110,
                        "边线调整后已有文字保持原屏幕位置")
            inline.model.undo()
            try require(inline.selection == rect && inline.model.image === snapshot.image && inline.model.marks[0].start == snapshot.marks[0].start,
                        "撤销边线调整同时恢复选区、原图及标注坐标")
            inline.model.redo()
            try require(inline.selection == expected, "重做边线拖动恢复调整后的范围")
            inline.model.undo(); inline.layout()
        }
    }

    @MainActor private static func checkDirectAnnotationEditing() throws {
        let model = EditorModel(image: DemoImage.make()), canvas = AnnotationCanvas(model: model)
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600); canvas.displayScale = 0.5
        let host = NSWindow(contentRect: canvas.frame, styleMask: .borderless, backing: .buffered, defer: true)
        host.isReleasedWhenClosed = false; host.contentView = canvas
        defer { host.contentView = nil; host.close() }
        func near(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 0.001 }
        func nearRect(_ a: CGRect, _ b: CGRect) -> Bool {
            near(a.origin, b.origin) && abs(a.width - b.width) < 0.001 && abs(a.height - b.height) < 0.001
        }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            let local = CGPoint(x: canvas.imageFrame.minX + point.x * canvas.displayScale, y: canvas.imageFrame.minY + point.y * canvas.displayScale)
            return NSEvent.mouseEvent(with: type, location: canvas.convert(local, to: nil), modifierFlags: [], timestamp: 0,
                                     windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        }
        func drag(_ from: CGPoint, _ to: CGPoint) {
            canvas.mouseDown(with: event(.leftMouseDown, from)); canvas.mouseDragged(with: event(.leftMouseDragged, to)); canvas.mouseUp(with: event(.leftMouseUp, to))
        }
        let box = Mark(tool: .rectangle, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 400, y: 300), color: .red, width: 4)
        let arrow = Mark(tool: .arrow, start: CGPoint(x: 500, y: 100), end: CGPoint(x: 700, y: 300), color: .blue, width: 4)
        let text = Mark(tool: .text, start: CGPoint(x: 200, y: 500), end: CGPoint(x: 200, y: 500), color: .red, width: 4, text: "直接拖动", fontSize: 32)
        let pen = Mark(tool: .pen, start: CGPoint(x: 500, y: 500), end: CGPoint(x: 700, y: 600), points: [CGPoint(x: 500, y: 500), CGPoint(x: 600, y: 550), CGPoint(x: 700, y: 600)], color: .red, width: 5)
        try require(box.contains(CGPoint(x: 250, y: 100), tolerance: 5) && !box.contains(CGPoint(x: 250, y: 200), tolerance: 5),
                    "矩形只命中边线，空心内部不会抢走绘制操作")
        try require(arrow.contains(CGPoint(x: 600, y: 200), tolerance: 5) && !arrow.contains(CGPoint(x: 500, y: 280), tolerance: 5)
                    && pen.contains(CGPoint(x: 600, y: 550), tolerance: 5) && !pen.contains(CGPoint(x: 510, y: 590), tolerance: 5),
                    "箭头与画笔按实际线段命中，不使用整个外接矩形")
        model.marks = [box, arrow, text, pen]; model.tool = .mosaic
        drag(CGPoint(x: 250, y: 100), CGPoint(x: 280, y: 130))
        try require(model.tool == .mosaic && model.marks.count == 4 && near(model.marks[0].start, CGPoint(x: 130, y: 130)),
                    "马赛克工具状态下可直接拖动既有矩形，无需切换选择工具")
        model.undo(); model.redo(); model.undo()
        try require(model.marks[0].start == box.start && model.undoStack.isEmpty, "整次标注拖动只生成一个撤销步骤")
        model.tool = .text; drag(CGPoint(x: 600, y: 200), CGPoint(x: 650, y: 230))
        try require(near(model.marks[1].start, CGPoint(x: 550, y: 130)) && !model.showingText, "文字工具下触碰箭头会拖动箭头，不弹文字输入")
        model.tool = .rectangle; drag(CGPoint(x: 225, y: 515), CGPoint(x: 275, y: 545))
        try require(near(model.marks[2].start, CGPoint(x: 250, y: 530)), "绘图工具下可直接拖动文字")
        drag(CGPoint(x: 600, y: 550), CGPoint(x: 620, y: 570))
        try require(near(model.marks[3].points[1], CGPoint(x: 620, y: 570)), "直接拖动自由画笔会平移整条路径")
        canvas.mouseDown(with: event(.leftMouseDown, CGPoint(x: 250, y: 100))); canvas.mouseUp(with: event(.leftMouseUp, CGPoint(x: 250, y: 100)))
        let steps = model.undoStack.count
        try require(model.selectedID == box.id, "点击矩形边线即可进入带四角控制点的编辑状态")
        drag(CGPoint(x: 400, y: 300), CGPoint(x: 450, y: 350))
        try require(nearRect(model.marks[0].rect, CGRect(x: 100, y: 100, width: 350, height: 250)) && model.undoStack.count == steps + 1,
                    "拖动矩形角点改变大小并生成单个撤销步骤")
        model.undo(); try require(model.marks[0].rect == box.rect, "矩形只改右下角也可完整撤销")
        model.selectedID = nil
        drag(CGPoint(x: 200, y: 180), CGPoint(x: 300, y: 240))
        try require(model.marks.count == 5 && nearRect(model.marks.last!.rect, CGRect(x: 200, y: 180, width: 100, height: 60)),
                    "已有矩形的空白内部可以继续画新矩形")
        canvas.mouseDown(with: event(.leftMouseDown, CGPoint(x: 250, y: 100)))
        canvas.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 280, y: 150)))
        try require(canvas.cancelInteraction() && model.marks[0].rect == box.rect, "Esc 中断拖动恢复原标注，不留下半次编辑")
    }

    @MainActor private static func checkInAppWindowSelection() throws {
        let width = 1000, height = 700, size = CGSize(width: width, height: height)
        let panel = CGRect(x: 250, y: 160, width: 500, height: 340)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let gray: UInt8 = panel.contains(CGPoint(x: x, y: y)) ? 250 : 135, i = (y * width + x) * 4
            bytes[i] = gray; bytes[i + 1] = gray; bytes[i + 2] = gray
        } }
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let native = WindowSelectionTarget(id: 1, rect: CGRect(origin: .zero, size: size), name: "浏览器")
        let targets = InAppPanelDetector.enrich([native], image: image, localSize: size)
        let host = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: true)
        host.isReleasedWhenClosed = false; defer { host.contentView = nil; host.close() }
        let view = SelectionView(image: image, size: size, windowTargets: targets)
        host.contentView = view
        var result: CGRect?
        view.onFinish = { result = $0 }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                              windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        }
        func modifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: host.windowNumber,
                            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!
        }
        let point = CGPoint(x: 400, y: 300)
        view.mouseMoved(with: mouse(.mouseMoved, point))
        try require(view.selection == panel && result == nil, "图像识别的应用内弹窗在悬停时优先高亮，尚未完成截图")
        view.flagsChanged(with: modifiers(.option))
        try require(view.selection == native.rect, "鼠标不动按住 Option 即可切换到整个应用窗口")
        view.flagsChanged(with: modifiers([]))
        try require(view.selection == panel, "松开 Option 恢复弹窗吸附")
        view.mouseDown(with: mouse(.leftMouseDown, point)); view.mouseUp(with: mouse(.leftMouseUp, point))
        try require(result == panel, "单击应用内弹窗沿用普通截图的选区完成回调")
        view.mouseDown(with: mouse(.leftMouseDown, point)); view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 460, y: 380)))
        try require(result == CGRect(x: 400, y: 300, width: 60, height: 80), "从弹窗内部拖动仍可自由框选，不被吸附锁住")
        view.mouseMoved(with: mouse(.mouseMoved, CGPoint(x: 100, y: 100)))
        try require(view.selection == native.rect, "鼠标在弹窗外或没有明显面板时回退到应用窗口")
        let crop = image.cropping(to: panel)!
        let inline = InlineCaptureView(screenshot: image, crop: crop, selection: panel, size: size)
        inline.beginResize(.bottomRight); inline.resize(to: CGPoint(x: 800, y: 550)); inline.endResize()
        try require(inline.selection == CGRect(x: 250, y: 160, width: 550, height: 390), "应用内窗口选中后仍可拖动四角调整截图范围")
    }

    @MainActor private static func checkBrowserContentSelection() throws {
        let size = CGSize(width: 1000, height: 700)
        var bytes = [UInt8](repeating: 255, count: 1000 * 700 * 4)
        for y in 0..<700 { for x in 0..<1000 {
            var gray: UInt8 = y < 36 ? 210 : 255
            if y >= 44 && y < 76 && x >= 90 && x < 900 { gray = 236 }
            if y == 84 { gray = 220 }
            let i = (y * 1000 + x) * 4
            bytes[i] = gray; bytes[i + 1] = gray; bytes[i + 2] = gray
        } }
        let image = CGImage(width: 1000, height: 700, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4000,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let whole = CGRect(origin: .zero, size: size), content = CGRect(x: 0, y: 84, width: 1000, height: 616)
        let windows = WindowSelection.targets(from: [.init(id: 1, ownerPID: 1, frame: whole, name: "Chrome", bundleIdentifier: "com.google.Chrome")],
                                              display: whole, localSize: size, excludingPID: 2)
        let targets = InAppPanelDetector.enrich(windows, image: image, localSize: size)
        let host = NSWindow(contentRect: whole, styleMask: .borderless, backing: .buffered, defer: true)
        host.isReleasedWhenClosed = false; defer { host.contentView = nil; host.close() }
        let view = SelectionView(image: image, size: size, windowTargets: targets); host.contentView = view
        var result: CGRect?; view.onFinish = { result = $0 }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                              windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        }
        let point = CGPoint(x: 450, y: 350)
        view.mouseMoved(with: mouse(.mouseMoved, point))
        try require(view.selection == content && result == nil, "网页内悬停吸附内容区，自动排除标签栏与地址栏")
        view.mouseMoved(with: mouse(.mouseMoved, CGPoint(x: 450, y: 50)))
        try require(view.selection == whole, "鼠标移到浏览器顶部仍可截取整个窗口")
        view.mouseMoved(with: mouse(.mouseMoved, point))
        let option = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .option, timestamp: 0,
                                     windowNumber: host.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!
        view.flagsChanged(with: option)
        try require(view.selection == whole, "网页内容吸附时 Option 可临时选整窗")
        view.mouseDown(with: mouse(.leftMouseDown, point)); view.mouseUp(with: mouse(.leftMouseUp, point))
        try require(result == content, "单击网页内容进入同一原位标注流程")
        let inline = InlineCaptureView(screenshot: image, crop: image.cropping(to: content)!, selection: content, size: size)
        inline.beginResize(.topLeft); inline.resize(to: CGPoint(x: 10, y: 100)); inline.endResize()
        try require(inline.selection == CGRect(x: 10, y: 100, width: 990, height: 600), "网页内容选中后仍可调整四角")
    }

    @MainActor private static func checkWindowSelection() throws {
        let size = CGSize(width: 1000, height: 700), image = DemoImage.make()
        let front = WindowSelectionTarget(id: 2, rect: CGRect(x: 200, y: 150, width: 400, height: 300), name: "前方窗口")
        let back = WindowSelectionTarget(id: 1, rect: CGRect(x: 100, y: 80, width: 800, height: 550), name: "后方窗口")
        let host = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: true)
        host.isReleasedWhenClosed = false
        defer { host.contentView = nil; host.close() }
        let view = SelectionView(image: image, size: size, windowTargets: [front, back])
        host.contentView = view
        var results: [CGRect?] = []
        view.onFinish = { results.append($0) }
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, shift: Bool = false) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: x, y: y), to: nil),
                              modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: host.windowNumber,
                              context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        }
        func key(_ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                            windowNumber: host.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                            isARepeat: false, keyCode: code)!
        }
        view.mouseMoved(with: mouse(.mouseMoved, 300, 200))
        try require(view.selection == front.rect && results.isEmpty, "悬停高亮最前方窗口，不提前完成截图")
        view.mouseMoved(with: mouse(.mouseMoved, 120, 100))
        try require(view.selection == back.rect, "移到后方窗口露出区域时自动切换边界")
        view.mouseExited(with: mouse(.mouseMoved, 1100, 200))
        try require(view.selection == nil, "离开显示器清除旧的窗口高亮")
        view.mouseDown(with: mouse(.leftMouseDown, 300, 200))
        view.mouseDragged(with: mouse(.leftMouseDragged, 301, 201))
        view.mouseUp(with: mouse(.leftMouseUp, 302, 201))
        try require(results.count == 1 && results.last! == front.rect, "没有预先移动鼠标也能单击选窗口，轻微抖动不误判拖动")
        view.mouseDown(with: mouse(.leftMouseDown, 300, 200))
        view.mouseDragged(with: mouse(.leftMouseDragged, 460, 280))
        view.mouseMoved(with: mouse(.mouseMoved, 800, 500))
        view.mouseUp(with: mouse(.leftMouseUp, 480, 300))
        try require(results.last! == CGRect(x: 300, y: 200, width: 180, height: 100), "从窗口内部拖动立即转为自由框选并使用松开位置")
        view.mouseDown(with: mouse(.leftMouseDown, 500, 400))
        view.mouseDragged(with: mouse(.leftMouseDragged, 300, 280, shift: true))
        view.mouseUp(with: mouse(.leftMouseUp, 300, 280, shift: true))
        try require(results.last! == CGRect(x: 380, y: 280, width: 120, height: 120), "窗口上反向拖动加 Shift 仍能框选正方形")
        let before = results.count
        view.mouseDown(with: mouse(.leftMouseDown, 950, 650))
        view.mouseUp(with: mouse(.leftMouseUp, 950, 650))
        try require(results.count == before && view.selection == nil, "空白桌面单击不会截到旧窗口")
        view.mouseDown(with: mouse(.leftMouseDown, 950, 650))
        view.mouseUp(with: mouse(.leftMouseUp, 990, 690))
        try require(results.last! == CGRect(x: 950, y: 650, width: 40, height: 40), "没有候选窗口的桌面仍可自由框选")
        view.mouseMoved(with: mouse(.mouseMoved, 300, 200)); view.keyDown(with: key(36))
        try require(results.last! == front.rect, "Enter 可确认悬停中的窗口")
        view.allowsSelection = false
        let disabledCount = results.count
        view.mouseMoved(with: mouse(.mouseMoved, 300, 200)); view.mouseDown(with: mouse(.leftMouseDown, 300, 200))
        view.mouseUp(with: mouse(.leftMouseUp, 300, 200)); view.keyDown(with: key(36))
        try require(results.count == disabledCount && view.selection == nil, "选定后其他显示器不再高亮或接受竞争选区")
        view.keyDown(with: key(53))
        try require(results.count == disabledCount + 1 && results.last! == nil, "其他显示器上的 Esc 仍然可取消截图")
        let reselected = SelectionView(image: image, size: size, windowTargets: view.windowTargets)
        try require(reselected.windowTargets == [front, back] && reselected.selection == nil, "重新框选保留冻结窗口顺序，清除上次选区")
    }

    @MainActor private static func checkShortcutRecorder() throws {
        func event(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                            context: nil, characters: "p", charactersIgnoringModifiers: "p", isARepeat: repeatKey, keyCode: code)!
        }
        let button = ShortcutRecorderButton()
        var received: [CaptureShortcut?] = [], cancels = 0
        button.onValue = { received.append($0) }; button.onCancel = { cancels += 1 }
        button.recording = true
        defer { button.recording = false }
        button.receive(event(35, modifiers: [.control, .option, .capsLock]))
        try require(received.last! == CaptureShortcut(keyCode: 35, modifiers: [.control, .option]), "快捷键录入保留真实键码并过滤 Caps Lock")
        button.receive(event(35, modifiers: [.control, .option], repeatKey: true))
        try require(received.count == 1, "按住按键不会重复保存快捷键")
        button.receive(event(53))
        try require(cancels == 1 && received.count == 1, "Esc 取消录入而不覆盖原快捷键")
        button.receive(event(51))
        try require(received.count == 2 && received[1] == nil, "Delete 可以清除快捷键")
        button.receive(event(51, modifiers: [.option]))
        try require(received.last! == CaptureShortcut(keyCode: 51, modifiers: [.option]), "带修饰键的 Delete 作为组合录入")
        button.recording = false
        button.receive(event(35, modifiers: [.control, .option]))
        try require(received.count == 3, "结束录入后停止接收快捷键输入")

        button.recording = true
        let flags = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [.control, .command], timestamp: 0,
                                     windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55)!
        button.flagsChanged(with: flags)
        try require(button.title == "⌃⌘ + …" && received.count == 3, "只按 Control Command 会显示已按修饰键，不保存空组合")
        button.keyDown(with: event(0, modifiers: [.control, .command]))
        try require(received.count == 4 && received.last! == CaptureShortcut(keyCode: 0, modifiers: [.control, .command]), "直接 keyDown 入口支持 Control Command A")
        let handled = button.performKeyEquivalent(with: event(0, modifiers: [.control, .command]))
        try require(handled && received.count == 5, "Command 组合的菜单按键入口交给录入框处理")
        button.recording = false
        button.flagsChanged(with: flags)
        try require(button.title == button.idleTitle && received.count == 5, "取消录入后清除修饰键预览并停止接收")
    }

    private static func recoveryFrame(offset: Int, blank: Int = 0) -> CGImage {
        let width = 320, height = 640
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<(height - blank) { for x in 0..<width {
            let value = UInt64((offset + y) / 3 + 7129) &* 6364136223846793005 &+ UInt64(x / 5 + 1) &* 1442695040888963407
            let level = UInt8(20 + (value ^ (value >> 33)) % 220), index = (y * width + x) * 4
            bytes[index] = level; bytes[index + 1] = level; bytes[index + 2] = level
        } }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    @MainActor private static func checkScrollRecovery() async throws {
        let worker = try ScrollCaptureWorker(first: recoveryFrame(offset: 600))
        _ = try await worker.observe(recoveryFrame(offset: 800), now: 0)
        let reverse = try await worker.observe(recoveryFrame(offset: 700), now: 0.2)
        let farAbove = try await worker.observe(recoveryFrame(offset: 0), now: 0.4)
        try require(reverse.outcome == .backwards && farAbove.outcome == .backwards && farAbove.height == 840, "短暂上滑和已识别后的大幅回看不会追加或变为断层警报")
        _ = try await worker.observe(recoveryFrame(offset: 800), now: 0.6)
        let resumed = try await worker.observe(recoveryFrame(offset: 900), now: 0.8)
        try require(resumed.outcome == .appended(100) && resumed.height == 940, "回到最远位置后自动接续，只追加新内容")
        let bounce = recoveryFrame(offset: 924, blank: 24)
        let transient = try await worker.observe(bounce, now: 1)
        let shortHold = try await worker.observe(bounce, now: 1.3)
        let returned = try await worker.observe(recoveryFrame(offset: 900), now: 1.5)
        try require(transient.outcome == .settling && shortHold.outcome == .settling && returned.outcome == .unchanged && returned.height == 940, "底部回弹的临时空白不写入长图，回弹结束自动恢复")
        _ = try await worker.observe(bounce, now: 2)
        let realPadding = try await worker.observe(bounce, now: 2.8)
        try require(realPadding.outcome == .appended(24), "持续稳定的真实页尾留白仍可正常采集")
        var completed: CGImage?
        let session = try ScrollCaptureSession(first: recoveryFrame(offset: 600), captureFrame: { recoveryFrame(offset: 500) }, onComplete: { completed = $0 })
        session.finish()
        for _ in 0..<75 {
            if completed != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try require(completed != nil && Raster.png(completed!) == Raster.png(recoveryFrame(offset: 600)), "上滑后点击完成直接输出已捕获内容，不要求用户回到末端")
    }

    @MainActor static func runWorkerChecks() async throws {
        try await checkScrollRecovery()
        let historyRoot = FileManager.default.temporaryDirectory.appendingPathComponent("QingJie-long-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: historyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: historyRoot) }
        let history = AppState(historyDirectory: historyRoot.appendingPathComponent("Copied"))
        let clipboard = NSPasteboard.withUniqueName(); defer { clipboard.releaseGlobally() }
        let appearance = ScreenshotAppearance(roundedCorners: true, shadow: true, cornerRadius: 30,
                                              shadowBlur: 18, shadowOffset: 9, shadowOpacity: 0.4), sourceImage = recoveryFrame(offset: 0)
        var decorated: CGImage?
        let session = try ScrollCaptureSession(first: sourceImage, appearance: appearance, pixelsPerPoint: 2,
                                              captureFrame: { sourceImage }, onComplete: {
            decorated = $0
            if let image = $0, ClipboardImage.write(image, to: clipboard) { history.remember(.copied(image)) }
        })
        session.state.paused = true; session.finish()
        for _ in 0..<75 {
            if decorated != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let expected = try appearance.render(sourceImage, pixelsPerPoint: 2)
        try require(decorated != nil && Raster.png(decorated!) == Raster.png(expected) && session.state.width == sourceImage.width,
                    "长截图完成时统一添加一次圆角和阴影，采集预览仍保留原始尺寸")
        let recordedLong = try history.history.first.map { try Data(contentsOf: $0.url) }
        try require(history.history.count == 1 && recordedLong == clipboard.data(forType: .png), "长截图完成复制后历史与最终剪贴板成品一致")
        let cancelled = try ScrollCaptureSession(first: sourceImage, captureFrame: { sourceImage }, onComplete: {
            if let image = $0 { history.remember(.copied(image)) }
        })
        cancelled.cancel()
        try require(history.history.count == 1, "取消长截图不追加历史")
        let savedHistory = AppState(historyDirectory: historyRoot.appendingPathComponent("Saved"))
        var pendingSave: ((ScreenshotSaver.Outcome) -> Void)?
        let saving = try ScrollCaptureSession(first: sourceImage, appearance: appearance, pixelsPerPoint: 2,
                                             captureFrame: { sourceImage }, onSaved: { savedHistory.remember(.saved($0)) }, onComplete: { _ in })
        saving.state.paused = true
        saving.finish(saveAs: true) { _, callback in pendingSave = callback }
        for _ in 0..<75 {
            if pendingSave != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try require(pendingSave != nil && savedHistory.history.isEmpty, "长截图保存面板等待期间不提前写入历史")
        pendingSave?(.cancelled)
        saving.finish(saveAs: true) { _, callback in callback(.failed("测试写入失败")) }
        try require(savedHistory.history.isEmpty && !saving.state.finishing, "长截图取消保存及写入失败后仍可重试，不生成历史")
        let savedLong = historyRoot.appendingPathComponent("long.png")
        try ScreenshotSaver.write(sourceImage, to: savedLong, appearance: appearance, pixelsPerPoint: 2)
        saving.finish(saveAs: true) { _, callback in callback(.saved(savedLong)) }
        let savedLongData = try Data(contentsOf: savedLong)
        let savedLongHistoryData = try savedHistory.history.first.map { try Data(contentsOf: $0.url) }
        try require(savedHistory.history.count == 1 && savedLongHistoryData == savedLongData, "长截图另存为重试成功只记录一次实际美化成品")
        let source = DemoChromeScrollSource()
        let first = source.frame()
        let worker = try ScrollCaptureWorker(first: first)
        source.advance()
        let moving = try await worker.observe(source.frame())
        try require(moving.outcome == .appended(390), "自然滚动首个变化帧直接累计，无需静止重复帧")
        source.advance()
        let movingAgain = try await worker.observe(source.frame())
        try require(movingAgain.outcome == .appended(390), "连续变化的下一帧继续累计")
        source.advance()
        let finalMoving = try await worker.observe(source.frame(), requireStable: true)
        try require(finalMoving.outcome == nil && finalMoving.count == 3, "完成时移动末帧先等待稳定")
        let finalStable = try await worker.observe(source.frame(), requireStable: true)
        try require(finalStable.outcome == .appended(390), "完成时稳定末帧可正确补入")
        let bottom = try await worker.observe(source.frame(), requireStable: true)
        try require(bottom.outcome == .unchanged && bottom.count == 4, "完成时重复末帧不会累计两次")
        let animated = DemoChromeScrollSource(animatesSidebars: true)
        let automaticWorker = try ScrollCaptureWorker(first: animated.frame())
        animated.advance()
        let autoUpdate = try await automaticWorker.observe(animated.frame())
        try require(autoUpdate.outcome == .appended(390) && autoUpdate.motionRecognized, "实际采样流程自动触发运动识别，无需指定范围")
        _ = try await automaticWorker.observe(animated.frame(), requireStable: true)
        let settled = try await automaticWorker.observe(animated.frame(), requireStable: true)
        try require(settled.outcome == .unchanged, "完成时忽略内容区外持续变化的侧栏")
    }
}
