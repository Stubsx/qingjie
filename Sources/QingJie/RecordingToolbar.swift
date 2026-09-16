import AppKit
import SwiftUI
import QingJieCore

/// The same frozen selection, resize handles and toolbar placement as a screenshot.
final class InlineRecordingView: NSView {
    static let toolbarSize = CGSize(width: 680, height: 90)
    private let screenshot: CGImage
    private let service: RecordingService
    private(set) var selection: CGRect
    private let handles = CaptureResizeHandles(frame: .zero)
    private let toolbar: NSHostingView<RecordingToolbar>
    private var resizeSnapshot: RecordingTarget?
    private var resizeHandle: RectResizeHandle?
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(screenshot: CGImage, size: CGSize, target: RecordingTarget, service: RecordingService) {
        self.screenshot = screenshot; self.service = service; selection = target.rect
        toolbar = NSHostingView(rootView: RecordingToolbar(service: service, settings: service.settings))
        toolbar.sizingOptions = []
        super.init(frame: CGRect(origin: .zero, size: size))
        addSubview(handles); addSubview(toolbar)
        handles.onBegin = { [weak self] in
            guard let self else { return }
            window?.makeFirstResponder(self)
            resizeSnapshot = service.target; resizeHandle = $0
        }
        handles.onDrag = { [weak self] in self?.resize(to: $0, square: $1) }
        handles.onEnd = { [weak self] in self?.resizeSnapshot = nil; self?.resizeHandle = nil }
        handles.onCursorUpdate = { [weak self] in self?.mouseMoved(with: $0) }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    override func layout() {
        super.layout()
        handles.frame = bounds; handles.selection = selection
        toolbar.frame = CaptureGeometry.toolbarFrame(selection: selection, bounds: bounds.size, size: Self.toolbarSize)
    }
    private func resize(to point: CGPoint, square: Bool) {
        guard let before = resizeSnapshot, let resizeHandle else { return }
        let rect = InteractionGeometry.resize(before.rect, handle: resizeHandle, to: point, bounds: bounds, minimum: 3, square: square)
        guard rect != selection else { return }
        selection = rect
        service.updateSelection(RecordingTarget(displayID: before.displayID, displayFrame: before.displayFrame,
                                                scale: before.scale, rect: rect, windowID: nil, title: "自选区域"))
        needsLayout = true; needsDisplay = true; layoutSubtreeIfNeeded()
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        Raster.draw(screenshot, in: bounds, context: context)
        let shade = CGMutablePath(); shade.addRect(bounds); shade.addRect(selection)
        context.addPath(shade); context.setFillColor(NSColor.black.withAlphaComponent(0.46).cgColor)
        context.fillPath(using: .evenOdd)
        context.setStrokeColor(NSColor(calibratedRed: 0.73, green: 0.94, blue: 0.62, alpha: 1).cgColor)
        context.setLineWidth(1.5); context.stroke(selection)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .cursorUpdate], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !toolbar.frame.contains(point), let cursor = handles.cursor(at: point) { cursor.set() }
        else { NSCursor.arrow.set() }
    }
    override func cursorUpdate(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if let before = resizeSnapshot {
                selection = before.rect; service.updateSelection(before)
                resizeSnapshot = nil; resizeHandle = nil; handles.stopDragging()
                needsDisplay = true; needsLayout = true
            } else { service.cancel() }
        } else if event.keyCode == 36 { service.start() }
        else { super.keyDown(with: event) }
    }
}

