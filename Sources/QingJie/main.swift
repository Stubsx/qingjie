import AppKit
import SwiftUI
import OSLog
import QingJieCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let state = AppState()
    let captureService = CaptureService()
    let hotKeys = HotKeys()
    var statusItem: NSStatusItem!
    var homeWindow: NSWindow!
    var editors: [NSWindow] = []
    var pins: [NSWindow] = []
    var captureMenuItems: [(NSMenuItem, CaptureShortcutAction, String)] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--smoke-test") { runSmokeTest(); return }
        if let identifier = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter({ $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated })
            .first(where: { $0.isFinishedLaunching || $0.processIdentifier < ProcessInfo.processInfo.processIdentifier }) {
            if let url = existing.bundleURL {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.createsNewApplicationInstance = false
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
            } else {
                existing.activate(options: [.activateAllWindows])
                NSApp.terminate(nil)
            }
            return
        }
        NSApp.setActivationPolicy(DockIconSettings.shared.showsIcon ? .regular : .accessory)
        createMenus()
        state.capture = { [weak self] in self?.captureService.capture($0) }
        state.importImage = { [weak self] in self?.importImage() }
        state.openHistory = { [weak self] in self?.openImage($0) }
        state.showDemo = { [weak self] in self?.captureService.showInlineDemo() }
        state.showScrollDemo = { [weak self] in self?.captureService.showScrollDemo() }
        state.requestPermission = { [weak self] in self?.captureService.showPermissionHelp() }
        captureService.onPermissionChange = { [weak self] in self?.state.hasPermission = CGPreflightScreenCaptureAccess() }
        captureService.onExport = { [weak self] in self?.state.remember($0) }
        hotKeys.onTrigger = { [weak self] in self?.captureService.capture($0 == .region ? .region : .fullscreen) }
        hotKeys.onChange = { [weak self] in self?.refreshShortcutPresentation() }
        hotKeys.register()
        UpdateSettings.shared.onUpdateFound = { [weak self] info in
            self?.state.notice = "发现新版本 \(info.version)：可在「设置 → 通用」下载安装。"
        }
        UpdateSettings.shared.startAutomaticChecks()
        homeWindow = makeWindow(title: "轻截 · 工作台", size: NSSize(width: 1040, height: 740), content: HomeView(state: state, hotKeys: hotKeys))
        homeWindow.delegate = self
        homeWindow.setFrameAutosaveName("QingJieHome")
        showHome()
        if CommandLine.arguments.contains("--demo") { captureService.showInlineDemo() }
    }
    func applicationDidBecomeActive(_ notification: Notification) { state.hasPermission = CGPreflightScreenCaptureAccess() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Logger(subsystem: "com.local.qingjie", category: "Capture").notice("Application reopen requested. hasVisibleWindows=\(flag)")
        guard !captureService.busy else { return false }
        showHome(); return true
    }
    private func makeWindow<V: View>(title: String, size: NSSize, content: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false
        window.backgroundColor = .white; window.contentView = NSHostingView(rootView: content)
        window.center(); return window
    }
    @objc func showHome() { homeWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func showSettings() {
        state.page = .settings
        showHome()
    }
    private func refreshShortcutPresentation() {
        state.shortcutConfiguration = hotKeys.configuration; state.hotKeyFailed = hotKeys.failed
        for (item, action, title) in captureMenuItems {
            item.title = title + (hotKeys.configuration[action].map { "  " + $0.display } ?? "")
        }
    }
    @objc func region() { captureService.capture(.region) }
    @objc func fullscreen() { captureService.capture(.fullscreen) }
    @objc func demo() { captureService.showInlineDemo() }
    @objc func importImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false; panel.title = "打开图片进行标注"
        panel.begin { [weak self] response in if response == .OK, let url = panel.url { self?.openImage(url) } }
    }
    func openImage(_ url: URL) {
        guard let source = NSImage(contentsOf: url), let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            let alert = NSAlert(); alert.messageText = "无法打开这张图片"; alert.informativeText = "请选择有效的 PNG、JPEG、HEIC 或 TIFF 图片。"; alert.runModal(); return
        }
        openEditor(image)
    }
    func openEditor(_ image: CGImage) {
        let model = EditorModel(image: image)
        model.onExport = { [weak self] in self?.state.remember($0) }
        model.onPin = { [weak self] in self?.pin($0) }
        let window = makeWindow(title: "轻截 · 截图标注", size: NSSize(width: 1120, height: 760), content: EditorView(model: model))
        window.delegate = self; window.minSize = NSSize(width: 980, height: 680)
        editors.append(window); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func pin(_ image: CGImage) {
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
        let scale = min(0.55, screen.width * 0.65 / CGFloat(image.width), screen.height * 0.7 / CGFloat(image.height))
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.isMovableByWindowBackground = true
        panel.hasShadow = true; panel.delegate = self; panel.aspectRatio = size; panel.minSize = NSSize(width: 80, height: max(40, size.height / size.width * 80))
        let view = PinnedImageView(); view.image = NSImage(cgImage: image, size: size); view.imageScaling = .scaleProportionallyUpOrDown
        view.toolTip = "拖动移动 · 双击关闭 · 右键查看更多"
        panel.contentView = view; panel.center(); pins.append(panel); panel.orderFrontRegardless()
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        editors.removeAll { $0 === window }; pins.removeAll { $0 === window }
        if window === homeWindow { hotKeys.cancelRecording() }
    }
    private func createMenus() {
        let main = NSMenu()
        let appMenu = NSMenu(); appMenu.addItem(withTitle: "关于轻截", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator()); add("设置…", action: #selector(showSettings), key: ",", to: appMenu)
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "退出轻截", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)
        let fileMenu = NSMenu(title: "文件")
        add("打开图片…", action: #selector(importImage), key: "o", to: fileMenu)
        addCapture("区域截图", selector: #selector(region), action: .region, to: fileMenu)
        addCapture("全屏截图", selector: #selector(fullscreen), action: .fullscreen, to: fileMenu)
        fileMenu.addItem(.separator()); add("显示工作台", action: #selector(showHome), to: fileMenu)
        let fileItem = NSMenuItem(title: "文件", action: nil, keyEquivalent: ""); fileItem.submenu = fileMenu; main.addItem(fileItem)
        let editMenu = NSMenu(title: "编辑")
        for (title, selector, key) in [("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: title, action: selector, keyEquivalent: key)
        }
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); editItem.submenu = editMenu; main.addItem(editItem)
        NSApp.mainMenu = main
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "轻截")
        let menu = NSMenu()
        addCapture("区域截图", selector: #selector(region), action: .region, to: menu)
        addCapture("全屏截图", selector: #selector(fullscreen), action: .fullscreen, to: menu)
        menu.addItem(.separator()); add("打开图片…", action: #selector(importImage), to: menu)
        add("显示工作台", action: #selector(showHome), to: menu); add("体验标注", action: #selector(demo), to: menu)
        add("设置…", action: #selector(showSettings), to: menu)
        menu.addItem(.separator()); menu.addItem(withTitle: "退出轻截", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }
    private func addCapture(_ title: String, selector: Selector, action: CaptureShortcutAction, to menu: NSMenu) {
        let item = NSMenuItem(title: title + (hotKeys.configuration[action].map { "  " + $0.display } ?? ""), action: selector, keyEquivalent: "")
        item.target = self; menu.addItem(item); captureMenuItems.append((item, action, title))
    }
    private func add(_ title: String, action: Selector, key: String = "", to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
    }
    private func runSmokeTest() {
        Task {
            do { try SmokeTest.run(); try await SmokeTest.runWorkerChecks(); print("SMOKE TEST PASSED"); NSApp.terminate(nil) }
            catch { fputs("SMOKE TEST FAILED: \(error)\n", stderr); exit(1) }
        }
    }
}

final class PinnedImageView: NSImageView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.close() } else { window?.performDrag(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copy = NSMenuItem(title: "复制贴图", action: #selector(copyImage), keyEquivalent: ""); copy.target = self; menu.addItem(copy)
        let opacity = NSMenuItem(title: window?.alphaValue == 1 ? "半透明" : "不透明", action: #selector(toggleOpacity), keyEquivalent: ""); opacity.target = self; menu.addItem(opacity)
        menu.addItem(.separator())
        let close = NSMenuItem(title: "关闭贴图", action: #selector(closePin), keyEquivalent: ""); close.target = self; menu.addItem(close)
        return menu
    }
    @objc private func closePin() { window?.close() }
    @objc private func toggleOpacity() { window?.alphaValue = window?.alphaValue == 1 ? 0.55 : 1 }
    @objc private func copyImage() { guard let image else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
