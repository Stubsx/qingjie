import AppKit
import UniformTypeIdentifiers
import QingJieCore

/// A successfully delivered screenshot, with its final annotations and appearance.
enum ScreenshotOutput {
    case copied(CGImage)
    case copiedPNG(URL)
    case saved(URL)
}

enum ScreenshotFileFormat: CaseIterable {
    case png, jpeg, pdf
    var contentType: UTType { switch self { case .png: .png; case .jpeg: .jpeg; case .pdf: .pdf } }
    var suffix: String { switch self { case .png: "png"; case .jpeg: "jpg"; case .pdf: "pdf" } }
    var title: String {
        switch self {
        case .png: "PNG（无损，支持透明）"
        case .jpeg: "JPEG（文件更小）"
        case .pdf: "PDF（自动分页）"
        }
    }
    static func forURL(_ url: URL) -> Self {
        switch url.pathExtension.lowercased() { case "pdf": .pdf; case "jpg", "jpeg": .jpeg; default: .png }
    }
}

/// The save panel chooses the format before potentially expensive encoding starts.
final class ScreenshotSaver {
    enum Outcome { case saved(URL), cancelled, failed(String) }
    private var panel: NSSavePanel?
    private var exportTask: Task<Void, Never>?
    private static let folderKey = "QingJie.lastScreenshotFolder"

    @MainActor func presentExport(formats: [ScreenshotFileFormat], onWriting: @escaping (ScreenshotFileFormat) -> Void = { _ in },
                                 writer: @escaping (URL) async throws -> Void, completion: @escaping (Outcome) -> Void) {
        guard panel == nil, exportTask == nil, let initial = formats.first else { return }
        let save = NSSavePanel()
        save.allowedContentTypes = [initial.contentType]; save.isExtensionHidden = false
        save.title = "截图另存为"; save.prompt = "保存"; save.canCreateDirectories = true
        let date = DateFormatter(); date.dateFormat = "yyyyMMdd-HHmmss-SSS"
        save.nameFieldStringValue = "轻截-\(date.string(from: Date())).\(initial.suffix)"
        if let path = UserDefaults.standard.string(forKey: Self.folderKey), FileManager.default.fileExists(atPath: path) {
            save.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        save.accessoryView = SaveFormatAccessory(panel: save, formats: formats)
        panel = save; NSApp.activate(ignoringOtherApps: true)
        save.begin { [weak self] response in
            guard let self else { return }
            panel = nil; save.orderOut(nil)
            guard response == .OK, let url = save.url else { completion(.cancelled); return }
            onWriting(ScreenshotFileFormat.forURL(url))
            exportTask = Task { @MainActor [weak self] in
                let work = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); try await writer(url) }
                do {
                    try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                    self?.exportTask = nil
                    UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: Self.folderKey)
                    completion(.saved(url))
                } catch is CancellationError {
                    self?.exportTask = nil; completion(.cancelled)
                } catch {
                    self?.exportTask = nil; completion(.failed(error.localizedDescription))
                }
            }
        }
    }
    @MainActor func cancel() { panel?.cancel(nil); panel = nil; exportTask?.cancel(); exportTask = nil }

    @MainActor func presentPNG(_ file: ScrollPNGFile, completion: @escaping (Outcome) -> Void) {
        presentExport(formats: [.png], writer: { try Self.copyFile(file.url, to: $0) }, completion: completion)
    }

    static func copyFile(_ source: URL, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".qingjie-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        // A failed copy leaves an existing destination untouched.
        guard rename(temporary.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    @MainActor func present(_ image: CGImage, appearance: ScreenshotAppearance = .init(), pixelsPerPoint: CGFloat = 1,
                             completion: @escaping (Outcome) -> Void) {
        presentExport(formats: ScreenshotFileFormat.allCases, writer: { url in
            try Self.write(image, to: url, appearance: appearance, pixelsPerPoint: pixelsPerPoint)
        }, completion: completion)
    }
    static func write(_ image: CGImage, to url: URL, appearance: ScreenshotAppearance = .init(), pixelsPerPoint: CGFloat = 1) throws {
        if ScreenshotFileFormat.forURL(url) == .pdf {
            try ScreenshotPDF.write(image, to: url) { try Task.checkCancellation() }; return
        }
        let type: NSBitmapImageRep.FileType = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png
        let output = type == .png ? try appearance.render(image, pixelsPerPoint: pixelsPerPoint) : image
        guard let data = NSBitmapImageRep(cgImage: output).representation(using: type, properties: [.compressionFactor: 0.95]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }
}

private final class SaveFormatAccessory: NSView {
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private weak var panel: NSSavePanel?
    private let formats: [ScreenshotFileFormat]
    init(panel: NSSavePanel, formats: [ScreenshotFileFormat]) {
        self.panel = panel; self.formats = formats
        super.init(frame: CGRect(x: 0, y: 0, width: 360, height: 56))
        autoresizingMask = [.width]

        let label = NSTextField(labelWithString: "文件格式：")
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.alignment = .right
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        popup.font = label.font
        popup.controlSize = .regular
        popup.addItems(withTitles: formats.map(\.title))
        popup.setAccessibilityLabel("文件格式")

        // The save panel stretches its accessory to the full width in both panel modes.
        // Keep the form row centered inside a padded container instead of at that edge.
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            row.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            popup.widthAnchor.constraint(equalToConstant: 230)
        ])
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
        guard formats.indices.contains(index) else { return }
        let format = formats[index]
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = (panel.nameFieldStringValue as NSString).deletingPathExtension + "." + format.suffix
    }
}
