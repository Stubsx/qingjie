import AppKit
import SwiftUI
import QingJieCore

final class ScreenshotAppearanceSettings: ObservableObject {
    static let shared = ScreenshotAppearanceSettings()
    private let defaults: UserDefaults
    @Published var roundedCorners: Bool { didSet { defaults.set(roundedCorners, forKey: "QingJie.appearance.roundedCorners") } }
    @Published var shadow: Bool { didSet { defaults.set(shadow, forKey: "QingJie.appearance.shadow") } }
    @Published var cornerRadius: CGFloat { didSet { defaults.set(Double(cornerRadius), forKey: "QingJie.appearance.cornerRadius") } }
    @Published var shadowBlur: CGFloat { didSet { defaults.set(Double(shadowBlur), forKey: "QingJie.appearance.shadowBlur") } }
    @Published var shadowOffset: CGFloat { didSet { defaults.set(Double(shadowOffset), forKey: "QingJie.appearance.shadowOffset") } }
    @Published var shadowOpacity: CGFloat { didSet { defaults.set(Double(shadowOpacity), forKey: "QingJie.appearance.shadowOpacity") } }
    var value: ScreenshotAppearance {
        .init(roundedCorners: roundedCorners, shadow: shadow, cornerRadius: cornerRadius,
              shadowBlur: shadowBlur, shadowOffset: shadowOffset, shadowOpacity: shadowOpacity)
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        roundedCorners = defaults.bool(forKey: "QingJie.appearance.roundedCorners")
        shadow = defaults.bool(forKey: "QingJie.appearance.shadow")
        func number(_ key: String, fallback: CGFloat) -> CGFloat {
            guard let number = defaults.object(forKey: "QingJie.appearance." + key) as? NSNumber else { return fallback }
            return CGFloat(number.doubleValue)
        }
        let parameters = ScreenshotAppearance(
            cornerRadius: number("cornerRadius", fallback: ScreenshotAppearance.defaultCornerRadius),
            shadowBlur: number("shadowBlur", fallback: ScreenshotAppearance.defaultShadowBlur),
            shadowOffset: number("shadowOffset", fallback: ScreenshotAppearance.defaultShadowOffset),
            shadowOpacity: number("shadowOpacity", fallback: ScreenshotAppearance.defaultShadowOpacity))
        cornerRadius = parameters.cornerRadius; shadowBlur = parameters.shadowBlur
        shadowOffset = parameters.shadowOffset; shadowOpacity = parameters.shadowOpacity
    }
    func resetParameters() {
        cornerRadius = ScreenshotAppearance.defaultCornerRadius
        shadowBlur = ScreenshotAppearance.defaultShadowBlur
        shadowOffset = ScreenshotAppearance.defaultShadowOffset
        shadowOpacity = ScreenshotAppearance.defaultShadowOpacity
    }
}

struct AppSettingsView: View {
    let hotKeys: HotKeys
    @ObservedObject var appearance: ScreenshotAppearanceSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            AppearanceSettingsView(settings: appearance, onReset: { hotKeys.cancelRecording() })
                .onChange(of: appearance.value) { _, _ in hotKeys.cancelRecording() }
            Divider()
            ShortcutSettingsView(hotKeys: hotKeys)
            Divider()
            RecordingSettingsView()
            Divider()
            GeneralSettingsView()
        }
    }
}

