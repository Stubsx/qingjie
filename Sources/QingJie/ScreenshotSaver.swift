import AppKit
import UniformTypeIdentifiers
import QingJieCore

/// A successfully delivered screenshot, with its final annotations and appearance.
enum ScreenshotOutput {
    case copied(CGImage)
    case saved(URL)
}

/// One save flow for frozen selections, composed long screenshots and imported images.
final class ScreenshotSaver {
    enum Outcome { case saved(URL), cancelled, failed(String) }
    private var panel: NSSavePanel?
    private static let folderKey = "QingJie.lastScreenshotFolder"

    func present(_ image: CGImage, appearance: ScreenshotAppearance = .init(), pixelsPerPoint: CGFloat = 1,
                 completion: @escaping (Outcome) -> Void) {
        guard panel == nil else { return }
        let save = NSSavePanel()
        save.allowedContentTypes = [.png]; save.isExtensionHidden = false
        save.title = "截图另存为"; save.prompt = "保存"; save.canCreateDirectories = true
        let date = DateFormatter(); date.dateFormat = "yyyyMMdd-HHmmss-SSS"
        save.nameFieldStringValue = "轻截-\(date.string(from: Date())).png"
        if let path = UserDefaults.standard.string(forKey: Self.folderKey),
           FileManager.default.fileExists(atPath: path) { save.directoryURL = URL(fileURLWithPath: path, isDirectory: true) }
        save.accessoryView = SaveFormatAccessory(panel: save)
        panel = save
        NSApp.activate(ignoringOtherApps: true)
        save.begin { [weak self] response in
            self?.panel = nil
            save.orderOut(nil)
            guard response == .OK, let url = save.url else { completion(.cancelled); return }
            do {
                try Self.write(image, to: url, appearance: appearance, pixelsPerPoint: pixelsPerPoint)
                UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: Self.folderKey)
                completion(.saved(url))
            } catch { completion(.failed(error.localizedDescription)) }
        }
    }
    static func write(_ image: CGImage, to url: URL, appearance: ScreenshotAppearance = .init(), pixelsPerPoint: CGFloat = 1) throws {
        let type: NSBitmapImageRep.FileType = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png
        let output = type == .png ? try appearance.render(image, pixelsPerPoint: pixelsPerPoint) : image
        guard let data = NSBitmapImageRep(cgImage: output).representation(using: type, properties: [.compressionFactor: 0.95]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }
}

private final class SaveFormatAccessory: NSStackView {
    private let popup = NSPopUpButton(frame: CGRect(x: 0, y: 0, width: 170, height: 28))
    private weak var panel: NSSavePanel?
    init(panel: NSSavePanel) {
        self.panel = panel
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 36))
        popup.addItems(withTitles: ["PNG（无损，支持透明）", "JPEG（文件更小）"])
        orientation = .horizontal; spacing = 10
        addArrangedSubview(NSTextField(labelWithString: "图片格式：")); addArrangedSubview(popup)
        popup.target = self; popup.action = #selector(changeFormat(_:))
        for (index, item) in popup.itemArray.enumerated() {
            item.tag = index; item.target = self; item.action = #selector(changeFormat(_:))
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    @objc private func changeFormat(_ sender: Any?) {
        guard let panel else { return }
        let index = (sender as? NSMenuItem)?.tag ?? popup.indexOfSelectedItem
        popup.selectItem(at: index)
        let jpeg = index == 1
        panel.allowedContentTypes = jpeg ? [.jpeg] : [.png]
        panel.nameFieldStringValue = (panel.nameFieldStringValue as NSString).deletingPathExtension + (jpeg ? ".jpg" : ".png")
    }
}
