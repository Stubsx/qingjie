import AppKit
import AVFoundation
import SwiftUI
import QingJieCore

@MainActor final class RecordingService: NSObject, ObservableObject, NSWindowDelegate {
    enum Phase { case idle, selecting, configuring, countdown, starting, recording, finishing, finished, failed }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var countdown = 3
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var target: RecordingTarget?
    @Published private(set) var savedURL: URL?
    @Published private(set) var failure = ""
    @Published private(set) var recoveryURL: URL?
    @Published private(set) var stopReason = ""
    var onChange: (() -> Void)?
    var onSettled: (() -> Void)?
    var selectTarget: ((@escaping (RecordingTarget?) -> Void) -> Void)?
    var cancelSelection: (() -> Void)?
    var finishSelection: (() -> Void)?
    var shortcutLabel: () -> String = { "⌥⇧R" }
    let settings: RecordingSettings
    private var panel: NSPanel?
    private var border: NSPanel?
    private var engine: RecordingEngine?
    private var startTask: Task<Void, Never>?
    private var timer: Timer?
    private var sessionID = UUID()
    private var stopRequested = false
    private var returnApp: NSRunningApplication?
    private var screenObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    var busy: Bool { ![.idle, .finished, .failed].contains(phase) }
    var isWriting: Bool { [.starting, .recording, .finishing].contains(phase) }
    var statusTitle: String {
        switch phase {
        case .recording: return "停止录屏"
        case .finishing: return "正在保存录屏…"
        case .starting: return "正在开始录屏…"
        case .selecting, .configuring, .countdown: return "取消录屏"
        default: return "开始录屏"
        }
    }
    var durationLabel: String {
        let seconds = Int(elapsed)
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    init(settings: RecordingSettings? = nil) {
        self.settings = settings ?? .shared; super.init()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isWriting, let target = self.target, target.windowID == nil else { return }
                let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == target.displayID }
                if screen?.frame != target.displayFrame || screen?.backingScaleFactor != target.scale {
                    self.interruptRecording("显示器发生变化，录制已结束。")
                }
            }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interruptRecording("Mac 进入睡眠，录制已结束。") }
        }
    }
    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    }
    private func interruptRecording(_ reason: String) {
        guard isWriting else { return }
        stopReason = reason
        if phase == .starting { stopRequested = true } else { stop() }
    }

    func toggle() {
        switch phase {
        case .recording: stop()
        case .starting: stopRequested = true
        case .finishing: break
        case .selecting, .configuring, .countdown: cancel()
        default: beginSelection()
        }
    }
    func beginSelection() {
        guard #available(macOS 15.0, *) else { showFailure(RecordingError.unavailable); return }
        if phase == .configuring { cancelSelection?() }
        closePanel()
        savedURL = nil; recoveryURL = nil; failure = ""; stopReason = ""; target = nil; elapsed = 0
        sessionID = UUID(); stopRequested = false
        let id = sessionID
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { returnApp = front }
        setPhase(.selecting)
        selectTarget? { [weak self] target in
            guard let self, sessionID == id, phase == .selecting else { return }
            guard let target else { setPhase(.idle); onSettled?(); return }
            self.target = target
            setPhase(.configuring)
        }
    }
    func updateSelection(_ target: RecordingTarget) {
        guard phase == .configuring else { return }
        self.target = target
    }
    func selectionFailed(_ error: Error) { showFailure(error) }
    func start() {
        guard phase == .configuring, let target else { return }
        guard #available(macOS 15.0, *) else { showFailure(RecordingError.unavailable); return }
        let options = settings.options.validated
        let id = sessionID
        countdown = 0; setPhase(.countdown)
        finishSelection?()
        closePanel(); showPanel(width: 300, height: 58)
        showBorder(target)
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                if options.microphone {
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    var allowed = status == .authorized
                    if status == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .audio) }
                    try Task.checkCancellation()
                    guard allowed else { throw RecordingError.microphoneDenied }
                    guard AVCaptureDevice.default(for: .audio) != nil else { throw RecordingError.microphoneMissing }
                }
                let url = try settings.makeOutputURL()
                recoveryURL = url
                for count in (1...3).reversed() {
                    try Task.checkCancellation()
                    countdown = count
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                try Task.checkCancellation()
                guard sessionID == id else { return }
                let engine = NativeRecordingEngine()
                self.engine = engine
                engine.onStarted = { [weak self] in
                    guard let self, sessionID == id, phase == .starting else { return }
                    setPhase(.recording)
                    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self else { return }; self.elapsed = self.engine?.duration ?? 0
                        }
                    }
                }
                engine.onFinished = { [weak self] result in
                    guard let self, sessionID == id, isWriting else { return }
                    finish(result)
                }
                setPhase(.starting)
                returnApp?.activate(options: [])
                try await engine.start(target: target, options: options, url: url)
                if stopRequested { stop() }
            } catch is CancellationError {
                // The cancel action already restored the UI; no recording was started.
            } catch {
                guard sessionID == id else { return }
                await engine?.stop()
                if sessionID == id, phase != .finished, phase != .failed { showFailure(error) }
            }
            if sessionID == id { startTask = nil }
        }
    }
    func stop() {
        guard [.recording, .starting].contains(phase), let engine else { return }
        setPhase(.finishing)
        Task { await engine.stop() }
    }
    func cancel() {
        guard !isWriting else { stop(); return }
        sessionID = UUID()
        startTask?.cancel(); startTask = nil
        if phase == .selecting || phase == .configuring { cancelSelection?() }
        closePanel(); closeBorder(); target = nil; recoveryURL = nil
        setPhase(.idle); onSettled?()
        returnApp?.activate(options: [])
    }
    /// Quitting waits for the MP4 trailer to be written instead of truncating the file.
    func prepareToQuit() {
        if phase == .starting { stopRequested = true }
        else if phase == .recording { stop() }
        else if !isWriting { cancel() }
    }
    private func finish(_ result: Result<URL, Error>) {
        timer?.invalidate(); timer = nil
        closeBorder()
        elapsed = engine?.duration ?? elapsed
        engine = nil
        switch result {
        case .success(let url):
            savedURL = url; recoveryURL = nil
            setPhase(.finished); closePanel(); showPanel(width: 450, height: 66)
        case .failure(let error): showFailure(error); return
        }
        onSettled?()
    }
    private func showFailure(_ error: Error) {
        timer?.invalidate(); timer = nil; engine = nil; closeBorder()
        failure = error.localizedDescription
        if let recoveryURL, !FileManager.default.fileExists(atPath: recoveryURL.path) { self.recoveryURL = nil }
        setPhase(.failed); closePanel(); showPanel(width: 540, height: 100)
        onSettled?()
    }
    private func setPhase(_ value: Phase) { phase = value; onChange?() }
    private func showPanel(width: CGFloat, height: CGFloat) {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "轻截 · 录屏"; panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true; panel.backgroundColor = .clear
        panel.isOpaque = false; panel.hasShadow = true; panel.delegate = self
        let hosting = NSHostingView(rootView: RecordingStatusToolbar(service: self).preferredColorScheme(.light))
        // Size the host before attaching it; unconstrained text otherwise produces
        // an oversized minimum height on scaled external displays.
        hosting.sizingOptions = []
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
        panel.contentView = hosting
        panel.setContentSize(CGSize(width: width, height: height))
        self.panel = panel
        let screen = NSScreen.screens.first { $0.frame == target?.displayFrame } ?? NSScreen.main
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1000, height: 700)
        let rect = target?.rect ?? CGRect(x: frame.width / 2, y: 30, width: 0, height: 0)
        let placement = CaptureGeometry.toolbarFrame(selection: rect, bounds: frame.size, size: CGSize(width: width, height: height))
        panel.setFrame(CGRect(x: frame.minX + placement.minX, y: frame.maxY - placement.maxY,
                              width: placement.width, height: placement.height), display: true)
        panel.orderFrontRegardless()
    }
    private func closePanel() {
        panel?.delegate = nil; panel?.orderOut(nil); panel?.close(); panel = nil
    }
    private func showBorder(_ target: RecordingTarget) {
        closeBorder()
        guard target.windowID == nil else { return }
        let frame = CGRect(x: target.displayFrame.minX + target.rect.minX,
                           y: target.displayFrame.maxY - target.rect.maxY,
                           width: target.rect.width, height: target.rect.height)
        let border = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        border.isReleasedWhenClosed = false; border.isOpaque = false; border.backgroundColor = .clear
        border.ignoresMouseEvents = true; border.hasShadow = false; border.level = .floating
        border.hidesOnDeactivate = false; border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        border.contentView = RecordingBorderView(frame: CGRect(origin: .zero, size: frame.size))
        self.border = border; border.orderFrontRegardless()
    }
    private func closeBorder() { border?.orderOut(nil); border?.close(); border = nil }
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        panel = nil
        if phase == .configuring { cancel() }
    }
}

private final class RecordingBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.36, green: 0.78, blue: 0.47, alpha: 0.9).setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2; path.stroke()
    }
}
