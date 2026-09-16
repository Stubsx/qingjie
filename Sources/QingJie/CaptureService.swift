import AppKit
import ScreenCaptureKit
import OSLog
import QingJieCore

enum CaptureMode { case region, fullscreen }

@MainActor final class CaptureService {
    private var captureAppearance = ScreenshotAppearance()
    private let logger = Logger(subsystem: "com.local.qingjie", category: "Capture")
    private var overlays: [NSWindow] = []
    private var hiddenWindows: [NSWindow] = []
    private var scrollSession: ScrollCaptureSession?
    private(set) var busy = false
    private typealias ScrollStart = (NSScreen, CGRect, CGRect, CGImage) throws -> Void
    private let permissionHelp = PermissionHelpController()
    private var activationObserver: NSObjectProtocol?
    private var lastExternalApp: NSRunningApplication?
    private var returnApp: NSRunningApplication?
    private var startedFromApp = false
    private var recordingSelection: ((RecordingTarget?) -> Void)?
    private var recordingConfiguration = false
    private var captureID = UUID()

    init() {
        let current = NSWorkspace.shared.frontmostApplication
        if current?.processIdentifier != ProcessInfo.processInfo.processIdentifier { lastExternalApp = current }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                                object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self?.lastExternalApp = app
            }
        }
        permissionHelp.onPermissionChange = { [weak self] in self?.onPermissionChange?() }
    }
    private func prepareCapture() {
        captureAppearance = ScreenshotAppearanceSettings.shared.value
        permissionHelp.dismiss()
        let front = NSWorkspace.shared.frontmostApplication
        startedFromApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        returnApp = startedFromApp ? lastExternalApp : front
        busy = true
        captureID = UUID()
        // 「截图时隐藏轻截」关闭时不收起窗口，画面中保留轻截自身界面。
        hiddenWindows = (recordingSelection != nil || CaptureAppHidingSettings.shared.enabled)
            ? NSApp.windows.filter { $0.isVisible && $0.level != .statusBar && !($0 is NSPanel) }
            : []
        hiddenWindows.forEach { $0.orderOut(nil) }
    }
    var onPermissionChange: (() -> Void)?
    var onExport: ((ScreenshotOutput) -> Void)?

    func selectForRecording(service: RecordingService, _ completion: @escaping (RecordingTarget?) -> Void) {
        guard !busy else { completion(nil); return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            onPermissionChange?()
            guard CGPreflightScreenCaptureAccess() else { showPermissionHelp(); completion(nil); return }
            return selectForRecording(service: service, completion)
        }
        recordingConfiguration = false
        recordingUI = service
        recordingSelection = completion
        capture(.region)
    }

    private weak var recordingUI: RecordingService?

    func cancelRecordingSelection() {
        guard recordingSelection != nil || recordingConfiguration else { return }
        endCapture(completed: false)
    }
    func finishRecordingSelection() {
        guard recordingConfiguration else { return }
        endCapture(completed: true)
    }

    func capture(_ mode: CaptureMode) {
        guard !busy else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            onPermissionChange?()
            if !CGPreflightScreenCaptureAccess() { showPermissionHelp(); return }
            return capture(mode)
        }
        prepareCapture()
        let operationID = captureID
        let pointerScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        Task {
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                // 隐藏开启时排除本应用，避免残留画面；关闭时不排除，让轻截窗口进入截图。
                let excluded = (recordingSelection != nil || CaptureAppHidingSettings.shared.enabled)
                    ? content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                    : []
                let screens = mode == .fullscreen ? [pointerScreen].compactMap { $0 } : NSScreen.screens
                let windows = Self.snapshotWindows()
                var windowTargets: [CGDirectDisplayID: [WindowSelectionTarget]] = [:]
                var frames: [(NSScreen, CGImage)] = []
                for screen in screens {
                    guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                          let display = content.displays.first(where: { $0.displayID == id }) else { continue }
                    let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
                    let config = SCStreamConfiguration()
                    // CGDisplayPixelsWide returns logical dimensions on scaled Retina displays.
                    config.width = Int(screen.frame.width * screen.backingScaleFactor)
                    config.height = Int(screen.frame.height * screen.backingScaleFactor)
                    config.showsCursor = false; config.scalesToFit = true
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    frames.append((screen, image))
                    let targets = WindowSelection.targets(from: windows, display: CGDisplayBounds(id),
                                                          localSize: screen.frame.size,
                                                          excludingPID: ProcessInfo.processInfo.processIdentifier)
                    let size = screen.frame.size
                    windowTargets[id] = mode == .fullscreen || recordingSelection != nil ? targets : await Task.detached(priority: .userInitiated) {
                        InAppPanelDetector.enrich(targets, image: image, localSize: size)
                    }.value
                }
                guard !frames.isEmpty else { throw CaptureError.noDisplay }
                // Selection can be cancelled while ScreenCaptureKit is preparing snapshots.
                guard busy, operationID == captureID else { return }
                if recordingSelection != nil {
                    presentRecordingOverlays(frames, windowTargets: windowTargets)
                    return
                }
                presentOverlays(frames, windowTargets: windowTargets, selectFullScreen: mode == .fullscreen, scrolling: { [weak self] screen, selection, pixels, first in
                        try self?.startScrolling(screen: screen, selection: selection, pixels: pixels, first: first)
                    })
            } catch {
                guard busy, operationID == captureID else { return }
                let recorder = recordingUI
                finish(image: nil)
                if let recorder { recorder.selectionFailed(error); return }
                let alert = NSAlert(); alert.messageText = "暂时无法截屏"
                alert.informativeText = "\(error.localizedDescription)\n请确认系统设置中的「屏幕与系统音频录制」已允许轻截。如刚开启权限，请退出并重新打开轻截。"
                alert.addButton(withTitle: "好"); alert.runModal()
            }
        }
    }
    func showPermissionHelp() { permissionHelp.show() }

    private func presentRecordingOverlays(_ frames: [(NSScreen, CGImage)], windowTargets: [CGDirectDisplayID: [WindowSelectionTarget]]) {
        closeOverlays()
        NSApp.activate(ignoringOtherApps: true)
        for (screen, image) in frames {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            let window = CaptureOverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.acceptsMouseMovedEvents = true
            let view = SelectionView(image: image, size: screen.frame.size, windowTargets: windowTargets[id] ?? [])
            view.enableRecordingSelection()
            view.onTargetFinish = { [weak self, weak window] rect, windowID in
                guard let self, let window, let service = recordingUI, let completion = recordingSelection else { return }
                guard let rect else { endCapture(completed: false); return }
                let full = rect == CGRect(origin: .zero, size: screen.frame.size) && windowID == nil
                let name = windowID.flatMap { selectedID in windowTargets[id]?.first(where: { $0.id == selectedID })?.name }
                var target = RecordingTarget(displayID: id, displayFrame: screen.frame, scale: screen.backingScaleFactor,
                                             rect: rect, windowID: windowID,
                                             title: windowID != nil ? "窗口 · \(name ?? "所选窗口")" : (full ? "整个屏幕" : "自选区域"))
                if let windowID { target.windowSize = Self.snapshotWindows().first(where: { $0.id == windowID })?.frame.size }
                recordingSelection = nil
                recordingConfiguration = true
                for overlay in overlays {
                    if let selection = overlay.contentView as? SelectionView {
                        selection.allowsSelection = false
                        selection.subviews.forEach { $0.isHidden = true }
                        selection.instructions = "Esc 取消录屏"
                        selection.onTargetFinish = { [weak service] _, _ in service?.cancel() }
                    }
                }
                completion(target)
                let inline = InlineRecordingView(screenshot: image, size: screen.frame.size, target: target, service: service)
                window.contentView = inline
                inline.layoutSubtreeIfNeeded()
                window.makeKey(); window.makeFirstResponder(inline)
            }
            window.contentView = view; overlays.append(window)
            window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view); view.refreshHoverFromPointer()
        }
        overlays.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.makeKey()
    }

    private static func snapshotWindows() -> [CaptureWindow] {
        guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? NSNumber,
                  let pid = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = entry[kCGWindowLayer as String] as? NSNumber,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return CaptureWindow(id: id.uint32Value, ownerPID: pid.int32Value, frame: frame,
                                 layer: layer.intValue,
                                 alpha: (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                                 isOnScreen: (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                                 name: entry[kCGWindowOwnerName as String] as? String ?? "",
                                 bundleIdentifier: NSRunningApplication(processIdentifier: pid.int32Value)?.bundleIdentifier ?? "")
        }
    }

    private func presentOverlays(_ frames: [(NSScreen, CGImage)],
                                 windowTargets: [CGDirectDisplayID: [WindowSelectionTarget]] = [:],
                                 selectFullScreen: Bool = false, scrolling: ScrollStart? = nil) {
        closeOverlays()
        NSApp.activate(ignoringOtherApps: true)
        for (screen, image) in frames {
            let window = CaptureOverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.acceptsMouseMovedEvents = true; window.isOpaque = true
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            let view = SelectionView(image: image, size: screen.frame.size,
                                     windowTargets: displayID.flatMap { windowTargets[$0] } ?? [])
            view.onFinish = { [weak self, weak window] rect in
                guard let self, let window else { return }
                guard let rect else { finish(image: nil); return }
                guard let pixelRect = CaptureGeometry.pixelRect(selection: rect, bounds: screen.frame.size,
                                                                 pixels: CGSize(width: image.width, height: image.height)),
                      let crop = image.cropping(to: pixelRect) else { finish(image: nil); return }
                // Other displays stay dimmed but cannot start a competing selection.
                for overlay in overlays {
                    if let selectionView = overlay.contentView as? SelectionView {
                        selectionView.allowsSelection = false; selectionView.instructions = "Esc 取消截图"; selectionView.needsDisplay = true
                    }
                }
                let beginScroll: ((CGRect, CGRect, CGImage) throws -> Void)? = scrolling.map { handler in
                    { rect, pixels, crop in try handler(screen, rect, pixels, crop) }
                }
                let inline = InlineCaptureView(screenshot: image, crop: crop, selection: rect, size: screen.frame.size,
                                               appearance: captureAppearance, onStartScrolling: beginScroll)
                inline.model.onSamplingChange = { [weak self, weak window, weak inline] sampling in
                    guard let self, let window, overlays.contains(where: { $0 === window }) else { return }
                    if sampling { overlays.forEach { $0.orderOut(nil) } }
                    else {
                        overlays.forEach { $0.orderFrontRegardless() }
                        NSApp.activate(ignoringOtherApps: true)
                        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(inline?.canvas)
                    }
                }
                inline.onFinish = { [weak self] in self?.endCapture(completed: true) }
                inline.onExport = { [weak self] in self?.onExport?($0) }
                inline.onSavePanelChange = inline.model.onSamplingChange
                inline.onCancel = { [weak self] in self?.endCapture(completed: false) }
                inline.onReselect = { [weak self] in self?.presentOverlays(frames, windowTargets: windowTargets, scrolling: scrolling) }
                window.contentView = inline
                inline.needsLayout = true; inline.layoutSubtreeIfNeeded()
                window.makeKey(); window.makeFirstResponder(inline.canvas)
            }
            window.contentView = view; overlays.append(window)
            window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
            view.refreshHoverFromPointer()
        }
        overlays.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.makeKey()
        if selectFullScreen, let screen = frames.first?.0, let view = overlays.first?.contentView as? SelectionView {
            view.onFinish?(CGRect(origin: .zero, size: screen.frame.size))
        }
    }
    private func closeOverlays() {
        overlays.forEach { $0.orderOut(nil); $0.contentView = nil; $0.close() }; overlays.removeAll()
    }
    private func finish(image: CGImage?) {
        guard let image else { endCapture(completed: false); return }
        // Keep the generated result alive for retry if the pasteboard is temporarily unavailable.
        while !ClipboardImage.write(image) {
            let alert = NSAlert(); alert.messageText = "截图未能复制到剪贴板"
            alert.informativeText = "画面仍保留在本次截图中，可以重试。取消会丢弃本次结果。"
            alert.addButton(withTitle: "重试复制"); alert.addButton(withTitle: "取消截图")
            if alert.runModal() != .alertFirstButtonReturn { endCapture(completed: false); return }
        }
        endCapture(completed: true)
        onExport?(.copied(image))
    }
    private func finishSaving(_ url: URL) {
        endCapture(completed: true)
        onExport?(.saved(url))
    }
    private func endCapture(completed: Bool) {
        let cancelledSelection = recordingSelection
        recordingSelection = nil
        recordingConfiguration = false; recordingUI = nil
        closeOverlays()
        // A successful capture never opens or restores a workbench/editor window.
        if completed { hiddenWindows.forEach { $0.orderOut(nil) } }
        else if startedFromApp { hiddenWindows.forEach { $0.orderFront(nil) } }
        let visibleRegular = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) && $0.level != .statusBar }.count
        logger.notice("Capture ended. completed=\(completed) visibleRegularWindows=\(visibleRegular)")
        hiddenWindows.removeAll(); scrollSession = nil; busy = false
        if completed || !startedFromApp { returnApp?.activate(options: []) }
        returnApp = nil
        cancelledSelection?(nil)
    }
    func showInlineDemo() {
        guard !busy, let screen = NSScreen.main,
              let frozen = Self.demoFrame(DemoImage.make(), size: screen.frame.size) else { return }
        prepareCapture()
        presentOverlays([(screen, frozen)])
    }
    private static func demoFrame(_ content: CGImage, size: CGSize) -> CGImage? {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.94, alpha: 1).setFill(); CGRect(origin: .zero, size: size).fill()
        let rect = CaptureGeometry.fit(image: CGSize(width: content.width, height: content.height), in: size, inset: 90)
        NSImage(cgImage: content, size: .zero).draw(in: rect)
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
    private func startScrolling(screen: NSScreen, selection: CGRect, pixels: CGRect, first: CGImage) throws {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              CGFloat(first.width) == pixels.width, CGFloat(first.height) == pixels.height else { throw CaptureError.noDisplay }
        // The initial shareable-content snapshot predates the selection and HUD. When the
        // workbench was hidden, it may not contain our app at all. Resolve exclusion after
        // the scroll panels exist, otherwise their moving outline can enter later frames.
        // This exclusion is unconditional: even with「截图时隐藏轻截」off, the scroll HUD
        // and preview panels must never enter live frames.
        var scrollingFilter: SCContentFilter?
        let configuration = SCStreamConfiguration()
        let initialFrame = screen.frame, initialScale = screen.backingScaleFactor
        configuration.width = Int(initialFrame.width * initialScale); configuration.height = Int(initialFrame.height * initialScale)
        configuration.showsCursor = false; configuration.scalesToFit = true
        let session = try ScrollCaptureSession(first: first, appearance: captureAppearance,
                                              pixelsPerPoint: CGFloat(first.width) / selection.width, captureFrame: {
            guard let current = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id }),
                  current.frame == initialFrame, current.backingScaleFactor == initialScale else { throw CaptureError.displayChanged }
            if scrollingFilter == nil {
                let liveContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let ownApp = liveContent.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                guard !ownApp.isEmpty,
                      let liveDisplay = liveContent.displays.first(where: { $0.displayID == id }) else { throw CaptureError.noExclusion }
                scrollingFilter = SCContentFilter(display: liveDisplay, excludingApplications: ownApp, exceptingWindows: [])
            }
            guard let filter = scrollingFilter else { throw CaptureError.noExclusion }
            let frame = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard let cropped = frame.cropping(to: pixels) else { throw CaptureError.displayChanged }
            return cropped
        }, captureFocus: {
            let pointer = NSEvent.mouseLocation
            let local = CGPoint(x: pointer.x - initialFrame.minX, y: initialFrame.maxY - pointer.y)
            guard selection.contains(local) else { return nil }
            return CaptureGeometry.imagePoint(local, displayedIn: selection, imageSize: CGSize(width: first.width, height: first.height))
        }, onSaved: { [weak self] in self?.finishSaving($0) },
           onComplete: { [weak self] in self?.finish(image: $0) })
        beginScrolling(session, screen: screen, selection: selection)
    }
    private func beginScrolling(_ session: ScrollCaptureSession, screen: NSScreen, selection: CGRect) {
        closeOverlays()
        if !session.state.isDemo { returnApp?.activate(options: []) }
        scrollSession = session; session.start(screen: screen, selection: selection)
        logger.notice("Scrolling started from existing selection. width=\(session.state.width) height=\(session.state.height)")
    }
    func showScrollDemo() {
        guard !busy, let screen = NSScreen.main else { return }
        let source = DemoChromeScrollSource(animatesSidebars: true)
        let size = screen.frame.size
        guard let frozen = Self.demoFrame(source.frame(), size: size) else { return }
        prepareCapture()
        presentOverlays([(screen, frozen)], scrolling: { [weak self] screen, selection, pixels, first in
            guard let self else { return }
            let session = try ScrollCaptureSession(first: first, isDemo: true, appearance: captureAppearance,
                                                  pixelsPerPoint: CGFloat(first.width) / selection.width, captureFrame: {
                guard let frame = Self.demoFrame(source.frame(), size: size), let crop = frame.cropping(to: pixels) else {
                    throw CaptureError.displayChanged
                }
                return crop
            }, onSaved: { [weak self] in self?.finishSaving($0) },
           onComplete: { [weak self] in self?.finish(image: $0) })
            session.state.onAdvance = { source.advance() }
            beginScrolling(session, screen: screen, selection: selection)
        })
    }
    deinit { if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) } }
    private enum CaptureError: LocalizedError {
        case noDisplay, displayChanged, noExclusion
        var errorDescription: String? {
            switch self {
            case .noDisplay: return "未找到可截取的显示器。"
            case .displayChanged: return "显示器或缩放发生变化，已暂停捕获。"
            case .noExclusion: return "无法排除截图浮窗，请取消后重新开始。"
            }
        }
    }
}

