import AppKit
import SwiftUI

enum InstalledApp {
    static var url: URL {
        URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "QingJieInstallPath") as? String ?? "/Applications/轻截.app", isDirectory: true)
    }
    static var isAvailable: Bool { Bundle(url: url)?.bundleIdentifier == "com.local.qingjie" }
    static func pasteboardItem() -> NSPasteboardWriting { url as NSURL }
}

@MainActor final class PermissionHelpController: NSObject, NSWindowDelegate, ObservableObject {
    @Published var allowed = false
    var onPermissionChange: (() -> Void)?
    private var panel: NSPanel?
    private var timer: Timer?

    func show() {
        allowed = CGPreflightScreenCaptureAccess()
        if panel == nil {
            let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 370, height: 205),
                                 styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "轻截 · 拖拽授权"; window.isReleasedWhenClosed = false
            window.level = .floating; window.hidesOnDeactivate = false; window.isMovableByWindowBackground = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; window.delegate = self
            window.contentView = NSHostingView(rootView: PermissionHelpView(controller: self))
            if let screen = NSScreen.main {
                window.setFrameOrigin(CGPoint(x: screen.visibleFrame.maxX - 390, y: screen.visibleFrame.minY + 35))
            }
            panel = window
        }
        panel?.makeKeyAndOrderFront(nil)
        openSettings()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let updated = CGPreflightScreenCaptureAccess()
                if updated != self.allowed { self.allowed = updated; self.onPermissionChange?() }
            }
        }
    }
    static func renderPreview() -> CGImage? {
        let controller = PermissionHelpController()
        let view = NSHostingView(rootView: PermissionHelpView(controller: controller))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 370, height: 205), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; view.layoutSubtreeIfNeeded()
        defer { window.close() }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap); return bitmap.cgImage
    }
    func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    func dismiss() { timer?.invalidate(); timer = nil; panel?.close(); panel = nil }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil; panel = nil }
}

private struct PermissionHelpView: View {
    @ObservedObject var controller: PermissionHelpController
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(controller.allowed ? "屏幕录制权限已开启" : "列表里找不到轻截？把它拖进去")
                .font(.system(size: 13, weight: .semibold))
            DraggableAppBadge().frame(height: 64)
            Text(controller.allowed ? "可以关闭此浮条并重试截图。如暂不可用，请退出再打开轻截。" : "拖到系统设置的「屏幕与系统音频录制」列表，再按系统提示打开开关。")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("打开系统设置") { controller.openSettings() }
                Spacer()
                Button("完成") { controller.dismiss() }
            }.font(.system(size: 11))
        }.padding(16).frame(width: 370, alignment: .leading).background(Theme.background)
            .foregroundStyle(Theme.ink).preferredColorScheme(.light)
    }
}

private struct DraggableAppBadge: NSViewRepresentable {
    func makeNSView(context: Context) -> AppDragView { AppDragView() }
    func updateNSView(_ nsView: AppDragView, context: Context) {}
}

final class AppDragView: NSView, NSDraggingSource {
    private var mouseOrigin: CGPoint?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("轻截应用，拖到系统设置的录屏权限列表")
        toolTip = InstalledApp.url.path
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    override func resetCursorRects() { if InstalledApp.isAvailable { addCursorRect(bounds, cursor: .openHand) } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        let icon = NSWorkspace.shared.icon(forFile: InstalledApp.url.path)
        icon.draw(in: CGRect(x: 12, y: 10, width: 44, height: 44), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        ("轻截" as NSString).draw(at: CGPoint(x: 68, y: 12), withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor])
        ((InstalledApp.isAvailable ? "拖动这里添加到授权列表 →" : "请先安装到「应用程序」") as NSString)
            .draw(at: CGPoint(x: 68, y: 36), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
    }
    override func mouseDown(with event: NSEvent) { mouseOrigin = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard InstalledApp.isAvailable, let start = mouseOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
        mouseOrigin = nil
        let item = NSDraggingItem(pasteboardWriter: InstalledApp.pasteboardItem())
        item.setDraggingFrame(CGRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48), contents: NSWorkspace.shared.icon(forFile: InstalledApp.url.path))
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
