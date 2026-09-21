import AppKit
import Carbon

/// Scoped to a live capture, so Escape works while the source app keeps keyboard focus.
final class ScrollEscapeMonitor {
    private static let signature: OSType = 0x514A4553
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private let onEscape: () -> Void
    init(onEscape: @escaping () -> Void) { self.onEscape = onEscape }

    @discardableResult func start() -> Bool {
        stop()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  let self else { return event }
            onEscape(); return nil
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == ScrollEscapeMonitor.signature, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            Unmanaged<ScrollEscapeMonitor>.fromOpaque(context).takeUnretainedValue().onEscape()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status == noErr,
           RegisterEventHotKey(53, 0, EventHotKeyID(signature: Self.signature, id: 1),
                               GetEventDispatcherTarget(), 0, &hotKey) == noErr { return true }
        // An existing shortcut may own Escape. The passive fallback doesn't claim it.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                self?.onEscape()
            }
        }
        return false
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }; globalMonitor = nil
    }
    deinit { stop() }

    /// Exercise the same dispatcher callback used when another application is in front.
    static func sendEscapeForVerification() {
        var event: EventRef?
        guard CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event) == noErr,
              let event else { return }
        defer { ReleaseEvent(event) }
        var id = EventHotKeyID(signature: signature, id: 1)
        SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          MemoryLayout<EventHotKeyID>.size, &id)
        SendEventToEventTarget(event, GetEventDispatcherTarget())
    }
}

/// A nonactivating panel can still take key focus; live capture controls must not.
final class ScrollCapturePanel: NSPanel {
    var permitsKeyboardFocus: () -> Bool = { false }
    override var canBecomeKey: Bool { permitsKeyboardFocus() }
    override var canBecomeMain: Bool { false }
}

struct ScrollCaptureDestination: Equatable {
    let windowID: CGWindowID
    let processID: pid_t
    let frame: CGRect
}

@MainActor enum ScrollCaptureInput {
    static func requestAccess() -> Bool { CGPreflightPostEventAccess() || CGRequestPostEventAccess() }

    static func destination(at point: CGPoint, excludingPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> ScrollCaptureDestination? {
        guard let window = CaptureService.snapshotWindows().first(where: {
            $0.ownerPID != excludingPID && $0.isOnScreen && $0.alpha > 0.01 && ($0.layer == 0 || $0.layer == 3)
                && $0.frame.contains(point)
        }) else { return nil }
        return ScrollCaptureDestination(windowID: window.id, processID: window.ownerPID, frame: window.frame)
    }

    static func restoreFocus(to destination: ScrollCaptureDestination) {
        NSRunningApplication(processIdentifier: destination.processID)?.activate(options: [])
    }

    static func makeEvent(to destination: ScrollCaptureDestination, at point: CGPoint, points: CGFloat) -> CGEvent? {
        guard point.x.isFinite, point.y.isFinite, points.isFinite, points > 0, points <= 120,
              destination.frame.contains(point),
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: -Int32(points.rounded()), wheel2: 0, wheel3: 0) else { return nil }
        event.location = point
        event.flags = []
        return event
    }

    static func scroll(to destination: ScrollCaptureDestination, at point: CGPoint, points: CGFloat) -> Bool {
        guard CGPreflightPostEventAccess(), self.destination(at: point) == destination,
              let event = makeEvent(to: destination, at: point, points: points),
              let pointer = CGEvent(source: nil)?.location,
              let restorePointer = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                           mouseCursorPosition: pointer, mouseButton: .left) else { return false }
        // WindowServer supplies the window-local coordinates needed by NSScrollView
        // and web views. Direct PID posting skips that annotation and misses content.
        // Posting at a specified location also updates the pointer; restore it next
        // in the same queue, with no delayed warp that could overwrite later input.
        restorePointer.flags = CGEventSource.flagsState(.combinedSessionState)
        event.post(tap: .cgSessionEventTap)
        restorePointer.post(tap: .cgSessionEventTap)
        return true
    }
}
