import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class LoginItemSettings: ObservableObject {
    static let shared = LoginItemSettings()
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    // 裸二进制（swift run / 直接执行）没有 .app bundle，SMAppService 不可用。
    @Published private(set) var unavailable = Bundle.main.bundleIdentifier == nil
    @Published var failure: String?

    private let service = SMAppService.mainApp

    init() { refresh() }

    func refresh() {
        let status = service.status
        isEnabled = status == .enabled || status == .requiresApproval
        requiresApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { refresh(); return }
        do {
            if enabled { try service.register() } else { try service.unregister() }
            failure = nil
        } catch {
            failure = "开机启动设置未生效：请确认使用的是「应用程序」中安装的轻截，再试一次。（\(error.localizedDescription)）"
        }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
final class DockIconSettings: ObservableObject {
    static let shared = DockIconSettings()
    static let key = "QingJie.general.dockIcon"
    @Published var showsIcon: Bool {
        didSet {
            guard oldValue != showsIcon else { return }
            defaults.set(showsIcon, forKey: Self.key)
            NSApplication.shared.setActivationPolicy(showsIcon ? .regular : .accessory)
            if showsIcon { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsIcon = defaults.object(forKey: Self.key) as? Bool ?? true
    }
}

@MainActor
final class CaptureAppHidingSettings: ObservableObject {
    static let shared = CaptureAppHidingSettings()
    static let key = "QingJie.general.hideAppOnCapture"
    @Published var enabled: Bool {
        didSet {
            guard oldValue != enabled else { return }
            defaults.set(enabled, forKey: Self.key)
        }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: Self.key) as? Bool ?? true
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var loginItem: LoginItemSettings = .shared
    @ObservedObject var dock: DockIconSettings = .shared
    @ObservedObject var captureHiding: CaptureAppHidingSettings = .shared
    @ObservedObject var update: UpdateSettings = .shared
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("通用").font(.system(size: 24, weight: .semibold))
            .onAppear { loginItem.refresh() }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("开机自动启动").font(.system(size: 14, weight: .medium))
                        Text("登录 Mac 后自动运行，驻留菜单栏。")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if loginItem.unavailable {
                            Text("当前运行方式不支持开机启动，请打开「应用程序」中的轻截后再设置。")
                                .font(.system(size: 11)).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 10)
                    Toggle("开机自动启动", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                        .labelsHidden().toggleStyle(.switch).tint(Theme.green)
                        .disabled(loginItem.unavailable)
                        .accessibilityLabel("开机自动启动")
                        .accessibilityValue(loginItem.isEnabled ? "已开启" : "已关闭")
                }.padding(18)
                Divider().padding(.horizontal, 18)
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("在 Dock 栏显示图标").font(.system(size: 14, weight: .medium))
                        Text("关闭后仅驻留菜单栏，截图与快捷键不受影响。")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 10)
                    Toggle("在 Dock 栏显示图标", isOn: $dock.showsIcon)
                        .labelsHidden().toggleStyle(.switch).tint(Theme.green)
                        .accessibilityLabel("在 Dock 栏显示图标")
                        .accessibilityValue(dock.showsIcon ? "已开启" : "已关闭")
                }.padding(18)
                Divider().padding(.horizontal, 18)
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("截图时隐藏轻截").font(.system(size: 14, weight: .medium))
                        Text("开始截图时收起轻截窗口，避免遮挡画面。")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 10)
                    Toggle("截图时隐藏轻截", isOn: $captureHiding.enabled)
                        .labelsHidden().toggleStyle(.switch).tint(Theme.green)
                        .accessibilityLabel("截图时隐藏轻截")
                        .accessibilityValue(captureHiding.enabled ? "已开启" : "已关闭")
                }.padding(18)
                Divider().padding(.horizontal, 18)
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("自动检查更新").font(.system(size: 14, weight: .medium))
                        Text("每天匿名读取一次版本信息，只比对版本号，不上传数据；发现新版本可在此一键下载安装，替换前会校验文件完整性和固定签名身份，完成后自动重启。")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        updateStatus
                        if update.updateAvailable == true, let notes = update.latest?.notes, !notes.isEmpty {
                            Text(notes).font(.system(size: 11)).foregroundStyle(Theme.ink).lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let description = update.stage.description {
                            HStack(spacing: 8) {
                                if case .downloading(let value) = update.stage {
                                    ProgressView(value: value).frame(width: 120)
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                                Text(description).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            }
                        }
                        if case .failed(let message) = update.stage {
                            Text(message).font(.system(size: 11)).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 10) {
                            if update.updateAvailable == true, let latest = update.latest {
                                if latest.package != nil {
                                    Button("下载并安装") { Task { await update.downloadAndInstall() } }
                                        .buttonStyle(ActionButtonStyle(primary: true))
                                        .disabled(update.stage.busy)
                                        .accessibilityLabel("下载并安装新版本")
                                }
                                Button("查看更新") { update.openReleasePage() }
                                    .buttonStyle(ActionButtonStyle())
                                    .accessibilityLabel("打开发布页面查看新版本")
                                if !update.isSkipped(latest) {
                                    Button("跳过此版本") { update.skipCurrentVersion() }
                                        .buttonStyle(ActionButtonStyle())
                                        .accessibilityLabel("跳过此版本，不再提醒")
                                }
                            }
                            Button(update.checking ? "检查中…" : "立即检查") {
                                Task { await update.check(notify: true) }
                            }
                            .buttonStyle(ActionButtonStyle())
                            .disabled(update.checking || update.stage.busy)
                            .accessibilityLabel("立即检查更新")
                        }
                    }
                    Spacer(minLength: 10)
                    Toggle("自动检查更新", isOn: $update.enabled)
                        .labelsHidden().toggleStyle(.switch).tint(Theme.green)
                        .accessibilityLabel("自动检查更新")
                        .accessibilityValue(update.enabled ? "已开启" : "已关闭")
                }.padding(18)
                if loginItem.requiresApproval {
                    Divider().padding(.horizontal, 18)
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("等待系统确认").font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                            Text("轻截已登记为登录项，还需在系统设置的「登录项与扩展」中允许轻截。")
                                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 10)
                        Button("打开系统设置") { loginItem.openSystemSettings() }
                            .buttonStyle(ActionButtonStyle())
                            .accessibilityLabel("打开系统设置的登录项设置")
                    }.padding(18)
                }
                if let failure = loginItem.failure {
                    Divider().padding(.horizontal, 18)
                    Text(failure).font(.system(size: 11)).foregroundStyle(.orange).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true).padding(18)
                }
            }.background(.white, in: RoundedRectangle(cornerRadius: 12))
            Text("关闭 Dock 图标后，可从菜单栏图标打开工作台、截图或退出。")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var updateStatus: some View {
        let installed = UpdateSettings.installed
        if update.updateAvailable == true, let latest = update.latest {
            Text("发现新版本 \(latest.version)（当前 \(installed.version)）")
                .font(.system(size: 11)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if let failure = update.failure {
            Text(failure).font(.system(size: 11)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if update.lastChecked != nil {
            Text("已是最新版本 \(installed.version) · 上次检查 \(update.lastChecked!.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        } else {
            Text("当前版本 \(installed.version) · 尚未检查")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
    }
}
