import AppKit
import AVFoundation
import ScreenCaptureKit
import QingJieCore

struct RecordingTarget {
    let displayID: CGDirectDisplayID
    let displayFrame: CGRect
    let scale: CGFloat
    let rect: CGRect
    let windowID: CGWindowID?
    let title: String
    var windowSize: CGSize? = nil
    var sourceSize: CGSize {
        let size = windowSize ?? rect.size
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

@MainActor protocol RecordingEngine: AnyObject {
    var onStarted: (() -> Void)? { get set }
    var onFinished: ((Result<URL, Error>) -> Void)? { get set }
    var duration: TimeInterval { get }
    func start(target: RecordingTarget, options: RecordingOptions, url: URL) async throws
    func stop() async
}

enum RecordingError: LocalizedError {
    case unavailable, displayChanged, windowGone, microphoneDenied, microphoneMissing, emptyFile
    var errorDescription: String? {
        switch self {
        case .unavailable: return "录屏需要 macOS 15 或更新版本。"
        case .displayChanged: return "显示器或缩放已发生变化，请重新选择录屏范围。"
        case .windowGone: return "所选窗口已关闭或不可录制，请重新选择。"
        case .microphoneDenied: return "麦克风尚未获准使用。请在系统设置的「隐私与安全性 → 麦克风」中允许轻截，或关闭麦克风后重试。"
        case .microphoneMissing: return "未找到可用的麦克风，请连接麦克风或关闭收音后重试。"
        case .emptyFile: return "没有录到有效画面，请重新开始录屏。"
        }
    }
}

/// ScreenCaptureKit records video, system audio and microphone on one system timeline.
/// Its mouse-click effect is encoded into the frames and needs no event-tap permission.
@available(macOS 15.0, *)
@MainActor final class NativeRecordingEngine: NSObject, RecordingEngine, SCRecordingOutputDelegate, SCStreamDelegate {
    var onStarted: (() -> Void)?
    var onFinished: ((Result<URL, Error>) -> Void)?
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var url: URL?
    private var completed = false
    private var stopping = false
    private var stopFailure: Error?
    private var recordingFailure: Error?
    private static let background = CGColor(gray: 0, alpha: 1)
    var duration: TimeInterval {
        let value = output?.recordedDuration.seconds ?? 0
        return value.isFinite ? max(0, value) : 0
    }

    static func configuration(options: RecordingOptions, sourceSize: CGSize, sourceRect: CGRect? = nil) -> SCStreamConfiguration {
        let options = options.validated
        let size = options.resolution.outputSize(for: sourceSize)
        let config = SCStreamConfiguration()
        config.width = Int(size.width); config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(options.frameRate))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.captureDynamicRange = .SDR
        config.showsCursor = options.showsCursor; config.showMouseClicks = options.mouseClicks
        config.capturesAudio = options.systemAudio; config.captureMicrophone = options.microphone
        config.sampleRate = 48_000; config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        config.scalesToFit = true; config.preservesAspectRatio = true
        config.ignoreShadowsSingleWindow = true
        config.queueDepth = 5
        config.backgroundColor = background
        if let sourceRect { config.sourceRect = sourceRect }
        return config
    }

    func start(target: RecordingTarget, options: RecordingOptions, url: URL) async throws {
        self.url = url
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        let filter: SCContentFilter
        let config: SCStreamConfiguration
        if let windowID = target.windowID {
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw RecordingError.windowGone }
            filter = SCContentFilter(desktopIndependentWindow: window)
            config = Self.configuration(options: options,
                                        sourceSize: CGSize(width: filter.contentRect.width * CGFloat(filter.pointPixelScale),
                                                           height: filter.contentRect.height * CGFloat(filter.pointPixelScale)))
        } else {
            guard let display = content.displays.first(where: { $0.displayID == target.displayID }),
                  let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == target.displayID }),
                  screen.frame == target.displayFrame, screen.backingScaleFactor == target.scale else { throw RecordingError.displayChanged }
            // Resolve after the HUD exists so none of our controls enter the video.
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
            filter = ownApps.isEmpty ? SCContentFilter(display: display, excludingWindows: ownWindows)
                : SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            config = Self.configuration(options: options, sourceSize: target.sourceSize, sourceRect: target.rect)
        }
        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL = url; recordingConfig.videoCodecType = .h264; recordingConfig.outputFileType = .mp4
        let output = SCRecordingOutput(configuration: recordingConfig, delegate: self)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addRecordingOutput(output)
        self.output = output; self.stream = stream
        do { try await stream.startCapture() }
        catch {
            recordingFailure = error
            await stop()
            throw error
        }
    }

    func stop() async {
        guard !stopping, !completed, let stream else { return }
        stopping = true
        do { try await stream.stopCapture() }
        catch {
            // Removing the output also finalizes its file if capture already stopped.
            stopFailure = error
            do { if let output { try stream.removeRecordingOutput(output) } }
            catch { complete(.failure(error)) }
        }
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in guard let self, !completed else { return }; onStarted?() }
    }
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self, let url else { return }
            if let recordingFailure { complete(.failure(recordingFailure)); return }
            do {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                let video = try await asset.loadTracks(withMediaType: .video)
                guard duration.seconds > 0, !video.isEmpty else { throw RecordingError.emptyFile }
                if let recordingFailure { complete(.failure(recordingFailure)) }
                else { complete(.success(url)) }
            } catch { complete(.failure(stopFailure ?? error)) }
        }
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            recordingFailure = error
            // Always release screen and microphone capture even if the disk fills up.
            await stop()
            complete(.failure(error))
        }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, !completed else { return }
            stopFailure = error
            await stop()
        }
    }
    private func complete(_ result: Result<URL, Error>) {
        guard !completed else { return }
        completed = true
        onFinished?(result)
        stream = nil; output = nil
    }
}
