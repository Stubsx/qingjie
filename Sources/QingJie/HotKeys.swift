import AppKit
import Carbon
import SwiftUI
import QingJieCore

private final class CarbonShortcutBackend {
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var handlerStatus: OSStatus = noErr
    var onPress: ((UInt32) -> Void)?
    static let signature: OSType = 0x514A4945

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        handlerStatus = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == CarbonShortcutBackend.signature else { return OSStatus(eventNotHandledErr) }
            Unmanaged<CarbonShortcutBackend>.fromOpaque(context).takeUnretainedValue().onPress?(id.id)
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(_ shortcut: CaptureShortcut, id: UInt32) -> Int32 {
        guard handlerStatus == noErr else { return handlerStatus }
        guard !shortcut.isSystemReserved else { return Int32(eventHotKeyExistsErr) }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers,
                                        EventHotKeyID(signature: Self.signature, id: id), GetEventDispatcherTarget(), 0, &ref)
        if status == noErr, let ref { references[id] = ref }
        return status
    }
    func unregister(_ id: UInt32) { if let ref = references.removeValue(forKey: id) { UnregisterEventHotKey(ref) } }
    deinit {
        references.values.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }
}

extension CaptureShortcut {
    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }
    init(event: NSEvent) {
        var modifiers: ShortcutModifiers = []
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }
    var isSystemReserved: Bool {
        var values: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&values) == noErr, let values else { return false }
        let entries = values.takeRetainedValue() as NSArray
        return entries.contains { value in
            guard let entry = value as? [String: Any], let enabled = entry[kHISymbolicHotKeyEnabled as String] as? NSNumber,
                  enabled.boolValue, let code = entry[kHISymbolicHotKeyCode as String] as? NSNumber,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? NSNumber else { return false }
            return code.uint32Value == keyCode && modifiers.uint32Value == carbonModifiers
        }
    }
}

/// One observable source for preferences, registration state, menus and recorder feedback.
final class HotKeys: ObservableObject {
    @Published private(set) var configuration: ShortcutConfiguration
    @Published private(set) var recording: CaptureShortcutAction?
    @Published private(set) var message = "点击快捷键，按下想使用的组合；修改后立即生效。"
    @Published private(set) var isError = false
    @Published private(set) var testing = false
    @Published private(set) var diagnostic = "尚未检测。点「检测快捷键」，切换到其他应用后按截图组合键。"
    @Published private(set) var lastDelivery = "尚未收到截图按键"
    @Published private(set) var failures: [CaptureShortcutAction: Int32] = [:]
    var onTrigger: ((CaptureShortcutAction) -> Void)?
    var onChange: (() -> Void)?
    var failed: Bool { !failures.isEmpty }
    private let store: ShortcutStore
    private let backend: CarbonShortcutBackend
    private let registry: ShortcutRegistry
    private var localMonitor: Any?
    private var diagnosticTimer: Timer?
    private var sawLocalDuringTest = false
    private var lastTriggerTime: TimeInterval = 0
    private var lastTriggerAction: CaptureShortcutAction?


