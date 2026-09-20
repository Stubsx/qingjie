import AppKit
import SwiftUI
import CryptoKit
import QingJieCore

struct HistoryItem: Identifiable {
    var id: String { url.lastPathComponent }
    let url: URL
    let date: Date
    let thumbnail: NSImage
    var pageCount: Int? = nil
    var isPDF: Bool { url.pathExtension.lowercased() == "pdf" }
}

enum HomePage: String, CaseIterable {
    case workbench = "工作台"
    case history = "最近截图"
    case guide = "使用指南"
    case settings = "设置"

    var icon: String {
        switch self {
        case .workbench: "square.grid.2x2"
        case .history: "clock.arrow.circlepath"
        case .guide: "book.closed"
        case .settings: "gearshape"
        }
    }
}

final class AppState: ObservableObject {
    @Published var history: [HistoryItem] = []
    @Published var hasPermission = CGPreflightScreenCaptureAccess()
    @Published var page = HomePage.workbench
    @Published var notice = ""
    @Published var hotKeyFailed = false
    @Published var recordingTitle = "开始录屏"
    @Published var recordingBusy = false
    @Published var shortcutConfiguration = ShortcutConfiguration.defaults
    func shortcutLabel(_ action: CaptureShortcutAction) -> String { shortcutConfiguration[action]?.display ?? "未设置" }
    var capture: ((CaptureMode) -> Void)?
    var recordScreen: (() -> Void)?
    var importImage: (() -> Void)?
    var openHistory: ((URL) -> Void)?
    var showDemo: (() -> Void)?
    var showScrollDemo: (() -> Void)?
    var requestPermission: (() -> Void)?
    private var lastDigest = ""
    let historyDirectory: URL

    init(historyDirectory: URL? = nil) {
        self.historyDirectory = historyDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QingJie/History", isDirectory: true)
        reloadHistory()
    }
    func reloadHistory() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: historyDirectory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        history = urls.filter { ["png", "pdf"].contains($0.pathExtension) }.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(30).compactMap { url in
            let thumb: CGImage
            var pageCount: Int?
            if url.pathExtension == "pdf" {
                guard let result = try? ScreenshotPDF.thumbnail(at: url) else { return nil }
                thumb = result.image; pageCount = result.pages
            } else {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let result = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 560] as CFDictionary) else { return nil }
                thumb = result
            }
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            return HistoryItem(url: url, date: date, thumbnail: NSImage(cgImage: thumb, size: .zero), pageCount: pageCount)
        }
    }
    func remember(_ output: ScreenshotOutput) {
        switch output {
        case .copied(let image): remember(image)
        case .copiedPNG(let url):
            do { try rememberFile(url) }
            catch { notice = "截图已复制，但最近记录保存失败：\(error.localizedDescription)" }
        case .saved(let url):
            do {
                // Keep the complete exported document or PNG as the history item.
                if ["png", "pdf"].contains(url.pathExtension.lowercased()) {
                    try rememberFile(url)
                } else {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }
                    remember(image)
                }
            } catch { notice = "截图已保存，但最近记录保存失败：\(error.localizedDescription)" }
        }
    }
    func remember(_ image: CGImage) {
        guard let data = Raster.png(image) else { notice = "截图已处理，但无法生成最近记录。"; return }
        do { try rememberPNG(data) }
        catch { notice = "截图已处理，但最近记录保存失败：\(error.localizedDescription)" }
    }
    private func rememberPNG(_ data: Data) throws {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest != lastDigest else { return }
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let filename = "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6)).png"
        try data.write(to: historyDirectory.appendingPathComponent(filename), options: .atomic)
        lastDigest = digest
        let all = try FileManager.default.contentsOfDirectory(at: historyDirectory, includingPropertiesForKeys: nil)
            .filter { ["png", "pdf"].contains($0.pathExtension) }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in all.dropFirst(30) { try FileManager.default.removeItem(at: old) }
        reloadHistory()
    }
    private func rememberFile(_ source: URL) throws {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let part = try handle.read(upToCount: 1024 * 1024), !part.isEmpty { hasher.update(data: part) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest != lastDigest else { return }
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let suffix = source.pathExtension.lowercased() == "pdf" ? "pdf" : "png"
        let target = historyDirectory.appendingPathComponent("\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6)).\(suffix)")
        try ScreenshotSaver.copyFile(source, to: target)
        lastDigest = digest
        let all = try FileManager.default.contentsOfDirectory(at: historyDirectory, includingPropertiesForKeys: nil)
            .filter { ["png", "pdf"].contains($0.pathExtension) }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in all.dropFirst(30) { try FileManager.default.removeItem(at: old) }
        reloadHistory()
    }
    func revealHistory() {
        do {
            try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(historyDirectory)
        } catch { notice = error.localizedDescription }
    }
    func deleteHistory(_ item: HistoryItem) {
        do { try FileManager.default.removeItem(at: item.url); lastDigest = ""; reloadHistory() }
        catch { notice = error.localizedDescription }
    }
}

enum Theme {
    static let green = Color(red: 0.10, green: 0.32, blue: 0.27)
    static let lime = Color(red: 0.81, green: 0.95, blue: 0.66)
    static let ink = Color(red: 0.12, green: 0.16, blue: 0.15)
    static let secondary = Color(red: 0.45, green: 0.49, blue: 0.47)
    static let background = Color(red: 0.96, green: 0.965, blue: 0.95)
}

struct ActionButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 15).padding(.vertical, 10)
            .foregroundStyle(primary ? Color.white : Theme.ink)
            .background(primary ? Theme.green : Color.white, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(primary ? Color.clear : Color.black.opacity(0.08)))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