final class CaptureOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SelectionView: NSView {
    let image: CGImage
    let windowTargets: [WindowSelectionTarget]
    private var origin: CGPoint?
    private var isDragging = false
    private var hoverTarget: WindowSelectionTarget?
    private var hoverPoint: CGPoint?
    private var pointerTracking: NSTrackingArea?
    private(set) var selection: CGRect?
    var onFinish: ((CGRect?) -> Void)?
    var onTargetFinish: ((CGRect?, UInt32?) -> Void)?
    private var recordingSelectionEnabled = false
    var allowsSelection = true {
        didSet { if !allowsSelection { origin = nil; isDragging = false; updateSelection(nil) } }
    }
    var instructions = "拖动框选，松开标注  ·  Shift 正方形  ·  Esc 取消"
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(image: CGImage, size: CGSize, windowTargets: [WindowSelectionTarget] = []) {
        self.image = image; self.windowTargets = windowTargets
        super.init(frame: CGRect(origin: .zero, size: size))
        if !windowTargets.isEmpty { instructions = "单击截取窗口  ·  ⌥ 选整个应用窗口  ·  拖动自由框选  ·  Esc 取消" }
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("截图选区"); setAccessibilityValue("等待选择窗口或拖动框选")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    func enableRecordingSelection() {
        recordingSelectionEnabled = true
        instructions = "单击录制窗口  ·  拖动选择区域  ·  F 录制全屏  ·  Esc 取消"
        setAccessibilityLabel("录屏选区")
        let button = NSButton(title: "录制整个屏幕（F）", target: self, action: #selector(selectEntireScreen))
        button.bezelStyle = .rounded
        button.frame = CGRect(x: bounds.midX - 90, y: bounds.height - 124, width: 180, height: 32)
        addSubview(button)
    }
    @objc private func selectEntireScreen() { guard allowsSelection else { return }; onTargetFinish?(bounds, nil) }
    private func completeSelection(_ rect: CGRect?) {
        if let onTargetFinish { onTargetFinish(rect, rect == nil ? nil : hoverTarget?.id) }
        else { onFinish?(rect) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area); pointerTracking = area
    }
    func refreshHoverFromPointer() {
        guard let window else { return }
        updateHover(at: convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil), wholeWindow: NSEvent.modifierFlags.contains(.option))
    }
    private func updateHover(at point: CGPoint, wholeWindow: Bool = false) {
        guard allowsSelection, origin == nil else { return }
        hoverPoint = point
        let target = bounds.contains(point) ? WindowSelection.target(at: point, in: windowTargets, wholeWindow: wholeWindow) : nil
        updateSelection(target?.rect, target: target)
    }
    private func updateSelection(_ rect: CGRect?, target: WindowSelectionTarget? = nil) {
        guard selection != rect || hoverTarget != target else { return }
        selection = rect; hoverTarget = target; needsDisplay = true
        setAccessibilityValue(rect == nil ? "等待选择窗口或拖动框选" : selectionDescription)
    }
    private var selectionDescription: String {
        guard let selection else { return "" }
        let pixels = CaptureGeometry.pixelRect(selection: selection, bounds: bounds.size,
                                               pixels: CGSize(width: image.width, height: image.height)) ?? .zero
        let prefix = hoverTarget.map { $0.name.isEmpty ? "窗口 · " : "\(String($0.name.prefix(24))) · " } ?? ""
        return "\(prefix)\(Int(pixels.width)) × \(Int(pixels.height)) px"
    }
    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil), wholeWindow: event.modifierFlags.contains(.option)) }
    override func flagsChanged(with event: NSEvent) {
        if let hoverPoint { updateHover(at: hoverPoint, wholeWindow: event.modifierFlags.contains(.option)) }
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {
        if allowsSelection, origin == nil { hoverPoint = nil; updateSelection(nil) }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        Raster.draw(image, in: bounds, context: context)
        let shade = CGMutablePath(); shade.addRect(bounds)
        if let selection { shade.addRect(selection) }
        context.addPath(shade); context.setFillColor(NSColor.black.withAlphaComponent(0.46).cgColor); context.fillPath(using: .evenOdd)
        if let selection {
            context.setStrokeColor(NSColor(calibratedRed: 0.73, green: 0.94, blue: 0.62, alpha: 1).cgColor)
            context.setLineWidth(1.5); context.stroke(selection)
            for point in [CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.minY), CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.maxX, y: selection.maxY)] {
                context.setFillColor(NSColor.white.cgColor); context.fillEllipse(in: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
            }
            pill(selectionDescription, at: CGPoint(x: selection.minX, y: max(8, selection.minY - 34)))
        }
        pill(instructions, at: CGPoint(x: bounds.midX, y: bounds.height - 76), centered: true)
    }
    private func pill(_ text: String, at point: CGPoint, centered: Bool = false) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        let point = CGPoint(x: max(8, min(centered ? point.x - (size.width + 24) / 2 : point.x, bounds.width - size.width - 32)), y: point.y)
        NSColor(calibratedWhite: 0.10, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: CGRect(x: point.x, y: point.y, width: size.width + 24, height: 28), xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: CGPoint(x: point.x + 12, y: point.y + 6), withAttributes: attributes)
    }
    override func mouseDown(with event: NSEvent) {
        guard allowsSelection else { return }
        window?.makeKey(); window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        updateHover(at: point, wholeWindow: event.modifierFlags.contains(.option))
        origin = point; isDragging = false
    }
    private func updateDrag(to location: CGPoint, square: Bool) {
        guard let origin else { return }
        var point = CGPoint(x: min(max(0, location.x), bounds.width), y: min(max(0, location.y), bounds.height))
        // Ignore normal click jitter, but once dragging starts never snap back to a window.
        if !isDragging, hypot(point.x - origin.x, point.y - origin.y) < 4 { return }
        isDragging = true
        if square {
            let dx = point.x - origin.x, dy = point.y - origin.y, length = min(abs(dx), abs(dy))
            point = CGPoint(x: origin.x + (dx >= 0 ? length : -length), y: origin.y + (dy >= 0 ? length : -length))
        }
        updateSelection(CaptureGeometry.rectangle(from: origin, to: point))
    }
    override func mouseDragged(with event: NSEvent) {
        guard allowsSelection else { return }
        updateDrag(to: convert(event.locationInWindow, from: nil), square: event.modifierFlags.contains(.shift))
    }
    override func mouseUp(with event: NSEvent) {
        guard allowsSelection, origin != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        updateDrag(to: point, square: event.modifierFlags.contains(.shift))
        origin = nil; isDragging = false
        if let selection, selection.width >= 3, selection.height >= 3 { completeSelection(selection) }
        else { updateHover(at: point) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { completeSelection(nil) }
        else if recordingSelectionEnabled, event.keyCode == 3 { selectEntireScreen() }
        else if allowsSelection, event.keyCode == 36, let selection, selection.width >= 3, selection.height >= 3 { completeSelection(selection) }
    }
}