    init(defaults: UserDefaults = .standard) {
        let store = ShortcutStore(defaults: defaults), backend = CarbonShortcutBackend()
        let loaded = store.load()
        self.store = store; self.backend = backend
        configuration = loaded
        registry = ShortcutRegistry(configuration: loaded, register: { backend.register($0, id: $1) }, unregister: { backend.unregister($0) })
        backend.onPress = { [weak self] id in
            guard let self, let action = registry.action(for: id) else { return }
            receive(action, global: true)
        }
    }
    func register() {
        registry.start()
        if localMonitor == nil {
            // App-local delivery also covers key events routed straight to a focused window.
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, !event.isARepeat else { return event }
                let shortcut = CaptureShortcut(event: event)
                guard registry.action(for: shortcut) != nil else { return event }
                DispatchQueue.main.async { [weak self] in
                    guard let self, let action = registry.action(for: shortcut) else { return }
                    receive(action, global: false)
                }
                return nil
            }
        }
        refresh()
    }
    func beginDiagnostic() {
        cancelRecording()
        diagnosticTimer?.invalidate()
        testing = true; sawLocalDuringTest = false
        diagnostic = "检测中（30 秒）：切换到其他应用，再按截图快捷键。本次只检测，不会截图。"
        diagnosticTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            guard let self, testing else { return }
            testing = false; diagnosticTimer = nil
            diagnostic = sawLocalDuringTest
                ? "只收到应用内按键，尚未验证全局触发。请重新检测，并在其他应用前台按下组合键。"
                : "30 秒内未收到按键。若已在其他应用按过，请检查其他软件的快捷键占用或尝试更换组合。"
        }
    }
    func stopDiagnostic() {
        guard testing else { return }
        testing = false; diagnosticTimer?.invalidate(); diagnosticTimer = nil
        diagnostic = "检测已结束。" 
    }
    private func receive(_ action: CaptureShortcutAction, global: Bool) {
        let label = configuration[action]?.display ?? action.title
        let allowed = CGPreflightScreenCaptureAccess()
        let source = global ? "系统全局事件" : "应用内事件"
        lastDelivery = "已收到 \(label)（\(source)）· " + (allowed ? "屏幕权限已开启" : "屏幕权限未开启，需先授权")
        if testing {
            if global {
                lastTriggerAction = action; lastTriggerTime = ProcessInfo.processInfo.systemUptime
                testing = false; diagnosticTimer?.invalidate(); diagnosticTimer = nil
                diagnostic = "全局快捷键已送达：\(label)。" + (allowed ? "可以开始截图。" : "当前未开启屏幕录制权限，请先授权。")
            } else {
                sawLocalDuringTest = true
                diagnostic = "已收到应用内按键：\(label)。请在剩余时间内切换到其他应用再按一次，以验证全局触发。"
            }
            return
        }
        // Some event routes can deliver the same press through both paths.
        let now = ProcessInfo.processInfo.systemUptime
        guard action != lastTriggerAction || now - lastTriggerTime > 0.25 else { return }
        lastTriggerAction = action; lastTriggerTime = now
        onTrigger?(action)
    }
    func beginRecording(_ action: CaptureShortcutAction) {
        stopDiagnostic()
        registry.suspend(); recording = action; isError = false
        message = "请按下\(action.title)的组合键。Esc 取消，Delete 清除；无响应时可点右侧「选择」。"
    }
    func cancelRecording() {
        guard recording != nil else { return }
        recording = nil; registry.resume(); refresh()
        message = failed ? "部分快捷键暂时无法恢复，请更换组合或关闭占用它的应用。" : "未修改快捷键。"
        isError = failed
    }
    @discardableResult func accept(_ shortcut: CaptureShortcut?, for action: CaptureShortcutAction) -> Bool {
        stopDiagnostic()
        var candidate = configuration; candidate[action] = shortcut
        if let error = candidate.validationMessage { message = error; isError = true; return false }
        if let shortcut, shortcut.isSystemReserved {
            message = "\(shortcut.display)已被 macOS 系统功能使用，请换一个组合。"; isError = true; return false
        }
        recording = nil; registry.resume()
        return apply(candidate)
    }
    func clear(_ action: CaptureShortcutAction) { stopDiagnostic(); cancelRecording(); accept(nil, for: action) }
    func reset() { stopDiagnostic(); cancelRecording(); apply(.defaults) }
    @discardableResult private func apply(_ candidate: ShortcutConfiguration) -> Bool {
        defer { refresh() }
        do {
            for action in CaptureShortcutAction.allCases where candidate[action] != configuration[action] {
                if let shortcut = candidate[action], shortcut.isSystemReserved {
                    throw ShortcutChangeError(message: "\(action.title)的 \(shortcut.display) 已被 macOS 使用，修改未保存。")
                }
            }
            try registry.apply(candidate)
            try store.save(candidate)
            configuration = candidate
            message = registry.failures.isEmpty ? "已保存并生效，重启轻截后仍会保留。" : "修改已保存，其他被占用的快捷键可继续逐项调整。"
            isError = false
            return true
        } catch { message = error.localizedDescription; isError = true; return false }
    }
    private func refresh() { failures = registry.failures; onChange?() }
    deinit { diagnosticTimer?.invalidate(); if let localMonitor { NSEvent.removeMonitor(localMonitor) } }
}


extension HotKeys {
    static func verifyDispatcherDelivery() -> Bool {
        let backend = CarbonShortcutBackend()
        var received: [UInt32] = []
        backend.onPress = { received.append($0) }
        func send(signature: OSType) -> OSStatus {
            var event: EventRef?
            guard CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event) == noErr,
                  let event else { return OSStatus(paramErr) }
            defer { ReleaseEvent(event) }
            var id = EventHotKeyID(signature: signature, id: 981)
            SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id)
            return SendEventToEventTarget(event, GetEventDispatcherTarget())
        }
        let delivered = send(signature: CarbonShortcutBackend.signature)
        _ = send(signature: 0x42414421)
        return delivered == noErr && received == [981]
    }
}
