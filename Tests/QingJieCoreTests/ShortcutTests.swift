import XCTest
@testable import QingJieCore

final class ShortcutTests: XCTestCase {
    final class Backend {
        var installed: [UInt32: CaptureShortcut] = [:]
        var occupied: Set<CaptureShortcut> = []
        var afterFailure: (() -> Void)?
        func register(_ shortcut: CaptureShortcut, id: UInt32) -> Int32 {
            if occupied.contains(shortcut) || installed.values.contains(shortcut) { afterFailure?(); return -9878 }
            installed[id] = shortcut; return 0
        }
        func unregister(_ id: UInt32) { installed.removeValue(forKey: id) }
        func registry(_ config: ShortcutConfiguration = .defaults) -> ShortcutRegistry {
            ShortcutRegistry(configuration: config, register: { self.register($0, id: $1) }, unregister: { self.unregister($0) })
        }
    }
    let custom = CaptureShortcut(keyCode: 35, modifiers: [.control, .option])
    func testDefaultShortcutsAndModifierOrdering() {
        XCTAssertNil(ShortcutConfiguration.defaults.validationMessage)
        XCTAssertEqual(ShortcutConfiguration.defaults.region?.display, "⌥⇧A")
        XCTAssertEqual(CaptureShortcut(keyCode: 35, modifiers: .all).display, "⌃⌥⇧⌘P")
    }
    func testControlCommandAIsNotConfusedWithSelectAll() throws {
        let shortcut = CaptureShortcut(keyCode: 0, modifiers: [.control, .command])
        XCTAssertNil(shortcut.validationMessage)
        XCTAssertNotNil(CaptureShortcut(keyCode: 0, modifiers: .command).validationMessage)
        XCTAssertEqual(shortcut.display, "⌃⌘A")
        let backend = Backend(), registry = backend.registry()
        registry.start()
        var config = ShortcutConfiguration.defaults; config.region = shortcut
        try registry.apply(config)
        XCTAssertEqual(registry.action(for: shortcut), .region)
        XCTAssertNil(registry.action(for: ShortcutConfiguration.defaults.region!))
        let suite = "QingJie.tests.\(UUID().uuidString)"
        let isolated = UserDefaults(suiteName: suite)!
        defer { isolated.removePersistentDomain(forName: suite) }
        try ShortcutStore(defaults: isolated).save(config)
        XCTAssertEqual(ShortcutStore(defaults: isolated).load(), config)
    }
    func testInvalidAndDuplicateCombinationsAreRejected() {
        XCTAssertNotNil(CaptureShortcut(keyCode: 35, modifiers: .shift).validationMessage)
        XCTAssertNotNil(CaptureShortcut(keyCode: 53, modifiers: .option).validationMessage)
        XCTAssertNotNil(CaptureShortcut(keyCode: 12, modifiers: .command).validationMessage)
        XCTAssertNotNil(CaptureShortcut(keyCode: 35, modifiers: .init(rawValue: 128)).validationMessage)
        var config = ShortcutConfiguration.defaults; config.fullscreen = config.region
        XCTAssertNotNil(config.validationMessage)
    }
    func testSavedSettingsSurviveReloadIncludingDisabledBinding() throws {
        let suite = "QingJie.tests.\(UUID().uuidString)"
        // Use an isolated suite, never the app's actual preferences.
        let isolated = UserDefaults(suiteName: suite)!
        defer { isolated.removePersistentDomain(forName: suite) }
        let store = ShortcutStore(defaults: isolated)
        XCTAssertEqual(store.load(), .defaults)
        var config = ShortcutConfiguration.defaults; config.region = custom; config.fullscreen = nil
        try store.save(config)
        XCTAssertEqual(ShortcutStore(defaults: UserDefaults(suiteName: suite)!).load(), config)
        var invalid = config; invalid.fullscreen = custom
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(store.load(), config)
    }
    func testMalformedPreferencesFallBackToDefaults() {
        let suite = "QingJie.tests.\(UUID().uuidString)"
        let isolated = UserDefaults(suiteName: suite)!
        defer { isolated.removePersistentDomain(forName: suite) }
        isolated.set(Data("not json".utf8), forKey: ShortcutStore.key)
        XCTAssertEqual(ShortcutStore(defaults: isolated).load(), .defaults)
    }
    func testRecordingSuspendsTriggersAndOldEventsStayInvalidAfterResume() {
        let backend = Backend()
        let active = backend.registry(); active.start()
        let oldIDs = Array(backend.installed.keys)
        XCTAssertEqual(oldIDs.count, 2)
        active.suspend(); XCTAssertTrue(backend.installed.isEmpty)
        XCTAssertTrue(oldIDs.allSatisfy { active.action(for: $0) == nil })
        active.resume(); XCTAssertEqual(backend.installed.count, 2)
        XCTAssertTrue(oldIDs.allSatisfy { active.action(for: $0) == nil })
        XCTAssertEqual(Set(backend.installed.keys.compactMap { active.action(for: $0) }), Set(CaptureShortcutAction.allCases))
    }
    func testBindingSwapAndRepeatedStartDoNotLeakRegistrations() throws {
        let backend = Backend(), config = ShortcutConfiguration.defaults
        let registry = backend.registry(); registry.start()
        var swapped = config; swapped.region = config.fullscreen; swapped.fullscreen = config.region
        try registry.apply(swapped)
        XCTAssertEqual(registry.configuration, swapped)
        for (id, shortcut) in backend.installed { XCTAssertEqual(swapped[registry.action(for: id)!], shortcut) }
        registry.start(); XCTAssertEqual(backend.installed.count, 2)
    }
    func testConflictRollsBackAndLeavesOriginalSettingsActive() {
        let backend = Backend(), config = ShortcutConfiguration.defaults
        let registry = backend.registry(); registry.start()
        let oldIDs = Array(backend.installed.keys)
        backend.occupied.insert(custom)
        var new = config; new.region = custom
        XCTAssertThrowsError(try registry.apply(new))
        XCTAssertEqual(registry.configuration, config)
        XCTAssertTrue(registry.failures.isEmpty)
        XCTAssertEqual(Set(backend.installed.values), Set(CaptureShortcutAction.allCases.compactMap { config[$0] }))
        XCTAssertTrue(oldIDs.allSatisfy { registry.action(for: $0) == nil })
    }
    func testRollbackFailureIsReportedWithoutClaimingBindingWorks() {
        let backend = Backend()
        let active = backend.registry(); active.start()
        backend.occupied.insert(custom)
        backend.afterFailure = { backend.occupied.insert(ShortcutConfiguration.defaults.region!) }
        var new = ShortcutConfiguration.defaults; new.region = custom
        XCTAssertThrowsError(try active.apply(new))
        XCTAssertEqual(active.configuration, .defaults)
        XCTAssertNotNil(active.failures[.region])
        XCTAssertFalse(backend.installed.keys.contains { active.action(for: $0) == .region })
        backend.afterFailure = nil
    }
    func testClearingAndRestoringDefaults() throws {
        let backend = Backend()
        let active = backend.registry(); active.start()
        var config = ShortcutConfiguration.defaults; config.fullscreen = nil
        try active.apply(config); XCTAssertEqual(backend.installed.count, 1)
        XCTAssertNil(active.configuration.fullscreen)
        try active.apply(.defaults); XCTAssertEqual(backend.installed.count, 2)
    }
    func testChangesCannotCommitWhileRecorderIsActive() {
        let registry = Backend().registry()
        registry.start(); registry.suspend()
        XCTAssertThrowsError(try registry.apply(.defaults))
        XCTAssertTrue(registry.suspended)
    }
    func testUnavailableStartupBindingsCanBeRepairedOneAtATime() throws {
        let backend = Backend()
        backend.occupied = Set(CaptureShortcutAction.allCases.compactMap { ShortcutConfiguration.defaults[$0] })
        let registry = backend.registry(); registry.start()
        XCTAssertEqual(registry.failures.count, 2)
        var repaired = ShortcutConfiguration.defaults; repaired.region = custom
        try registry.apply(repaired)
        XCTAssertEqual(registry.configuration, repaired)
        XCTAssertEqual(registry.failures.count, 1)
        XCTAssertEqual(backend.installed.values.first, custom)
        repaired.fullscreen = nil; try registry.apply(repaired)
        XCTAssertEqual(registry.failures.count, 0)
        XCTAssertNil(registry.configuration.fullscreen)
    }
    func testAppLocalDispatchOnlyUsesActiveBindings() throws {
        let backend = Backend(), config = ShortcutConfiguration.defaults
        let registry = backend.registry(); registry.start()
        XCTAssertEqual(registry.action(for: config.region!), .region)
        registry.suspend(); XCTAssertNil(registry.action(for: config.region!))
        registry.resume()
        var changed = config; changed.region = custom
        try registry.apply(changed)
        XCTAssertNil(registry.action(for: config.region!))
        XCTAssertEqual(registry.action(for: custom), .region)
    }
    func testLegacyScrollingBindingIsRetiredWithoutResettingOtherShortcuts() throws {
        let suite = "QingJie.tests.\(UUID().uuidString)", retired = CaptureShortcut(keyCode: 37, modifiers: [.option, .shift])
        let isolated = UserDefaults(suiteName: suite)!
        defer { isolated.removePersistentDomain(forName: suite) }
        let expected = ShortcutConfiguration(region: custom, fullscreen: nil)
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as! [String: Any]
        old["scrolling"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(retired))
        isolated.set(try JSONSerialization.data(withJSONObject: old), forKey: ShortcutStore.key)
        let migrated = ShortcutStore(defaults: isolated).load()
        XCTAssertEqual(migrated, expected)
        let persisted = try JSONSerialization.jsonObject(with: isolated.data(forKey: ShortcutStore.key)!) as! [String: Any]
        XCTAssertNil(persisted["scrolling"])
        let backend = Backend(); backend.occupied.insert(retired)
        let registry = backend.registry(migrated); registry.start()
        XCTAssertNil(registry.action(for: retired))
        XCTAssertTrue(registry.failures.isEmpty)
        XCTAssertEqual(Set(backend.installed.values), [custom])
        XCTAssertEqual(CaptureShortcutAction.allCases, [.region, .fullscreen])
    }
    func testInvalidRetiredBindingCannotInvalidateValidCurrentSettings() throws {
        let suite = "QingJie.tests.\(UUID().uuidString)"
        let isolated = UserDefaults(suiteName: suite)!
        defer { isolated.removePersistentDomain(forName: suite) }
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ShortcutConfiguration.defaults)) as! [String: Any]
        old["scrolling"] = ["invalid": "old field"]
        isolated.set(try JSONSerialization.data(withJSONObject: old), forKey: ShortcutStore.key)
        XCTAssertEqual(ShortcutStore(defaults: isolated).load(), .defaults)
    }
}
