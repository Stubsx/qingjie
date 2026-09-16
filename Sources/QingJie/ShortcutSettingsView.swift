import AppKit
import SwiftUI
import QingJieCore

struct ShortcutSettingsView: View {
    @ObservedObject var hotKeys: HotKeys
    @State private var choosing: CaptureShortcutAction?
    @State private var chosenModifiers: ShortcutModifiers = []
    @State private var chosenKey: UInt32 = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("快捷键").font(.system(size: 24, weight: .semibold))
                    Text("点击右侧按键录入新组合。")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button("恢复默认") { hotKeys.reset() }.buttonStyle(ActionButtonStyle())
                    .disabled(hotKeys.recording != nil)
                    .accessibilityLabel("恢复快捷键默认设置").help("恢复默认快捷键组合")
            }
            VStack(spacing: 0) {
                ForEach(CaptureShortcutAction.allCases, id: \.self) { action in
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(action.title).font(.system(size: 14, weight: .medium))
                            Text(action == .region ? "框选后可标注或开始长截图" : (action == .fullscreen ? "截取鼠标所在屏幕" : "选择范围开始录制，再按一次停止保存"))
                                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            if hotKeys.failures[action] != nil && hotKeys.recording == nil {
                                Text("注册失败（状态码 \(hotKeys.failures[action] ?? 0)），请更换组合或关闭占用它的应用。")
                                    .font(.system(size: 10)).foregroundStyle(.orange)
                            }
                        }
                        Spacer(minLength: 10)
                        ShortcutRecorder(hotKeys: hotKeys, action: action).frame(width: 180, height: 36)
                        Button("选择") { beginChoosing(action) }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.green)
                            .accessibilityLabel("选择\(action.title)快捷键")
                        Button { hotKeys.clear(action) } label: { Image(systemName: "xmark.circle").font(.system(size: 14)) }
                            .buttonStyle(.plain).foregroundStyle(Theme.secondary).help("清除\(action.title)快捷键")
                            .disabled(hotKeys.configuration[action] == nil || hotKeys.recording != nil)
                    }.padding(18)
                    if choosing == action { shortcutChooser(for: action).padding(.horizontal, 18).padding(.bottom, 18) }
                    if action != .recording { Divider().padding(.horizontal, 18) }
                }
            }.background(.white, in: RoundedRectangle(cornerRadius: 12))
            Text(hotKeys.message).font(.system(size: 12)).foregroundStyle(hotKeys.isError ? .orange : Theme.green)
                .lineSpacing(4).frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
                .accessibilityLabel(hotKeys.message)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("触发检测").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button(hotKeys.testing ? "结束检测" : "检测快捷键") {
                        choosing = nil
                        if hotKeys.testing { hotKeys.stopDiagnostic() } else { hotKeys.beginDiagnostic() }
                    }.buttonStyle(ActionButtonStyle())
                }
                Text(hotKeys.diagnostic).font(.system(size: 12)).foregroundStyle(Theme.green).fixedSize(horizontal: false, vertical: true)
                Text(hotKeys.lastDelivery).font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                if hotKeys.failed { Text("部分组合注册失败，请查看上方状态。").font(.system(size: 10)).foregroundStyle(.orange) }
            }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 12))
        }.frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: hotKeys.recording) { _, action in if action != nil { choosing = nil } }
        .onDisappear { hotKeys.cancelRecording() }
    }

    private func beginChoosing(_ action: CaptureShortcutAction) {
        hotKeys.cancelRecording()
        guard choosing != action else { choosing = nil; return }
        let shortcut = hotKeys.configuration[action] ?? ShortcutConfiguration.defaults[action]!
        chosenModifiers = shortcut.modifiers; chosenKey = shortcut.keyCode
        choosing = action
    }

    private func shortcutChooser(for action: CaptureShortcutAction) -> some View {
        let candidate = CaptureShortcut(keyCode: chosenKey, modifiers: chosenModifiers)
        return VStack(alignment: .leading, spacing: 14) {
            Text("分别选择修饰键和主键，无需同时按下组合。").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            HStack(spacing: 14) {
                modifierToggle("⌃ Control", .control)
                modifierToggle("⌥ Option", .option)
                modifierToggle("⇧ Shift", .shift)
                modifierToggle("⌘ Command", .command)
            }.font(.system(size: 11))
            HStack(spacing: 12) {
                Picker("主键", selection: $chosenKey) {
                    ForEach(CaptureShortcut.keyNames.keys.sorted { CaptureShortcut.keyNames[$0]! < CaptureShortcut.keyNames[$1]! }, id: \.self) { code in
                        Text(CaptureShortcut.keyNames[code]!).tag(code)
                    }
                }.frame(width: 145)
                Text(candidate.display).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(Theme.green)
                    .accessibilityLabel("待保存的快捷键：\(candidate.display)")
                Spacer(minLength: 4)
                Button("取消") { choosing = nil }.buttonStyle(ActionButtonStyle())
                Button("保存") { if hotKeys.accept(candidate, for: action) { choosing = nil } }
                    .buttonStyle(ActionButtonStyle(primary: true))
            }
        }.padding(14).background(Theme.background, in: RoundedRectangle(cornerRadius: 9))
    }

    private func modifierToggle(_ title: String, _ modifier: ShortcutModifiers) -> some View {
        Toggle(title, isOn: Binding(get: { chosenModifiers.contains(modifier) }, set: { selected in
            if selected { chosenModifiers.insert(modifier) } else { chosenModifiers.remove(modifier) }
        })).toggleStyle(.checkbox)
    }

    @MainActor static func renderPreview() -> CGImage? {
        let suite = "QingJie.preview.\(UUID().uuidString)"
        let isolated = UserDefaults(suiteName: suite)!
        defer { isolated.removePersistentDomain(forName: suite) }
        let view = NSHostingView(rootView: ShortcutSettingsView(hotKeys: HotKeys(defaults: isolated))
            .padding(32).frame(maxHeight: .infinity, alignment: .top).background(Theme.background).preferredColorScheme(.light))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1040, height: 740), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; view.layoutSubtreeIfNeeded()
        defer { window.close() }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap); return bitmap.cgImage
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var hotKeys: HotKeys
    let action: CaptureShortcutAction
    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.onBegin = { [weak hotKeys] in hotKeys?.beginRecording(action) }
        button.onCancel = { [weak hotKeys] in
            guard hotKeys?.recording == action else { return }
            hotKeys?.cancelRecording()
        }
        button.onValue = { [weak hotKeys] shortcut in
            guard hotKeys?.recording == action else { return }
            hotKeys?.accept(shortcut, for: action)
        }
        return button
    }
    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.actionTitle = action.title
        button.idleTitle = hotKeys.configuration[action]?.display ?? "点击设置"
        button.recording = hotKeys.recording == action
        button.toolTip = "点击录入快捷键，Esc 取消，Delete 清除"
    }
}

