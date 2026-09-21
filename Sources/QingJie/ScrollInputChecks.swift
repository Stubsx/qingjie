import AppKit
import QingJieCore

/// A second signed process with two real scroll views, used only by the native input regression check.
@MainActor final class ScrollInputFixture: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    private var scrolls: [NSScrollView] = []
    private var timer: Timer?
    private var directory: URL!
    private var started = Date()
    private var monitor: Any?
    private var eventDetails: [String: NSNumber] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let flag = CommandLine.arguments.firstIndex(of: "--scroll-input-fixture"),
              flag + 1 < CommandLine.arguments.count, let screen = NSScreen.main else { NSApp.terminate(nil); return }
        directory = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
        NSApp.setActivationPolicy(.accessory)
        let bounds = screen.visibleFrame
        for index in 0..<2 {
            let window = NSWindow(contentRect: CGRect(x: bounds.minX + 35 + CGFloat(index) * 380,
                                                       y: bounds.midY - 180, width: 350, height: 360),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = index == 0 ? "轻截测试 · 滚动目标" : "轻截测试 · 另一个焦点窗口"
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 350, height: 360))
            scroll.hasVerticalScroller = true
            scroll.documentView = ScrollInputFixtureDocument(frame: CGRect(x: 0, y: 0, width: 330, height: 4000))
            window.contentView = scroll; window.orderFrontRegardless()
            scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
            windows.append(window); scrolls.append(scroll)
        }
        // Keep a different window key: the event must still reach the selected source window.
        NSApp.activate(ignoringOtherApps: true); windows[1].makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.eventDetails = ["eventWindow": NSNumber(value: event.windowNumber), "delta": NSNumber(value: Double(event.scrollingDeltaY)),
                                  "eventX": NSNumber(value: Double(event.locationInWindow.x)), "eventY": NSNumber(value: Double(event.locationInWindow.y)),
                                  "cgX": NSNumber(value: Double(event.cgEvent?.location.x ?? -999)), "cgY": NSNumber(value: Double(event.cgEvent?.location.y ?? -999))]
            return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }
        publish()
    }

    private func publish() {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop").path) || Date().timeIntervalSince(started) > 20 {
            timer?.invalidate(); NSApp.terminate(nil); return
        }
        var values: [String: Any] = ["sourceWindow": windows[0].windowNumber, "otherWindow": windows[1].windowNumber,
                                   "keyWindow": NSApp.keyWindow?.windowNumber ?? -1,
                                   "sourceOffset": scrolls[0].contentView.bounds.minY,
                                   "otherOffset": scrolls[1].contentView.bounds.minY]
        values.merge(eventDetails) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: values) {
            try? data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
        }
    }
}

private final class ScrollInputFixtureDocument: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); dirtyRect.fill()
        for row in 0..<100 {
            let text = "第 \(row + 1) 行 · 原生滚动事件验证"
            (text as NSString).draw(at: CGPoint(x: 20, y: row * 40 + 10),
                                   withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor])
        }
    }
}