struct AppearanceSettingsView: View {
    @ObservedObject var settings: ScreenshotAppearanceSettings
    var onReset: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("截图美化").font(.system(size: 24, weight: .semibold))
                    Text("调整圆角与阴影，让画面更自然。").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button("恢复默认") { onReset(); settings.resetParameters() }
                    .buttonStyle(ActionButtonStyle())
                    .accessibilityLabel("恢复美化默认参数")
                    .help("恢复 R12、阴影大小 12 pt、偏移 6 pt、浓度 24%，保留开关状态")
            }
            HStack(alignment: .top, spacing: 22) {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 16) {
                        option("圆角矩形", value: $settings.roundedCorners)
                        parameter("圆角大小", value: $settings.cornerRadius,
                                  range: ScreenshotAppearance.cornerRadiusRange, unit: "pt")
                            .disabled(!settings.roundedCorners)
                    }.padding(18)
                    Divider().padding(.horizontal, 18)
                    VStack(alignment: .leading, spacing: 16) {
                        option("窗口阴影", value: $settings.shadow)
                        VStack(spacing: 14) {
                            parameter("阴影大小", value: $settings.shadowBlur,
                                      range: ScreenshotAppearance.shadowBlurRange, unit: "pt")
                            parameter("向下偏移", value: $settings.shadowOffset,
                                      range: ScreenshotAppearance.shadowOffsetRange, unit: "pt")
                            parameter("阴影浓度", value: $settings.shadowOpacity,
                                      range: ScreenshotAppearance.shadowOpacityRange, unit: "%", step: 0.01, multiplier: 100)
                        }.disabled(!settings.shadow)
                    }.padding(18)
                }.frame(maxWidth: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 12))
                preview.frame(width: 250)
            }
            Text("对 PNG 保存与剪贴板复制生效，JPEG 保持矩形；参数自动保存。")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("效果预览").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("PNG").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.secondary)
            }
            ZStack {
                Canvas { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.97)))
                    for y in stride(from: 0, to: Int(size.height), by: 12) {
                        for x in stride(from: 0, to: Int(size.width), by: 12) where (x / 12 + y / 12).isMultiple(of: 2) {
                            context.fill(Path(CGRect(x: x, y: y, width: 12, height: 12)), with: .color(Color(white: 0.93)))
                        }
                    }
                }
                if let image = try? settings.value.render(Self.sample, pixelsPerPoint: CGFloat(Self.sample.width) / 480) {
                    Image(nsImage: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)))
                        .resizable().scaledToFit().padding(14)
                }
            }.frame(height: 218).clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityLabel("圆角与阴影效果预览")
            Text("棋盘格表示透明区域。")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineSpacing(4)
        }
    }
    private func option(_ title: String, value: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 14, weight: .medium))
            Spacer()
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).tint(Theme.green).accessibilityLabel(title)
        }
    }
    private func parameter(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>,
                           unit: String, step: CGFloat = 1, multiplier: CGFloat = 1) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 12)).frame(width: 60, alignment: .leading)
            Slider(value: Binding(get: { value.wrappedValue }, set: {
                value.wrappedValue = min(max(($0 / step).rounded() * step, range.lowerBound), range.upperBound)
            }), in: range).tint(Theme.green).labelsHidden()
                .accessibilityLabel(title)
                .accessibilityValue("\(Int((value.wrappedValue * multiplier).rounded())) \(unit)")
            Text("\(Int((value.wrappedValue * multiplier).rounded())) \(unit)")
                .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Theme.green)
                .frame(width: 48, alignment: .trailing)
        }
    }
    private static let sample: CGImage = {
        let image = NSImage(size: CGSize(width: 480, height: 260))
        image.lockFocus()
        NSColor.white.setFill(); CGRect(x: 0, y: 0, width: 480, height: 260).fill()
        NSColor(white: 0.96, alpha: 1).setFill(); CGRect(x: 0, y: 218, width: 480, height: 42).fill()
        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill(); NSBezierPath(ovalIn: CGRect(x: 16 + i * 19, y: 235, width: 10, height: 10)).fill()
        }
        ("看见重点" as NSString).draw(at: CGPoint(x: 28, y: 159), withAttributes: [.font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor(calibratedRed: 0.1, green: 0.32, blue: 0.27, alpha: 1)])
        ("把清晰的想法，分享出去。" as NSString).draw(at: CGPoint(x: 28, y: 123), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor])
        for (i, width) in [360, 280, 320].enumerated() {
            NSColor(white: 0.92, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: 28, y: 83 - i * 22, width: width, height: 7), xRadius: 3, yRadius: 3).fill()
        }
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }()

    @MainActor static func renderPreview() -> CGImage? {
        let suite = "QingJie.appearance-preview.\(UUID().uuidString)"
        let isolated = UserDefaults(suiteName: suite)!
        defer { isolated.removePersistentDomain(forName: suite) }
        let appearance = ScreenshotAppearanceSettings(defaults: isolated)
        appearance.roundedCorners = true; appearance.shadow = true
        let state = AppState(); state.page = .settings
        let view = NSHostingView(rootView: HomeView(state: state, hotKeys: HotKeys(defaults: isolated), appearance: appearance))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1040, height: 1720), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; view.layoutSubtreeIfNeeded()
        defer { window.close() }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap); return bitmap.cgImage
    }
}
