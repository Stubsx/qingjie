import AppKit
import ScreenCaptureKit
import QingJieCore

enum RecordingChecks {
    @MainActor static func run() throws {
        let suite = "QingJie.recordingChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = RecordingSettings(defaults: defaults)
        settings.options.systemAudio = true; settings.options.microphone = true
        settings.options.resolution = .uhd; settings.options.frameRate = 60
        try SmokeTest.require(RecordingSettings(defaults: defaults).options == settings.options, "录屏画质与两个声音开关独立保存")

        let service = RecordingService(settings: settings)
        var delayedSelection: ((RecordingTarget?) -> Void)?
        var cancellations = 0
        service.selectTarget = { delayedSelection = $0 }
        service.cancelSelection = { cancellations += 1 }
        if #available(macOS 15.0, *) {
            service.toggle()
            try SmokeTest.require(service.phase == .selecting && service.busy, "快捷键从空闲进入录屏选择")
            service.toggle()
            try SmokeTest.require(service.phase == .idle && !service.busy && cancellations == 1, "再次触发可以取消尚未开始的录屏")
            let target = RecordingTarget(displayID: 1, displayFrame: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 2,
                                         rect: CGRect(x: 20, y: 30, width: 400, height: 300), windowID: nil, title: "测试")
            delayedSelection?(target)
            try SmokeTest.require(service.phase == .idle && service.target == nil, "异步选区结果不会在取消后重新打开录屏")
            let config = NativeRecordingEngine.configuration(options: settings.options, sourceSize: CGSize(width: 5120, height: 2880), sourceRect: target.rect)
            try SmokeTest.require(config.width == 3840 && config.height == 2160 && config.sourceRect == target.rect, "录屏保留选区坐标并按 4K 输出")
            try SmokeTest.require(config.minimumFrameInterval.value == 1 && config.minimumFrameInterval.timescale == 60, "60 帧设置传递到屏幕采样器")
            try SmokeTest.require(config.capturesAudio && config.captureMicrophone && config.excludesCurrentProcessAudio, "系统声音与麦克风可同时录入并排除轻截提示音")
            try SmokeTest.require(config.showMouseClicks && config.pixelFormat == kCVPixelFormatType_32BGRA, "点击圆环使用系统支持的像素格式写入视频")
            settings.options.systemAudio = false; settings.options.microphone = false
            settings.options.mouseClicks = false; settings.options.showsCursor = false
            let silent = NativeRecordingEngine.configuration(options: settings.options, sourceSize: CGSize(width: 800, height: 600))
            try SmokeTest.require(!silent.capturesAudio && !silent.captureMicrophone && !silent.showMouseClicks && !silent.showsCursor, "关闭声音与鼠标选项后不会继续采集")
        }

        let view = SelectionView(image: DemoImage.make(), size: CGSize(width: 800, height: 600))
        view.enableRecordingSelection()
        var selected: CGRect?, selectedID: UInt32?, didCancel = false
        view.onTargetFinish = { rect, id in selected = rect; selectedID = id; didCancel = rect == nil }
        let full = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                   context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
        view.keyDown(with: full)
        try SmokeTest.require(selected == view.bounds && selectedID == nil, "录屏 F 快捷操作选择整个当前屏幕")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                     context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53)!
        view.keyDown(with: escape)
        try SmokeTest.require(didCancel, "录屏 Esc 将取消传回选择流程")
    }
}
