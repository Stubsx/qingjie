import AppKit
import SwiftUI
import QingJieCore

struct ScrollUpdate {
    let outcome: StitchOutcome?
    let count: Int
    let height: Int
    let width: Int
    let region: CGRect
    let layoutLocked: Bool
    let motionRecognized: Bool
    let preview: CGImage?
}

/// Matching and composition run away from the main actor so drawing and scrolling remain responsive.
actor ScrollCaptureWorker {
    let stitcher: VerticalStitcher
    var lastSample: ScrollFingerprint?
    private var stableSince: TimeInterval?
    private var reviewingEarlier = false
    private var waitingForTail = false
    private var unmatchedSince: TimeInterval?
    var canFinishWithoutNewFrame: Bool { reviewingEarlier || waitingForTail }
    init(first: CGImage, contentRegion: CGRect? = nil, memoryBudget: Int? = nil) throws {
        stitcher = try VerticalStitcher(first: first, contentRegion: contentRegion, memoryBudget: memoryBudget)
    }
    func observe(_ image: CGImage, requireStable: Bool = false, focusPoint: CGPoint? = nil,
                 now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> ScrollUpdate {
        // During scrolling, confident overlap is enough. Only completion needs a settled frame.
        guard let content = image.cropping(to: stitcher.scrollingRegion) else { throw StitchError.invalidRegion }
        let sample = try ScrollFingerprint(image: content)
        let stable = lastSample.map { $0.distance(to: sample) < 0.65 } ?? false
        if !stable || stableSince == nil { stableSince = now }
        lastSample = sample
        if requireStable && !stable { return try snapshot(outcome: nil, includePreview: false) }
        let previousHeight = stitcher.totalHeight
        var result = try stitcher.append(image, focusPoint: focusPoint,
                                        allowQuietTail: stable && now - (stableSince ?? now) >= 0.65)
        switch result {
        case .backwards: reviewingEarlier = true; waitingForTail = false; unmatchedSince = nil
        case .settling: waitingForTail = true; unmatchedSince = nil
        case .noOverlap where reviewingEarlier: result = .backwards
        case .noOverlap:
            if unmatchedSince == nil { unmatchedSince = now }
            if now - (unmatchedSince ?? now) < 0.9 { result = .settling }
        case .appended, .unchanged: reviewingEarlier = false; waitingForTail = false; unmatchedSince = nil
        default: break
        }
        let changed: Bool
        if case .appended = result { changed = true } else { changed = false }
        return try snapshot(outcome: result, includePreview: changed || previousHeight != stitcher.totalHeight)
    }
    func snapshot(outcome: StitchOutcome? = nil, includePreview: Bool = true) throws -> ScrollUpdate {
        ScrollUpdate(outcome: outcome, count: stitcher.frameCount, height: stitcher.totalHeight,
                     width: stitcher.width, region: stitcher.scrollingRegion, layoutLocked: stitcher.layoutLocked,
                     motionRecognized: stitcher.usesMotionRecognition,
                     preview: includePreview ? try preview() : nil)
    }
    func resetStability() { lastSample = nil; stableSince = nil }
    func compose() throws -> CGImage { try stitcher.compose() }
    var prefersFileExport: Bool { stitcher.prefersFileExport }
    func exportPNG(appearance: ScreenshotAppearance, pixelsPerPoint: CGFloat) throws -> ScrollPNGFile {
        try stitcher.exportPNG(appearance: appearance, pixelsPerPoint: pixelsPerPoint) { try Task.checkCancellation() }
    }
    func save(to url: URL, appearance: ScreenshotAppearance, pixelsPerPoint: CGFloat) throws {
        try Task.checkCancellation()
        switch ScreenshotFileFormat.forURL(url) {
        case .pdf: try stitcher.exportPDF(to: url) { try Task.checkCancellation() }
        case .png:
            let file = try exportPNG(appearance: appearance, pixelsPerPoint: pixelsPerPoint)
            try Task.checkCancellation(); try ScreenshotSaver.copyFile(file.url, to: url)
        case .jpeg:
            try ScreenshotSaver.write(stitcher.compose(), to: url)
        }
    }
    func preview() throws -> CGImage { try stitcher.preview(maximumHeight: 4096, maximumWidth: 640) }
}

@MainActor final class ScrollCaptureState: ObservableObject {
    @Published var count = 1
    @Published var height: Int
    @Published var paused = false
    @Published var finishing = false
    @Published var atLimit = false
    @Published var warning = false
    @Published var note = "轻轻向下滚动，自动识别内容区并累计长图。"
    @Published var selectingRegion = false
    @Published var layoutNote = "图像识别已就绪 · 自动区分正文与固定区域"
    @Published var manualRegion = false
    @Published var preview: NSImage?
    @Published var width: Int
    let isDemo: Bool
    var onPause: (() -> Void)?
    var onFinish: (() -> Void)?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    var onAdvance: (() -> Void)?
    var onSelectRegion: (() -> Void)?
    init(first: CGImage, isDemo: Bool) { width = first.width; height = first.height; self.isDemo = isDemo }
}

@MainActor final class ScrollCaptureSession {
    let state: ScrollCaptureState
    private var worker: ScrollCaptureWorker
    private let captureFrame: () async throws -> CGImage
    private let captureFocus: () -> CGPoint?
    private var lastFocus: CGPoint?
    private let onComplete: (CGImage?) -> Void
    private let onSaved: (URL) -> Void
    private let onCopiedPNG: ((URL) -> Bool)?
    private let saver = ScreenshotSaver()
    private var readyImage: CGImage?
    private var readyPNG: ScrollPNGFile?
    private var readyForSaving = false
    private var sampling: Task<Void, Never>?
    private var finishingTask: Task<Void, Never>?
    private var panel: NSPanel?
    private var previewMaximumFrame: CGRect?
    private var border: NSPanel?
    private var closed = false
    private var regionPicker: NSWindow?
    private var regionTask: Task<Void, Never>?
    private var screen: NSScreen?
    private var captureOutline: CGRect?
    private let sourceSize: CGSize
    private let appearance: ScreenshotAppearance
    private let pixelsPerPoint: CGFloat

    init(first: CGImage, isDemo: Bool = false, appearance: ScreenshotAppearance = .init(), pixelsPerPoint: CGFloat = 1,
         memoryBudget: Int? = nil,
         captureFrame: @escaping () async throws -> CGImage,
         captureFocus: @escaping () -> CGPoint? = { nil }, onSaved: @escaping (URL) -> Void = { _ in },
         onCopiedPNG: ((URL) -> Bool)? = nil,
         onComplete: @escaping (CGImage?) -> Void) throws {
        sourceSize = CGSize(width: first.width, height: first.height)
        self.appearance = appearance; self.pixelsPerPoint = pixelsPerPoint
        state = ScrollCaptureState(first: first, isDemo: isDemo)
        worker = try ScrollCaptureWorker(first: first, memoryBudget: memoryBudget)
        self.captureFrame = captureFrame; self.captureFocus = captureFocus; self.onComplete = onComplete; self.onSaved = onSaved
        self.onCopiedPNG = onCopiedPNG
        state.onPause = { [weak self] in self?.togglePause() }
        state.onFinish = { [weak self] in self?.finish() }
        state.onSave = { [weak self] in self?.finish(saveAs: true) }
        state.onCancel = { [weak self] in self?.cancel() }
        state.onSelectRegion = { [weak self] in self?.selectContentRegion() }
    }

    /// Offscreen rendering for local visual verification without accessing the user's screen.
    static func renderHUDPreview(first: CGImage, preview: CGImage? = nil) -> CGImage? {
        let state = ScrollCaptureState(first: first, isDemo: true)
        state.preview = NSImage(cgImage: preview ?? first, size: .zero)
        let view = NSHostingView(rootView: ScrollCaptureHUD(state: state))
        let height = min(680, 152 + ceil(292 * CGFloat(first.height) / CGFloat(first.width)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        view.layoutSubtreeIfNeeded()
        defer { window.close() }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.cgImage
    }

    func start(screen: NSScreen, selection: CGRect?) {
        self.screen = screen
        let visible = CGRect(x: 0, y: screen.frame.maxY - screen.visibleFrame.maxY,
                             width: screen.visibleFrame.width, height: screen.visibleFrame.height)
            .offsetBy(dx: screen.visibleFrame.minX - screen.frame.minX, dy: 0)
        let localSelection = selection ?? CGRect(origin: .zero, size: screen.frame.size)
        let previewFrame = InteractionGeometry.scrollPreviewFrame(selection: localSelection, bounds: visible)
        let size = previewFrame.size
        let hud = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        hud.title = state.isDemo ? "轻截 · 长截图演示" : "轻截 · 滚动长截图"
        hud.titleVisibility = .hidden; hud.titlebarAppearsTransparent = true
        hud.isOpaque = false; hud.backgroundColor = .clear
        hud.isReleasedWhenClosed = false; hud.hidesOnDeactivate = false; hud.isMovableByWindowBackground = true
        hud.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hud.contentView = NSHostingView(rootView: ScrollCaptureHUD(state: state))
        let origin = CGPoint(x: screen.frame.minX + previewFrame.minX, y: screen.frame.maxY - previewFrame.maxY)
        previewMaximumFrame = CGRect(origin: origin, size: size)
        if let selection {
            let rect = CGRect(x: screen.frame.minX + selection.minX, y: screen.frame.maxY - selection.maxY,
                              width: selection.width, height: selection.height)
            captureOutline = rect
            let outline = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            outline.isReleasedWhenClosed = false; outline.isOpaque = false; outline.backgroundColor = .clear
            outline.hasShadow = false; outline.ignoresMouseEvents = true; outline.hidesOnDeactivate = false
            outline.level = .screenSaver; outline.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let dimming = ScrollCaptureBorder(frame: CGRect(origin: .zero, size: screen.frame.size))
            dimming.selection = selection
            outline.contentView = dimming; outline.orderFrontRegardless(); border = outline
        }
        hud.setFrameOrigin(origin); panel = hud; resizePreview(); hud.orderFrontRegardless()
        if state.isDemo { hud.makeKeyAndOrderFront(nil) }
        beginSampling()
    }

    private func beginSampling() {
        sampling?.cancel()
        sampling = Task { [weak self] in
            guard let self else { return }
            if let preview = try? await worker.preview() { state.preview = NSImage(cgImage: preview, size: .zero) }
            while !Task.isCancelled && !closed {
                if !state.paused && !state.finishing {
                    do {
                        let image = try await captureFrame()
                        guard !Task.isCancelled, !closed else { return }
                        let update = try await worker.observe(image, focusPoint: currentFocus())
                        guard !Task.isCancelled, !closed else { return }
                        apply(update)
                    } catch {
                        guard !Task.isCancelled, !closed else { return }
                        state.paused = true; state.warning = true
                        state.note = "捕获暂停：\(error.localizedDescription) 可完成已捕获部分。"
                    }
                }
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            }
        }
    }

    private func currentFocus() -> CGPoint? {
        if panel?.frame.contains(NSEvent.mouseLocation) != true, let point = captureFocus() { lastFocus = point }
        return lastFocus
    }

    private func apply(_ update: ScrollUpdate) {
        state.count = update.count; state.height = update.height; state.width = update.width
        if update.layoutLocked || state.manualRegion {
            state.layoutNote = state.manualRegion ? "手动内容区 · 只拼接框选范围" : (update.motionRecognized ? "已锁定滚动面板 · 独立变化的侧栏已排除" : "已自动锁定内容区 · 固定区域不重复拼接")
            if let outline = captureOutline {
                let region = update.region
                let rect = CGRect(x: outline.minX + region.minX / sourceSize.width * outline.width,
                                  y: outline.maxY - region.maxY / sourceSize.height * outline.height,
                                  width: region.width / sourceSize.width * outline.width,
                                  height: region.height / sourceSize.height * outline.height)
                if let screen, let dimming = border?.contentView as? ScrollCaptureBorder {
                    dimming.selection = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY,
                                               width: rect.width, height: rect.height)
                }
            }
        }
        if let preview = update.preview { state.preview = NSImage(cgImage: preview, size: .zero) }
        switch update.outcome {
        case .appended:
            readyImage = nil; readyPNG = nil; readyForSaving = false
            state.warning = false; state.note = "已衔接新画面。继续向下滚动，或点击完成。"
        case .unchanged:
            state.warning = false; state.note = "画面未变化。向下滚动即可自动识别和累计。"
        case .backwards:
            state.warning = false; state.note = "已保留捕获内容，新内容会自动接续。"
        case .settling:
            state.warning = false; state.note = "已保留捕获内容，新内容会自动接续。"
        case .noOverlap:
            state.warning = update.count > 1
            state.note = update.count == 1 ? "尚未识别到连续滚动，请在正文缓慢滚动；若已跳过一大段，请回滚一些。" : "未找到可靠衔接。请回滚一点，再缓慢向下滚动。"
        case .limitReached:
            state.atLimit = true; state.paused = true; state.warning = true
            state.note = StitchError.limitReached.localizedDescription
        case nil: break
        }
        resizePreview()
    }

    private func resizePreview() {
        guard let panel, let maximum = previewMaximumFrame else { return }
        let imageHeight = ceil((maximum.width - 28) * CGFloat(state.height) / CGFloat(max(1, state.width)))
        let controls: CGFloat = 152 + (state.warning ? 78 : 0)
        let height = min(maximum.height, max(260, imageHeight + controls))
        // Grow downward from the same top edge as the image becomes longer.
        let visible = screen?.visibleFrame ?? maximum
        let x = min(max(panel.frame.minX, visible.minX), visible.maxX - maximum.width)
        let top = min(max(panel.frame.maxY, visible.minY + height), visible.maxY)
        let frame = CGRect(x: x, y: top - height, width: maximum.width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func togglePause() {
        guard !state.finishing, !state.atLimit, !state.selectingRegion else { return }
        state.paused.toggle(); state.warning = false
        if !state.paused { readyImage = nil; readyPNG = nil; readyForSaving = false }
        state.note = state.paused ? "已暂停。恢复前请回到最后捕获的位置。" : "已继续，请缓慢向下滚动。"
        Task { await worker.resetStability() }
    }

    private func selectContentRegion() {
        guard !closed, !state.finishing, !state.selectingRegion, state.count == 1, let screen else { return }
        let wasPaused = state.paused
        state.selectingRegion = true; state.paused = true; sampling?.cancel()
        regionTask = Task { [weak self] in
            guard let self else { return }
            await sampling?.value
            do {
                // An in-flight match may have completed as the button was clicked. Preserve it.
                let latest = try await worker.snapshot()
                guard !closed else { return }
                apply(latest)
                guard latest.count == 1 else {
                    state.selectingRegion = false; state.paused = wasPaused
                    state.note = "已有内容拼接成功。要更改范围，请完成或取消后重新开始。"
                    beginSampling(); return
                }
                let first = try await captureFrame()
                guard !closed, !Task.isCancelled else { return }
                let scale = min(1, (screen.visibleFrame.width - 100) / CGFloat(first.width),
                                (screen.visibleFrame.height - 140) / CGFloat(first.height))
                let size = CGSize(width: CGFloat(first.width) * scale, height: CGFloat(first.height) * scale)
                let picker = CaptureOverlayWindow(contentRect: CGRect(origin: .zero, size: size),
                                                  styleMask: [.titled], backing: .buffered, defer: false)
                picker.title = "框选需要滚动的内容 · 松开应用 · Esc 取消框选"
                picker.isReleasedWhenClosed = false; picker.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
                picker.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                let view = SelectionView(image: first, size: size)
                view.instructions = "只框选滚动内容 · 避开动态侧栏"
                let previousApp = NSWorkspace.shared.frontmostApplication
                view.onFinish = { [weak self, weak view] rect in
                    guard let self, !closed else { return }
                    let region: CGRect?
                    if let rect {
                        region = CaptureGeometry.pixelRect(selection: rect, bounds: size, pixels: CGSize(width: first.width, height: first.height))
                        guard let region, region.width >= 80, region.height >= 100 else {
                            view?.instructions = "范围太小，请至少框选 80 × 100 像素"
                            view?.needsDisplay = true; return
                        }
                    } else { region = nil }
                    regionPicker?.orderOut(nil); regionPicker?.close(); regionPicker = nil
                    if let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                        previousApp.activate(options: [])
                    }
                    regionTask = Task { [weak self] in
                        guard let self, !closed else { return }
                        do {
                            if let region {
                                worker = try ScrollCaptureWorker(first: first, contentRegion: region)
                                state.manualRegion = true; state.atLimit = false
                                let update = try await worker.snapshot()
                                guard !closed else { return }; apply(update)
                            }
                            state.selectingRegion = false; state.paused = wasPaused; state.warning = false
                            state.note = wasPaused ? "已暂停。恢复后开始向下滚动。" : "内容区已就绪，请缓慢自然向下滚动。"
                            beginSampling()
                        } catch { regionSelectionFailed(error) }
                    }
                }
                picker.contentView = view
                picker.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2))
                regionPicker = picker; NSApp.activate(ignoringOtherApps: true)
                picker.makeKeyAndOrderFront(nil); picker.makeFirstResponder(view)
            } catch { regionSelectionFailed(error) }
        }
    }

    private func regionSelectionFailed(_ error: Error) {
        guard !closed else { return }
        state.selectingRegion = false; state.paused = true; state.warning = true
        state.note = "无法指定内容区：\(error.localizedDescription)"
        beginSampling()
    }

    func finish(saveAs: Bool = false,
                usingExport exportPresenter: (([ScreenshotFileFormat], @escaping (URL) async throws -> Void, @escaping (ScreenshotSaver.Outcome) -> Void) -> Void)? = nil,
                usingPNG presentPNG: ((ScrollPNGFile, @escaping (ScreenshotSaver.Outcome) -> Void) -> Void)? = nil,
                using present: ((CGImage, @escaping (ScreenshotSaver.Outcome) -> Void) -> Void)? = nil) {
        guard !closed, !state.finishing, !state.selectingRegion else { return }
        let directSave = saveAs && presentPNG == nil && present == nil
        if !directSave, let readyPNG { state.finishing = true; deliverPNG(readyPNG, saveAs: saveAs, using: presentPNG); return }
        if !directSave, let readyImage { state.finishing = true; deliver(readyImage, saveAs: saveAs, using: present); return }
        let includeLastFrame = !state.paused && !readyForSaving
        state.finishing = true; state.note = "正在生成长截图…"; sampling?.cancel()
        finishingTask = Task { [weak self] in
            guard let self else { return }
            await sampling?.value
            do {
                if includeLastFrame {
                    // Flush a settled final frame. Never race the outstanding polling screenshot.
                    var lastOutcome: StitchOutcome?
                    for _ in 0..<7 {
                        let image = try await captureFrame()
                        guard !Task.isCancelled, !closed else { return }
                        let update = try await worker.observe(image, requireStable: true, focusPoint: currentFocus())
                        apply(update); lastOutcome = update.outcome
                        if let outcome = lastOutcome, outcome != .settling { break }
                        try await Task.sleep(nanoseconds: 220_000_000)
                    }
                    let mayKeepCaptured = await worker.canFinishWithoutNewFrame
                    if lastOutcome == nil && !mayKeepCaptured { throw CompletionError.unsettled }
                    if lastOutcome == .noOverlap { throw CompletionError.unmatched }
                }
                guard !closed else { return }
                readyForSaving = true
                if directSave {
                    let large = await worker.prefersFileExport
                    guard !closed, !Task.isCancelled else { return }
                    presentSave(large: large, using: exportPresenter)
                    return
                }
                if await worker.prefersFileExport {
                    let file = try await worker.exportPNG(appearance: appearance, pixelsPerPoint: pixelsPerPoint)
                    guard !Task.isCancelled, !closed else { return }
                    readyPNG = file; deliverPNG(file, saveAs: saveAs, using: presentPNG)
                    return
                }
                let image = try await worker.compose()
                guard !Task.isCancelled, !closed else { return }
                readyImage = image; deliver(image, saveAs: saveAs, using: present)
            } catch {
                guard !closed else { return }
                state.finishing = false; state.paused = true; state.warning = true
                state.note = "\(error.localizedDescription) 再点完成可保留已经捕获的部分。"
                state.onPause = nil
            }
        }
    }
    private func presentSave(large: Bool,
                             using present: (([ScreenshotFileFormat], @escaping (URL) async throws -> Void, @escaping (ScreenshotSaver.Outcome) -> Void) -> Void)?) {
        let formats: [ScreenshotFileFormat] = large ? [.png, .pdf] : [.png, .jpeg, .pdf]
        let worker = self.worker, appearance = self.appearance, pixelsPerPoint = self.pixelsPerPoint
        let writer: (URL) async throws -> Void = { url in
            try await worker.save(to: url, appearance: appearance, pixelsPerPoint: pixelsPerPoint)
        }
        panel?.orderOut(nil); border?.orderOut(nil)
        let handler: (ScreenshotSaver.Outcome) -> Void = { [weak self] outcome in
            guard let self, !closed else { return }
            switch outcome {
            case .saved(let url): close(); onSaved(url)
            case .cancelled, .failed:
                state.finishing = false; state.paused = true
                if case .failed(let reason) = outcome {
                    state.warning = true; state.note = "保存失败：\(reason) · 可重试另存为"
                } else {
                    state.warning = false; state.note = "长图已保留，可另存为、复制或继续采集。"
                }
                border?.orderFrontRegardless(); panel?.orderFrontRegardless(); beginSampling()
            }
        }
        if let present { present(formats, writer, handler) }
        else {
            saver.presentExport(formats: formats, onWriting: { [weak self] format in
                guard let self, !closed else { return }
                state.warning = false; state.note = format == .pdf ? "正在生成 PDF…" : "正在保存长截图…"
                border?.orderFrontRegardless(); panel?.orderFrontRegardless()
            }, writer: writer, completion: handler)
        }
    }
    private func deliverPNG(_ file: ScrollPNGFile, saveAs: Bool,
                            using present: ((ScrollPNGFile, @escaping (ScreenshotSaver.Outcome) -> Void) -> Void)?) {
        guard saveAs else {
            if onCopiedPNG?(file.url) == true { close() }
            else {
                state.finishing = false; state.paused = true; state.warning = true
                state.note = "复制未完成，截图已保留。可以重试复制或另存为。"
            }
            return
        }
        panel?.orderOut(nil); border?.orderOut(nil)
        let handler: (ScreenshotSaver.Outcome) -> Void = { [weak self] outcome in
            guard let self, !closed else { return }
            switch outcome {
            case .saved(let url): close(); onSaved(url)
            case .cancelled, .failed:
                state.finishing = false; state.paused = true
                if case .failed(let reason) = outcome {
                    state.warning = true; state.note = "保存失败：\(reason) · 可重试另存为"
                } else {
                    state.warning = false; state.note = "长图已保留，可另存为、复制或继续采集。"
                }
                border?.orderFrontRegardless(); panel?.orderFrontRegardless()
                beginSampling()
            }
        }
        if let present { present(file, handler) }
        else { saver.presentPNG(file, completion: handler) }
    }
    private func deliver(_ image: CGImage, saveAs: Bool,
                         using present: ((CGImage, @escaping (ScreenshotSaver.Outcome) -> Void) -> Void)?) {
        guard saveAs else {
            do {
                let output = try appearance.render(image, pixelsPerPoint: pixelsPerPoint)
                close(); onComplete(output)
            } catch {
                state.finishing = false; state.paused = true; state.warning = true
                state.note = "美化失败：\(error.localizedDescription)"
            }
            return
        }
        panel?.orderOut(nil); border?.orderOut(nil)
        let handler: (ScreenshotSaver.Outcome) -> Void = { [weak self] outcome in
            guard let self, !closed else { return }
            switch outcome {
            case .saved(let url): close(); onSaved(url)
            case .cancelled, .failed:
                state.finishing = false; state.paused = true
                if case .failed(let reason) = outcome {
                    state.warning = true; state.note = "保存失败：\(reason) · 可重试另存为"
                } else {
                    state.warning = false; state.note = "长图已保留，可另存为、复制或继续采集。"
                }
                border?.orderFrontRegardless(); panel?.orderFrontRegardless()
                beginSampling()
            }
        }
        if let present { present(image, handler) }
        else { saver.present(image, appearance: appearance, pixelsPerPoint: pixelsPerPoint, completion: handler) }
    }
    private enum CompletionError: LocalizedError {
        case unsettled, unmatched
        var errorDescription: String? {
            self == .unsettled ? "最后画面仍在滚动，未加入成品。" : "最后画面无法衔接，未加入成品。"
        }
    }
    func cancel() { guard !closed else { return }; close(); onComplete(nil) }
    private func close() {
        closed = true; sampling?.cancel(); finishingTask?.cancel(); regionTask?.cancel()
        saver.cancel()
        readyImage = nil; readyPNG = nil
        regionPicker?.orderOut(nil); regionPicker?.close(); regionPicker = nil
        panel?.orderOut(nil); panel?.close(); panel = nil
        border?.orderOut(nil); border?.close(); border = nil
    }
}

private struct ScrollCaptureHUD: View {
    @ObservedObject var state: ScrollCaptureState
    @State private var inspectingPreview = false
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(state.isDemo ? "长截图演示" : "长截图").font(.system(size: 14, weight: .semibold))
                Spacer()
                if state.finishing { Text("正在完成…").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
                else if state.paused { Text("已暂停").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
            }
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            if let image = state.preview {
                                Image(nsImage: image).resizable()
                                    .aspectRatio(CGFloat(state.width) / CGFloat(max(1, state.height)), contentMode: .fit)
                                    .frame(width: geometry.size.width)
                                    .accessibilityLabel("长截图实时预览")
                            }
                            Color.clear.frame(height: 1).id("latest")
                        }
                    }
                    .onChange(of: state.height) {
                        if !inspectingPreview { proxy.scrollTo("latest", anchor: .bottom) }
                    }
                    .onAppear { proxy.scrollTo("latest", anchor: .bottom) }
                }
            }
            .background(Theme.background).clipped()
            .onHover { inspectingPreview = $0 }
            Text("\(state.width) × \(state.height) px")
                .font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(Theme.secondary)
            if state.warning || state.finishing {
                Text(state.note).font(.system(size: 12)).foregroundStyle(state.warning ? .orange : Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 5) {
                Spacer(minLength: 0)
                if state.isDemo {
                    CaptureIconButton(kind: .advance, title: "示例向下滚动") { state.onAdvance?() }
                        .disabled(state.paused || state.finishing || state.selectingRegion)
                }
                CaptureIconButton(kind: state.paused ? .resume : .pause, title: state.paused ? "继续长截图" : "暂停长截图") { state.onPause?() }
                    .disabled(state.finishing || state.atLimit || state.onPause == nil || state.selectingRegion)
                CaptureIconButton(kind: .close, title: "取消长截图") { state.onCancel?() }
                CaptureIconButton(kind: .save, title: "另存为") { state.onSave?() }
                    .disabled(state.finishing || state.selectingRegion)
                CaptureIconButton(kind: .copy, title: "完成复制", help: "完成并复制到剪贴板", primary: true) { state.onFinish?() }
                    .disabled(state.finishing || state.selectingRegion)
            }
        }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(Theme.green).preferredColorScheme(.light)
    }
}

private final class ScrollCaptureBorder: NSView {
    var selection: CGRect = .zero { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let path = CGMutablePath(); path.addRect(bounds); path.addRect(selection)
        context.addPath(path); context.setFillColor(NSColor.black.withAlphaComponent(0.46).cgColor)
        context.fillPath(using: .evenOdd)
        context.setStrokeColor(NSColor(calibratedRed: 0.25, green: 0.75, blue: 0.48, alpha: 1).cgColor)
        context.setLineWidth(2); context.stroke(selection.insetBy(dx: -1, dy: -1))
    }
}