struct RecordingToolbar: View {
    @ObservedObject var service: RecordingService
    @ObservedObject var settings: RecordingSettings
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 5) {
                Picker("分辨率", selection: $settings.options.resolution) {
                    ForEach(RecordingResolution.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 100).help("录制分辨率")
                Picker("帧率", selection: $settings.options.frameRate) {
                    ForEach(RecordingOptions.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                }.labelsHidden().frame(width: 82).help("录制帧率")
                Divider().frame(height: 22)
                option("系统声音", icon: "speaker.wave.2", offIcon: "speaker.slash", value: $settings.options.systemAudio)
                option("麦克风", icon: "mic", offIcon: "mic.slash", value: $settings.options.microphone)
                option("显示鼠标", icon: "cursorarrow", value: $settings.options.showsCursor)
                option("点击效果", icon: "cursorarrow.click.2", value: $settings.options.mouseClicks)
                Spacer(minLength: 6)
                button("重新框选", icon: "selection.pin.in.out", help: "重新选择录屏区域或窗口") { service.beginSelection() }
                button("取消录屏", icon: "xmark", help: "取消录屏 · Esc") { service.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button { service.start() } label: { Label("开始", systemImage: "record.circle") }
                    .buttonStyle(ActionButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .accessibilityLabel("开始录制").help("3 秒后开始录制 · Enter")
            }
            HStack(spacing: 8) {
                Text(service.target?.title ?? "录屏").lineLimit(1)
                Text("· 拖动四角调整，边线移动选区").lineLimit(1)
                Spacer(minLength: 8)
                let size = settings.options.resolution.outputSize(for: service.target?.sourceSize ?? .zero)
                Text("\(Int(size.width)) × \(Int(size.height)) px").font(.system(size: 11, design: .monospaced)).fixedSize()
            }.font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white, in: RoundedRectangle(cornerRadius: 11)).foregroundStyle(Theme.green).preferredColorScheme(.light)
    }
    private func option(_ title: String, icon: String, offIcon: String? = nil, value: Binding<Bool>) -> some View {
        Button { value.wrappedValue.toggle() } label: { Image(systemName: !value.wrappedValue ? (offIcon ?? icon) : icon) }
            .buttonStyle(AnnotationIconButtonStyle(selected: value.wrappedValue))
            .accessibilityLabel(title).accessibilityValue(value.wrappedValue ? "已开启" : "已关闭")
            .help("\(title)：\(value.wrappedValue ? "已开启" : "已关闭")")
    }
    private func button(_ title: String, icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }
            .buttonStyle(AnnotationIconButtonStyle()).accessibilityLabel(title).help(help)
    }
}

struct RecordingStatusToolbar: View {
    @ObservedObject var service: RecordingService
    var body: some View {
        HStack(spacing: 12) {
            if service.phase == .finished {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("录屏已保存").font(.system(size: 13, weight: .medium))
                    Text(service.stopReason.isEmpty ? (service.savedURL?.lastPathComponent ?? "") : service.stopReason)
                        .font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let url = service.savedURL {
                    icon("播放视频", "play.fill") { NSWorkspace.shared.open(url) }
                    icon("在访达中显示", "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                icon("完成", "xmark") { service.cancel() }
            } else if service.phase == .failed {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text(service.failure).font(.system(size: 12)).lineLimit(3).help(service.failure)
                Spacer(minLength: 4)
                if let url = service.recoveryURL {
                    icon("查看保留文件", "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                icon("重新选择", "arrow.clockwise") { service.beginSelection() }
                icon("关闭", "xmark") { service.cancel() }
            } else {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text(status).font(.system(size: 14, weight: .semibold, design: .monospaced))
                Spacer(minLength: 4)
                if service.phase == .countdown { icon("取消录屏", "xmark") { service.cancel() } }
                else if service.phase == .recording {
                    Text(service.shortcutLabel()).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    icon("停止录屏并保存", "stop.fill") { service.stop() }
                } else { ProgressView().controlSize(.small) }
            }
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(Theme.ink).background(.white, in: RoundedRectangle(cornerRadius: 11))
    }
    private var status: String {
        switch service.phase {
        case .countdown: return service.countdown > 0 ? "\(service.countdown) 秒后开始" : "正在准备…"
        case .recording: return service.durationLabel
        case .finishing: return "正在保存…"
        default: return "正在开始…"
        }
    }
    private func icon(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(AnnotationIconButtonStyle()).accessibilityLabel(title).help(title)
    }
}
