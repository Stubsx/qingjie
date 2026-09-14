import AppKit

enum DemoImage {
    static func makeLong() -> CGImage {
        let image = NSImage(size: NSSize(width: 720, height: 2600))
        image.lockFocusFlipped(true)
        NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.94, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: 720, height: 2600).fill()
        let ink = NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.25, alpha: 1)
        func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: NSColor = .darkGray) {
            (value as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color])
        }
        text("一张长图，装下完整思路。", 50, 42, 35, ink)
        text("QINGJIE / SCROLL CAPTURE DEMO", 52, 99, 13, .gray)
        let titles = ["周一 · 把灵感记下来", "产品笔记：让操作更顺手", "今天发现的三个小细节", "设计评审：留白与重点", "把沟通中的信息连起来", "周五复盘 · 这周做对了什么", "下一步，继续打磨体验", "记录完成，准备分享"]
        let lines = ["从一个观察开始，慢慢积累想法。", "清晰的入口，明确的反馈，流畅的操作。", "文字要读得清，画面要接得上，输出要完整。", "减少不必要的装饰，让关键信息更突出。", "长内容不必拆成许多图片，前后文可以一起保留。", "停下来回看进度，发现值得继续做好的事情。", "继续测试真实网页、文档与聊天记录。", "这是一张本机生成的练习图片，不包含真实数据。"]
        for index in 0..<8 {
            let y = CGFloat(154 + index * 291)
            NSColor.white.setFill(); NSBezierPath(roundedRect: CGRect(x: 40, y: y, width: 640, height: 261), xRadius: 15, yRadius: 15).fill()
            text(String(format: "%02d", index + 1), 65, y + 18, 14, ink)
            text(titles[index], 65, y + 51, 24, ink)
            text(lines[index], 65, y + 94, 16)
            text("记录编号 QJ-\(2037 + index * 173)     /     \(8 + index):\(12 + index * 5)", 65, y + 128, 13, .gray)
            for bar in 0..<5 {
                let width = CGFloat(70 + ((index * 61 + bar * 43) % 350))
                NSColor(calibratedRed: 0.30 + CGFloat(index) * 0.045, green: 0.62, blue: 0.45, alpha: 0.25 + CGFloat(bar) * 0.12).setFill()
                NSBezierPath(roundedRect: CGRect(x: 65, y: y + 160 + CGFloat(bar * 15), width: width, height: 7), xRadius: 3, yRadius: 3).fill()
            }
        }
        text("END / 完整内容，完整呈现。", 50, 2525, 20, ink)
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    static func make() -> CGImage {
        let image = NSImage(size: NSSize(width: 1440, height: 900))
        image.lockFocusFlipped(true)
        NSColor(calibratedRed: 0.94, green: 0.95, blue: 0.92, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: 1440, height: 900).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: CGRect(x: 110, y: 80, width: 1220, height: 740), xRadius: 26, yRadius: 26).fill()
        let ink = NSColor(calibratedRed: 0.10, green: 0.28, blue: 0.24, alpha: 1)
        func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor = .darkGray, weight: NSFont.Weight = .regular) {
            (value as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        }
        text("QINGJIE  /  A LITTLE MORE CLARITY", x: 175, y: 134, size: 17, color: ink, weight: .medium)
        text("把重点，留在画面里。", x: 175, y: 210, size: 60, color: ink, weight: .semibold)
        text("这是一张练习图片。试试画箭头、添加文字，或框选一块马赛克。", x: 178, y: 315, size: 25)
        for (index, title) in ["捕捉灵感", "标出重点", "即刻分享"].enumerated() {
            let x: CGFloat = 175 + CGFloat(index) * 366
            NSColor(calibratedRed: 0.93, green: 0.96, blue: 0.91, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: x, y: 412, width: 338, height: 210), xRadius: 18, yRadius: 18).fill()
            text("0\(index + 1)", x: x + 28, y: 440, size: 20, color: ink)
            text(title, x: x + 28, y: 495, size: 33, color: ink, weight: .semibold)
            text(["框选 / 全屏 / 导入", "箭头 / 文字 / 马赛克", "复制 / 保存 / 贴图"][index], x: x + 28, y: 555, size: 18)
        }
        text("示例信息：hello@example.com", x: 178, y: 698, size: 23)
        text("所有操作都在本机完成。", x: 178, y: 744, size: 19, color: .gray)
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }
}

final class DemoScrollSource {
    let document = DemoImage.makeLong()
    private(set) var offset = 0
    let viewportHeight = 1100
    func advance() { offset = min(document.height - viewportHeight, offset + 390) }
    func frame() -> CGImage { document.cropping(to: CGRect(x: 0, y: offset, width: document.width, height: viewportHeight))! }
}

/// A desktop-style layout: toolbar and two sidebars stay still while the document moves.
final class DemoChromeScrollSource {
    let source = DemoScrollSource()
    let left = 280, right = 220, top = 96, bottom = 54
    let animatesSidebars: Bool
    private var revision = 0
    init(animatesSidebars: Bool = false) { self.animatesSidebars = animatesSidebars }
    var offset: Int { source.offset }
    var document: CGImage { source.document }
    var viewportHeight: Int { source.viewportHeight }
    var contentRegion: CGRect { CGRect(x: left, y: top, width: document.width, height: viewportHeight) }
    func advance() { source.advance() }
    func frame() -> CGImage { revision += 1; return render(document: source.frame()) }
    func complete() -> CGImage { render(document: document) }

    private func render(document: CGImage) -> CGImage {
        let width = document.width + left + right, height = document.height + top + bottom
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill(); CGRect(x: 0, y: 0, width: width, height: height).fill()
        if animatesSidebars {
            for y in stride(from: top + 4, to: height - bottom - 30, by: 36) {
                let value = (UInt64(y + 17) &* 6364136223846793005) ^ (UInt64(revision + 13) &* 1442695040888963407)
                NSColor(calibratedRed: 0.68 + CGFloat(value % 25) / 100,
                        green: 0.68 + CGFloat((value >> 12) % 25) / 100,
                        blue: 0.68 + CGFloat((value >> 24) % 25) / 100, alpha: 1).setFill()
                CGRect(x: 8, y: y, width: left - 16, height: 30).fill()
                CGRect(x: width - right + 8, y: y, width: right - 16, height: 30).fill()
            }
        }
        func text(_ value: String, x: Int, y: Int, size: CGFloat = 24) {
            (value as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.darkGray])
        }
        text("轻截 · 项目资料 / 固定顶栏", x: left + 35, y: 27, size: 30)
        for (index, title) in ["工作空间", "收件箱", "项目笔记", "设计参考", "最近打开", "已收藏", "团队文档", "归档记录"].enumerated() {
            text(title, x: 35, y: top + 45 + index * 100)
            text("目录 0\(index + 1)", x: width - right + 25, y: top + 45 + index * 100, size: 20)
        }
        text("仅中间文档滚动 · 顶部、目录和侧栏保持固定", x: left + 35, y: height - bottom + 14, size: 20)
        Raster.draw(document, in: CGRect(x: left, y: top, width: document.width, height: document.height), context: context)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }
}