extension SmokeTest {
    @MainActor static func checkScrollInputRouting() async throws {
        let hud = ScrollCapturePanel(contentRect: CGRect(x: 20, y: 30, width: 200, height: 100),
                                     styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.isReleasedWhenClosed = false
        defer { hud.close() }
        try require(!hud.canBecomeKey && !hud.canBecomeMain, "长截图控制浮窗不会抢走源窗口的键盘焦点")
        hud.permitsKeyboardFocus = { true }
        try require(hud.canBecomeKey, "裁剪和演示仍可按需接受键盘操作")
        hud.permitsKeyboardFocus = { false }

        let sample = ScrollCaptureDestination(windowID: 731, processID: 123, frame: CGRect(x: 100, y: 200, width: 600, height: 400))
        let event = ScrollCaptureInput.makeEvent(to: sample, at: CGPoint(x: 250, y: 350), points: 80)
        try require(event?.type == .scrollWheel, "构造原生滚轮事件")
        try require(event?.location == CGPoint(x: 250, y: 350)
                    && event?.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -80,
                    "定向滚动保留目标坐标和向下的像素步长")
        guard CGPreflightPostEventAccess() else {
            print("SKIP: 跨进程原生滚动检查需要已授予轻截辅助功能权限；未请求或更改权限")
            return
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QingJie-scroll-input-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process(); process.executableURL = Bundle.main.executableURL
        process.arguments = ["--scroll-input-fixture", directory.path]
        try process.run()
        defer { try? Data().write(to: directory.appendingPathComponent("stop")) }
        func snapshot() -> [String: NSNumber]? {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("state.json")) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: NSNumber]
        }
        var source: QingJieCore.CaptureWindow?
        for _ in 0..<200 {
            if let value = snapshot(), let sourceID = value["sourceWindow"]?.uint32Value,
               value["keyWindow"] == value["otherWindow"] {
                source = CaptureService.snapshotWindows().first(where: { $0.id == sourceID && $0.ownerPID == process.processIdentifier })
            }
            if source != nil { break }; try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let source else {
            throw Failure(description: "原生滚动测试窗口未就绪：\(snapshot() ?? [:])，进程运行=\(process.isRunning)")
        }
        let sourceID = source.id
        // Put the HUD under the actual pointer, without moving the user's mouse.
        // Choose a different visible point in the source so OS hit testing is exercised.
        let physicalMoves = CGEventSource.counterForEventType(.hidSystemState, eventType: .mouseMoved)
        let cursor = NSEvent.mouseLocation
        hud.setFrameOrigin(CGPoint(x: cursor.x - 100, y: cursor.y - 50))
        let screenHeight = CGDisplayBounds(CGMainDisplayID()).height
        let points = [CGFloat(0.3), 0.6, 0.8].flatMap { y in
            [CGFloat(0.3), 0.6].map { x in
                CGPoint(x: source.frame.minX + source.frame.width * x, y: source.frame.minY + source.frame.height * y)
            }
        }
        guard let point = points.first(where: { !hud.frame.contains(CGPoint(x: $0.x, y: screenHeight - $0.y)) }) else {
            throw Failure(description: "测试浮窗遮住了正文")
        }
        guard let destination = ScrollCaptureInput.destination(at: point) else { throw Failure(description: "未识别原生滚动测试目标") }
        try require(destination.windowID == sourceID && destination.processID == process.processIdentifier,
                    "从实际选区识别目标进程和窗口，忽略截图浮窗")
        hud.level = .floating; hud.orderFrontRegardless(); hud.makeKey()
        try require(!hud.isKeyWindow, "即使请求成为关键窗口，采集浮窗也保持不抢焦点")
        ScrollCaptureInput.restoreFocus(to: destination)
        for _ in 0..<100 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.processID { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.processID, "开启自动滚动时恢复目标应用焦点")
        let cursorBefore = NSEvent.mouseLocation
        for _ in 0..<3 {
            guard ScrollCaptureInput.scroll(to: destination, at: point, points: 80) else {
                throw Failure(description: "原生滚轮投递失败：\(destination)，当前=\(String(describing: ScrollCaptureInput.destination(at: point)))")
            }
            try await Task.sleep(nanoseconds: 120_000_000)
        }
        var final: [String: NSNumber]?
        for _ in 0..<100 {
            final = snapshot()
            if (final?["sourceOffset"]?.doubleValue ?? 0) > 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try require((final?["sourceOffset"]?.doubleValue ?? 0) > 100 && final?["otherOffset"]?.doubleValue == 0,
                    "真实跨进程滚动只移动指定正文，另一个有键盘焦点的窗口保持原位：\(final ?? [:])")
        if CGEventSource.counterForEventType(.hidSystemState, eventType: .mouseMoved) == physicalMoves {
            try require(NSEvent.mouseLocation == cursorBefore && hud.frame.contains(cursorBefore),
                        "鼠标停留在浮窗上也能滚动正文，滚动后恢复原位：\(cursorBefore) → \(NSEvent.mouseLocation)")
        } else {
            print("SKIP: 检测到用户移动鼠标，仅跳过鼠标复位检查；正文路由已验证")
        }
        try Data().write(to: directory.appendingPathComponent("stop"))
        for _ in 0..<100 {
            if !process.isRunning { break }; try await Task.sleep(nanoseconds: 20_000_000)
        }
        try require(!process.isRunning, "原生滚动测试窗口正常退出")
        try FileManager.default.removeItem(at: directory)
    }
}
