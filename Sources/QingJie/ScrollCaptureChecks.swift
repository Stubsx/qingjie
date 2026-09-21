import AppKit
import ImageIO
import QingJieCore

extension SmokeTest {
    @MainActor static func checkScrollControls() async throws {
        let source = DemoScrollSource()
        var completed: CGImage?
        let session = try ScrollCaptureSession(first: source.frame(), isDemo: true,
                                              captureFrame: { source.frame() }, onCopiedPNG: { url in
            guard let file = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(file, 0, nil) else { return false }
            completed = image; return true
        }, onComplete: { completed = $0 })
        var advances = 0
        session.state.onAdvance = { advances += 1; source.advance() }
        session.state.onAutoScroll?()
        for _ in 0..<500 {
            if !session.state.autoScrolling { break }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        try require(!session.state.autoScrolling && source.offset == source.document.height - source.viewportHeight,
                    "自动滚动连续推进到页尾并在画面不再变化时停止")
        try require(session.state.height == source.document.height && session.state.count > 1,
                    "自动滚动逐帧拼接且保留不足一屏的末尾")
        session.finish()
        for _ in 0..<250 {
            if completed != nil || !session.state.finishing { break }; try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let completed, let actual = Raster.render(base: completed, marks: []),
              let expected = Raster.render(base: source.document, marks: []) else {
            throw Failure(description: "自动滚动成品未交付：\(session.state.note)")
        }
        // Compare pixels, not PNG container metadata; both delivery paths are valid.
        try require(actual.width == expected.width && actual.height == expected.height
                    && actual.dataProvider?.data as Data? == expected.dataProvider?.data as Data?,
                    "自动滚动成品与完整原文逐像素一致")
        let stoppedAdvances = advances
        session.state.onAutoScroll?()
        try require(!session.state.autoScrolling && advances == stoppedAdvances, "关闭后的长截图不会再次滚动")

        let still = source.frame()
        let paused = try ScrollCaptureSession(first: still, isDemo: true, captureFrame: { still }, onComplete: { _ in })
        var pulses = 0
        paused.state.onAdvance = { pulses += 1 }
        paused.state.onAutoScroll?()
        for _ in 0..<100 {
            if pulses > 0 { break }; try await Task.sleep(nanoseconds: 20_000_000)
        }
        paused.state.onPause?()
        let beforePause = pulses
        try await Task.sleep(nanoseconds: 900_000_000)
        try require(paused.state.paused && !paused.state.autoScrolling && pulses == beforePause,
                    "暂停立即停止自动滚动且没有残留滚动事件")
        paused.state.onAutoScroll?(); paused.state.onCrop?()
        for _ in 0..<100 {
            if !paused.state.preparingCrop { break }; try await Task.sleep(nanoseconds: 20_000_000)
        }
        try require(paused.state.cropping && !paused.state.autoScrolling, "裁剪前停止自动滚动")
        paused.state.onCrop?(); paused.state.onAutoScroll?()
        for _ in 0..<100 {
            if pulses > beforePause { break }; try await Task.sleep(nanoseconds: 20_000_000)
        }
        try require(paused.state.autoScrolling && !paused.state.paused && pulses > beforePause,
                    "取消裁剪后可重新启动自动滚动与采集")
        paused.cancel()
        let beforeCancel = pulses
        try await Task.sleep(nanoseconds: 900_000_000)
        try require(!paused.state.autoScrolling && pulses == beforeCancel, "取消后停止采集与自动滚动")

        var escapes = 0
        let monitor = ScrollEscapeMonitor { escapes += 1 }
        try require(monitor.start(), "Esc 全局快捷键注册成功，无需额外键盘监听授权")
        ScrollEscapeMonitor.sendEscapeForVerification()
        try require(escapes == 1, "Esc 通过系统全局事件入口送达")
        monitor.stop(); ScrollEscapeMonitor.sendEscapeForVerification()
        try require(escapes == 1, "退出后释放 Esc，不继续拦截其他应用")
        guard let screen = NSScreen.main else { throw Failure(description: "Esc 会话检查需要显示器") }
        var cancellations = 0
        let escaping = try ScrollCaptureSession(first: still, isDemo: true, captureFrame: { still },
                                               onComplete: { if $0 == nil { cancellations += 1 } })
        escaping.start(screen: screen, selection: CGRect(x: 100, y: 100, width: 400, height: 300))
        escaping.state.onAutoScroll?()
        ScrollEscapeMonitor.sendEscapeForVerification()
        ScrollEscapeMonitor.sendEscapeForVerification()
        try require(cancellations == 1 && !escaping.state.autoScrolling, "Esc 退出整个长截图并清理滚动任务，重复按键只取消一次")
    }
}
