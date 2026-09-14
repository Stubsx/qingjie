import Foundation

public enum CaptureShortcutAction: String, CaseIterable, Codable, Sendable {
    case region, fullscreen
    public var title: String {
        switch self { case .region: return "区域截图"; case .fullscreen: return "全屏截图" }
    }
}

public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let control = Self(rawValue: 1)
    public static let option = Self(rawValue: 2)
    public static let shift = Self(rawValue: 4)
    public static let command = Self(rawValue: 8)
    public static let all: Self = [.control, .option, .shift, .command]
    public var symbols: String {
        [(Self.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { contains($0.0) }.map(\.1).joined()
    }
}

public struct CaptureShortcut: Codable, Hashable, Sendable {
    public let keyCode: UInt32
    public let modifiers: ShortcutModifiers
    public init(keyCode: UInt32, modifiers: ShortcutModifiers) { self.keyCode = keyCode; self.modifiers = modifiers }
    public static let keyNames: [UInt32: String] = [
        0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",
        18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",
        36:"↩",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"⇥",49:"空格",50:"`",51:"⌫",
        65:"小数点",67:"小键盘 *",69:"小键盘 +",71:"清除",75:"小键盘 /",76:"小键盘 ↩",78:"小键盘 −",81:"小键盘 =",
        82:"小键盘 0",83:"小键盘 1",84:"小键盘 2",85:"小键盘 3",86:"小键盘 4",87:"小键盘 5",88:"小键盘 6",89:"小键盘 7",91:"小键盘 8",92:"小键盘 9",
        96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",105:"F13",106:"F16",107:"F14",109:"F10",111:"F12",113:"F15",
        114:"帮助",115:"↖",116:"⇞",117:"⌦",118:"F4",119:"↘",120:"F2",121:"⇟",122:"F1",123:"←",124:"→",125:"↓",126:"↑",64:"F17",79:"F18",80:"F19",90:"F20"
    ]
    public var display: String { modifiers.symbols + (Self.keyNames[keyCode] ?? "?") }
    public var validationMessage: String? {
        guard Self.keyNames[keyCode] != nil, modifiers.subtracting(.all).isEmpty else { return "这个按键暂不支持，请换一个组合。" }
        guard !modifiers.intersection([.control, .option, .command]).isEmpty else { return "请至少搭配 ⌘、⌥ 或 ⌃ 中的一个，避免影响正常输入。" }
        if modifiers == .command && [0,1,6,7,8,9,12,13,31,43].contains(keyCode) || modifiers == [.command, .shift] && keyCode == 6 {
            return "这个组合用于应用内的编辑或窗口操作，请换一个截图快捷键。"
        }
        return nil
    }
}

public struct ShortcutConfiguration: Codable, Equatable, Sendable {
    public var region: CaptureShortcut?
    public var fullscreen: CaptureShortcut?
    public init(region: CaptureShortcut?, fullscreen: CaptureShortcut?) {
        self.region = region; self.fullscreen = fullscreen
    }
    public static let defaults = Self(region: .init(keyCode: 0, modifiers: [.option, .shift]),
                                      fullscreen: .init(keyCode: 3, modifiers: [.option, .shift]))
    public subscript(_ action: CaptureShortcutAction) -> CaptureShortcut? {
        get { switch action { case .region: return region; case .fullscreen: return fullscreen } }
        set { switch action { case .region: region = newValue; case .fullscreen: fullscreen = newValue } }
    }
    public var validationMessage: String? {
        var used: [CaptureShortcut: CaptureShortcutAction] = [:]
        for action in CaptureShortcutAction.allCases {
            guard let shortcut = self[action] else { continue }
            if let message = shortcut.validationMessage { return "\(action.title)：\(message)" }
            if let previous = used[shortcut] { return "\(action.title)与\(previous.title)使用了相同的快捷键，请换一个组合。" }
            used[shortcut] = action
        }
        return nil
    }
}

public struct ShortcutStore {
    private let defaults: UserDefaults
    public static let key = "QingJie.captureShortcuts.v1"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> ShortcutConfiguration {
        guard let data = defaults.data(forKey: Self.key), let configuration = try? JSONDecoder().decode(ShortcutConfiguration.self, from: data),
              configuration.validationMessage == nil else { return .defaults }
        // Older versions also stored a scrolling binding. Ignore/remove only that retired field.
        if let legacy = try? JSONSerialization.jsonObject(with: data) as? [String: Any], legacy["scrolling"] != nil,
           let migrated = try? JSONEncoder().encode(configuration) { defaults.set(migrated, forKey: Self.key) }
        return configuration
    }
    public func save(_ configuration: ShortcutConfiguration) throws {
        if let message = configuration.validationMessage { throw ShortcutChangeError(message: message) }
        defaults.set(try JSONEncoder().encode(configuration), forKey: Self.key)
    }
}

public struct ShortcutChangeError: LocalizedError {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Registration IDs are never reused during a session, so queued events from an old binding are ignored.
public final class ShortcutRegistry {
    public private(set) var configuration: ShortcutConfiguration
    public private(set) var failures: [CaptureShortcutAction: Int32] = [:]
    public private(set) var suspended = false
    private let register: (CaptureShortcut, UInt32) -> Int32
    private let unregister: (UInt32) -> Void
    private var bindings: [UInt32: CaptureShortcutAction] = [:]
    private var sequence: UInt32 = 0
    public init(configuration: ShortcutConfiguration, register: @escaping (CaptureShortcut, UInt32) -> Int32, unregister: @escaping (UInt32) -> Void) {
        self.configuration = configuration; self.register = register; self.unregister = unregister
    }
    public func start() { unbind(); if !suspended { bind(configuration) } }
    public func suspend() { suspended = true; unbind() }
    public func resume() { guard suspended else { return }; suspended = false; bind(configuration) }
    public func action(for id: UInt32) -> CaptureShortcutAction? { suspended ? nil : bindings[id] }
    public func action(for shortcut: CaptureShortcut) -> CaptureShortcutAction? {
        guard !suspended else { return nil }
        return bindings.values.first { configuration[$0] == shortcut }
    }
    public func apply(_ candidate: ShortcutConfiguration) throws {
        if let message = candidate.validationMessage { throw ShortcutChangeError(message: message) }
        guard !suspended else { throw ShortcutChangeError(message: "请先完成快捷键录入。") }
        let previousFailures = failures
        let changed = Set(CaptureShortcutAction.allCases.filter { candidate[$0] != configuration[$0] })
        unbind(); bind(candidate)
        // Allow users to repair bindings one at a time when other unchanged bindings were already unavailable.
        let newFailures = failures.keys.filter { changed.contains($0) || previousFailures[$0] == nil }
        if !newFailures.isEmpty {
            let failedActions = CaptureShortcutAction.allCases.filter { newFailures.contains($0) }.map(\.title).joined(separator: "、")
            unbind(); bind(configuration)
            let recovery = failures.isEmpty ? "原快捷键已恢复，修改未保存。" : "原设置已保留，但部分快捷键暂时无法恢复，请查看下方提示。"
            throw ShortcutChangeError(message: "\(failedActions)无法注册，可能已被系统或其他应用占用。\(recovery)")
        }
        configuration = candidate
    }
    private func bind(_ configuration: ShortcutConfiguration) {
        failures = [:]
        for action in CaptureShortcutAction.allCases {
            guard let shortcut = configuration[action] else { continue }
            sequence &+= 1
            let status = register(shortcut, sequence)
            if status == 0 { bindings[sequence] = action } else { failures[action] = status }
        }
    }
    private func unbind() { let ids = Array(bindings.keys); bindings.removeAll(); ids.forEach(unregister) }
    deinit { unbind() }
}
