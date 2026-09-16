import AppKit
import Foundation
import QingJieCore
import SwiftUI

struct UpdateError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class UpdateSettings: ObservableObject {
    enum Stage: Equatable {
        case idle
        case refreshing
        case downloading(Double)
        case verifying
        case installing
        case restarting
        case failed(String)

        var busy: Bool {
            switch self {
            case .idle, .failed: return false
            default: return true
            }
        }

        var description: String? {
            switch self {
            case .idle, .failed: return nil
            case .refreshing: return "正在获取最新安装信息…"
            case .downloading(let progress): return "正在下载更新… \(Int((progress * 100).rounded()))%"
            case .verifying: return "正在校验安装包完整性…"
            case .installing: return "正在安装到「应用程序」…"
            case .restarting: return "安装完成，正在退出并重启…"
            }
        }
    }

    static let shared = UpdateSettings()
    static let key = "QingJie.general.autoUpdateCheck"
    static let skippedKey = "QingJie.general.skippedUpdate"
    // 发布更新源时同步 scripts/app_identity.py 中的 FEED_GIST。
    static let endpoint = URL(string: "https://gist.githubusercontent.com/Stubsx/6b32edfa0f8eb36dfc5ee9ed2de582be/raw/latest.json")!
    @Published var enabled: Bool {
        didSet {
            guard oldValue != enabled else { return }
            defaults.set(enabled, forKey: Self.key)
            if enabled { Task { await check(notify: true) }; scheduleDaily() } else { stopTimer() }
        }
    }
    @Published private(set) var checking = false
    @Published private(set) var latest: UpdateInfo?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var failure: String?
    @Published private(set) var stage: Stage = .idle
    @Published private(set) var skippedVersion: String?
    var onUpdateFound: ((UpdateInfo) -> Void)?
    private let defaults: UserDefaults
    private var timer: Timer?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        // gist 的 raw 响应带 max-age 缓存；版本检查必须每次拿到最新内容。
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 不走系统代理直连：一次极小的匿名 GET，避免本机代理工具按进程拦截造成超时。
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: Self.key) as? Bool ?? true
        skippedVersion = defaults.string(forKey: Self.skippedKey)
    }

    static var installed: (version: String, build: Int) {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
         Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0)
    }

    /// 构建脚本写入的固定签名校验规则；开发态直接运行的二进制没有该键，不允许安装更新。
    static var pinnedRequirement: String? {
        guard let sha1 = Bundle.main.object(forInfoDictionaryKey: "QingJieCertificateSHA1") as? String,
              sha1.range(of: #"^[A-F0-9]{40}$"#, options: .regularExpression) != nil,
              let identifier = Bundle.main.bundleIdentifier else { return nil }
        return "identifier \"\(identifier)\" and certificate leaf = H\"\(sha1)\""
    }

    static var installDestination: URL {
        URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "QingJieInstallPath") as? String ?? "/Applications/轻截.app", isDirectory: true)
    }

    var updateAvailable: Bool? {
        guard let latest else { return nil }
        return VersionComparison.isNewer(latest.version, build: latest.build,
                                         than: Self.installed.version, installedBuild: Self.installed.build)
    }

    func isSkipped(_ info: UpdateInfo) -> Bool { skippedVersion == info.version }

    func skipCurrentVersion() {
        guard let latest else { return }
        skippedVersion = latest.version
        defaults.set(latest.version, forKey: Self.skippedKey)
    }

    func startAutomaticChecks() {
        guard enabled else { return }
        scheduleDaily()
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await check(notify: true)
        }
    }

    private func scheduleDaily() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(notify: true) }
        }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    /// 匿名读取一次版本信息（无 Cookie、无缓存、不上传任何数据），只做版本号比对。
    func check(notify: Bool = false) async {
        guard !checking, !stage.busy else { return }
        checking = true
        defer { checking = false }
        do {
            let info = try await refreshInfo()
            if case .failed = stage { stage = .idle }
            if notify, updateAvailable == true, !isSkipped(info) { onUpdateFound?(info) }
        } catch {
            failure = "检查更新失败：\(error.localizedDescription)"
        }
    }

    private func refreshInfo() async throws -> UpdateInfo {
        let info = try await UpdateTransport.fetchInfo(from: Self.endpoint, using: session)
        latest = info; lastChecked = Date(); failure = nil
        return info
    }

    func openReleasePage() {
        guard let urlString = latest?.url, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 下载安装包，依次校验 sha256 与固定签名身份，再由独立脚本在退出后整体替换并重启。
    func downloadAndInstall() async {
        guard !stage.busy, !checking, updateAvailable == true else { return }
        guard let requirement = Self.pinnedRequirement else {
            stage = .failed("当前应用没有固定签名信息，无法校验更新包；请使用正式构建手动安装。")
            return
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("qingjie-update-\(UUID().uuidString)", isDirectory: true)
        do {
            // 用户可能在发现更新数小时后才点击安装；不得复用内存中的旧 URL/校验值。
            stage = .refreshing
            let info = try await refreshInfo()
            guard updateAvailable == true else { stage = .idle; return }
            guard let package = info.package else {
                throw UpdateError(message: "该版本没有可用的安装包下载地址，请打开发布页手动更新。")
            }
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            stage = .downloading(0)
            let archive = work.appendingPathComponent("package.zip")
            try await UpdateTransport.download(package, to: archive) { [weak self] value in
                Task { @MainActor in
                    guard let self, case .downloading = self.stage else { return }
                    self.stage = .downloading(value)
                }
            }
            stage = .verifying
            let extractedApp = try await Task.detached(priority: .userInitiated) {
                try UpdateTransport.verifyArchive(archive, package: package)
                return try Self.extract(archive, into: work, requirement: requirement)
            }.value
            stage = .installing
            let destination = Self.installDestination
            let arguments = try await Task.detached(priority: .userInitiated) {
                try Self.stage(extractedApp, beside: destination, requirement: requirement)
            }.value
            try Self.launchInstaller(script: arguments.script, pid: ProcessInfo.processInfo.processIdentifier,
                                     staged: arguments.staged, destination: destination,
                                     backup: arguments.backup, stagingParent: arguments.stagingParent, work: work)
            stage = .restarting
            NSApp.terminate(nil)
        } catch {
            try? FileManager.default.removeItem(at: work)
            stage = .failed("更新失败：\(error.localizedDescription)")
        }
    }

    nonisolated private static func extract(_ archive: URL, into work: URL, requirement: String) throws -> URL {
        let extracted = work.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path])
        guard let name = try FileManager.default.contentsOfDirectory(atPath: extracted.path).first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError(message: "压缩包中没有应用。")
        }
        let app = extracted.appendingPathComponent(name, isDirectory: true)
        try verifyApp(app, requirement: requirement)
        return app
    }

    nonisolated private static func stage(_ app: URL, beside destination: URL, requirement: String) throws -> StagingResult {
        if FileManager.default.fileExists(atPath: destination.path) {
            try verifyApp(destination, requirement: requirement)
        }
        let parent = destination.deletingLastPathComponent()
            .appendingPathComponent(".qingjie-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let staged = parent.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        do {
            try run("/usr/bin/ditto", [app.path, staged.path])
            try verifyApp(staged, requirement: requirement)
            let script = parent.appendingPathComponent("apply.sh")
            try Self.installerScript.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            return StagingResult(script: script, staged: staged,
                                 backup: parent.appendingPathComponent("previous.app", isDirectory: true),
                                 stagingParent: parent)
        } catch {
            try? FileManager.default.removeItem(at: parent)
            throw error
        }
    }

    /// 退出后执行：整体替换应用，失败时回滚旧版，成功后重启。与 scripts/app_identity.py 的 install 流程一致。
    nonisolated private static let installerScript = """
    #!/bin/bash
    pid="$1"; staged="$2"; destination="$3"; backup="$4"; staging="$5"; work="$6"
    for _ in $(seq 1 600); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.2
    done
    # 超时后仍在运行时停止，不能替换正在使用的应用。
    if kill -0 "$pid" 2>/dev/null; then exit 1; fi
    sleep 0.5
    if [ -e "$destination" ] && ! mv "$destination" "$backup"; then exit 1; fi
    if mv "$staged" "$destination"; then
      rm -rf "$backup"
      rm -rf "$staging" "$work"
      /usr/bin/open "$destination"
      exit 0
    fi
    if [ -e "$backup" ]; then mv "$backup" "$destination"; fi
    rm -rf "$staging" "$work" 2>/dev/null || true
    exit 1
    """

    nonisolated private static func launchInstaller(script: URL, pid: Int32, staged: URL, destination: URL,
                                        backup: URL, stagingParent: URL, work: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, String(pid), staged.path, destination.path, backup.path, stagingParent.path, work.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    nonisolated private static func verifyApp(_ app: URL, requirement: String) throws {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: app.path)) != nil {
            throw UpdateError(message: "应用目录不能是符号链接：\(app.lastPathComponent)。")
        }
        guard let bundle = Bundle(url: app), let info = bundle.infoDictionary,
              let ours = Bundle.main.infoDictionary else {
            throw UpdateError(message: "无法读取应用信息：\(app.lastPathComponent)。")
        }
        for key in ["CFBundleIdentifier", "CFBundleExecutable", "CFBundleName", "CFBundleDisplayName"] {
            guard info[key] as? String == ours[key] as? String, ours[key] != nil else {
                throw UpdateError(message: "应用身份发生变化：\(key) 不一致。")
            }
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=" + requirement, app.path])
        let detail = try run("/usr/bin/codesign", ["-d", "-r-", app.path])
        // codesign 输出中的证书哈希是小写十六进制，比对时忽略大小写。
        let designated = ("designated => " + requirement).lowercased()
        guard detail.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == designated }) else {
            throw UpdateError(message: "应用的 Designated Requirement 与固定身份不一致。")
        }
    }

    @discardableResult
    nonisolated private static func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw UpdateError(message: "\(URL(fileURLWithPath: path).lastPathComponent) 失败：\(output.isEmpty ? "请查看控制台。" : output)")
        }
        return output
    }
}

private struct StagingResult {
    let script: URL
    let staged: URL
    let backup: URL
    let stagingParent: URL
}