final class ShortcutRecorderButton: NSButton {
    var onBegin: (() -> Void)?
    var onCancel: (() -> Void)?
    var onValue: ((CaptureShortcut?) -> Void)?
    var actionTitle = "" { didSet { updateTitle() } }
    var idleTitle = "点击设置" { didSet { updateTitle() } }
    private var pressedModifiers: ShortcutModifiers = []
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    var recording = false {
        didSet {
            guard oldValue != recording else { return }
            if recording {
                window?.makeFirstResponder(self)
                // App-local only: no Accessibility or Input Monitoring permission is required.
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                    guard let self, recording else { return event }
                    // Do not consume events belonging to another window in the app.
                    if let eventWindow = event.window, eventWindow !== window { return event }
                    receive(event); return nil
                }
                resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    self?.onCancel?()
                }
            } else { stopMonitoring() }
            pressedModifiers = []; updateTitle()
        }
    }
    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded; controlSize = .large; font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        target = self; action = #selector(begin)
        setButtonType(.momentaryPushIn)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    override var acceptsFirstResponder: Bool { true }
    @objc private func begin() {
        onBegin?()
        // Install the receiver immediately, without waiting for the next SwiftUI update.
        recording = true
    }
    override func resignFirstResponder() -> Bool { if recording { onCancel?() }; return super.resignFirstResponder() }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil && recording { onCancel?() }; super.viewWillMove(toWindow: newWindow) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording { receive(event); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if recording { receive(event) } else { super.keyDown(with: event) }
    }
    override func flagsChanged(with event: NSEvent) {
        if recording { receive(event) } else { super.flagsChanged(with: event) }
    }
    func receive(_ event: NSEvent) {
        guard recording else { return }
        if event.type == .flagsChanged {
            pressedModifiers = CaptureShortcut(event: event).modifiers
            updateTitle(); return
        }
        guard event.type == .keyDown, !event.isARepeat else { return }
        if event.keyCode == 53 { onCancel?(); return }
        let shortcut = CaptureShortcut(event: event)
        if shortcut.modifiers.isEmpty && [51, 117].contains(event.keyCode) { onValue?(nil) }
        else { onValue?(shortcut) }
    }
    private func updateTitle() {
        title = recording ? (pressedModifiers.isEmpty ? "请按下组合键…" : pressedModifiers.symbols + " + …") : idleTitle
        setAccessibilityLabel(recording ? "\(actionTitle)快捷键录入：\(title)" : "\(actionTitle)快捷键：\(idleTitle)")
    }
    private func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
    }
    deinit { stopMonitoring() }
}
