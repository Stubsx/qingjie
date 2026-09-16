import AppKit
import SwiftUI
import QingJieCore

@MainActor final class RecordingSettings: ObservableObject {
    static let shared = RecordingSettings()
    static let key = "QingJie.recording.options.v1"
    @Published var options: RecordingOptions { didSet { save() } }
    @Published private(set) var directory: URL
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        options = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(RecordingOptions.self, from: $0) }?.validated ?? RecordingOptions()
        directory = defaults.string(forKey: "QingJie.recording.directory").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("轻截", isDirectory: true)
    }
    private func save() {
        if let data = try? JSONEncoder().encode(options.validated) { defaults.set(data, forKey: Self.key) }
    }
    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择录屏保存位置"; panel.prompt = "选择"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.directoryURL = directory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        directory = url
        defaults.set(url.path, forKey: "QingJie.recording.directory")
    }
    func makeOutputURL() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return directory.appendingPathComponent("录屏 \(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6)).mp4")
    }
}

struct RecordingOptionsView: View {
    @ObservedObject var settings: RecordingSettings
    var body: some View {
        VStack(spacing: 0) {
            row("分辨率", detail: "保持画面比例，较小的选区保留原始尺寸。") {
                Picker("分辨率", selection: $settings.options.resolution) {
                    ForEach(RecordingResolution.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 130)
            }
            Divider().padding(.horizontal, 16)
            row("帧率", detail: "更高帧率让动作更流畅。") {
                Picker("帧率", selection: $settings.options.frameRate) {
                    ForEach(RecordingOptions.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                }.labelsHidden().frame(width: 130)
            }
            Divider().padding(.horizontal, 16)
            option("系统声音", detail: "录入应用播放的声音。", value: $settings.options.systemAudio)
            Divider().padding(.horizontal, 16)
            option("麦克风", detail: "使用系统默认麦克风收录你的声音。", value: $settings.options.microphone)
            Divider().padding(.horizontal, 16)
            option("显示鼠标", detail: "在视频中显示鼠标指针。", value: $settings.options.showsCursor)
            Divider().padding(.horizontal, 16)
            option("点击效果", detail: "在视频中用圆环标出鼠标点击。", value: $settings.options.mouseClicks)
        }.background(.white, in: RoundedRectangle(cornerRadius: 12))
    }
    private func option(_ title: String, detail: String, value: Binding<Bool>) -> some View {
        row(title, detail: detail) {
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).tint(Theme.green).accessibilityLabel(title)
        }
    }
    private func row<Control: View>(_ title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control()
        }.padding(16)
    }
}

struct RecordingSettingsView: View {
    @ObservedObject var settings: RecordingSettings = .shared
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("录屏").font(.system(size: 24, weight: .semibold))
            RecordingOptionsView(settings: settings)
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("保存位置").font(.system(size: 13, weight: .medium))
                    Text(settings.directory.path).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        .lineLimit(2).textSelection(.enabled)
                }
                Spacer()
                Button("更改…") { settings.chooseDirectory() }.buttonStyle(ActionButtonStyle())
            }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 12))
            Text("录屏支持 macOS 15 及更新版本；原始尺寸的长边最高为 4096 像素。")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
    }
}
