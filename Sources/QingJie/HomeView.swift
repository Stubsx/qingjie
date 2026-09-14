import SwiftUI
import QingJieCore

struct HomeView: View {
    @ObservedObject var state: AppState
    let hotKeys: HotKeys
    var appearance: ScreenshotAppearanceSettings = .shared
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    HStack {
                        Text(state.page.rawValue).font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Label("本机处理 · 隐私安心", systemImage: "lock.shield").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }.padding(.top, 6)
                    switch state.page {
                    case .workbench:
                        hero
                        captureActions
                        historySection
                    case .history:
                        historySection
                    case .guide:
                        guide
                    case .settings:
                        AppSettingsView(hotKeys: hotKeys, appearance: appearance)
                    }
                    if !state.notice.isEmpty { Text(state.notice).font(.system(size: 12)).foregroundStyle(.orange) }
                }.padding(32)
            }.id(state.page).background(Theme.background)
        }
        .foregroundStyle(Theme.ink).frame(minWidth: 920, minHeight: 630)
        .preferredColorScheme(.light)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "viewfinder").font(.system(size: 24, weight: .medium)).foregroundStyle(Theme.lime)
                    .frame(width: 45, height: 45).background(Theme.green, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("轻截").font(.system(size: 21, weight: .bold))
                    Text("Q I N G J I E").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
            }.padding(.bottom, 42)
            ForEach(HomePage.allCases, id: \.self) { page in
                Button { state.page = page } label: {
                    HStack(spacing: 12) { Image(systemName: page.icon).frame(width: 18); Text(page.rawValue); Spacer() }
                        .font(.system(size: 13, weight: state.page == page ? .semibold : .regular))
                        .padding(.horizontal, 13).padding(.vertical, 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(state.page == page ? Theme.green.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                        .foregroundStyle(state.page == page ? Theme.green : Theme.secondary)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.bottom, 5)
            }
            Spacer(minLength: 30)
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "command").font(.system(size: 19)).foregroundStyle(Theme.green)
                Text("灵感出现，即刻捕捉").font(.system(size: 11, weight: .medium))
                HStack(spacing: 7) { Text(state.shortcutLabel(.region)).font(.system(size: 12, weight: .medium, design: .monospaced)); Text("区域截图").font(.system(size: 10)).foregroundStyle(Theme.secondary) }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Theme.background, in: RoundedRectangle(cornerRadius: 12))
            Button { state.requestPermission?() } label: {
                HStack(spacing: 6) {
                    Circle().fill(state.hasPermission ? Color.green : Color.orange).frame(width: 6, height: 6)
                    Text(state.hasPermission ? "屏幕权限已开启" : "点击开启屏幕权限").font(.system(size: 10))
                }.foregroundStyle(Theme.secondary)
            }.buttonStyle(.plain).padding(.top, 22)
            Text("轻截 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")  /  为专注而做").font(.system(size: 9)).foregroundStyle(Theme.secondary.opacity(0.7)).padding(.top, 11)
        }.padding(22).frame(width: 200).background(.white)
    }
    private var hero: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Text("CAPTURE. ANNOTATE. SHARE.").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.5).foregroundStyle(Theme.green)
                Text("轻轻一截，\n重点即刻呈现。").font(.system(size: 34, weight: .semibold)).lineSpacing(4)
                Text("从屏幕到表达，让每一次沟通更清晰。").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Button { state.capture?(.region) } label: { Label("开始区域截图", systemImage: "viewfinder") }
                    .buttonStyle(ActionButtonStyle(primary: true)).padding(.top, 4)
            }
            Spacer(minLength: 0)
            ZStack {
                RoundedRectangle(cornerRadius: 22).fill(Theme.green.opacity(0.06)).frame(width: 225, height: 176).rotationEffect(.degrees(-7))
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 4) { ForEach(0..<3) { _ in Circle().fill(Theme.green.opacity(0.17)).frame(width: 5, height: 5) }; Spacer() }
                    RoundedRectangle(cornerRadius: 3).fill(Theme.green.opacity(0.13)).frame(width: 99, height: 7)
                    Text("看见重点").font(.system(size: 24, weight: .semibold)).padding(9)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.green, style: StrokeStyle(lineWidth: 2, dash: [5, 3])))
                    HStack(spacing: 6) { ForEach([MarkTool.arrow, .pen, .text, .mosaic]) { tool in MarkToolIcon(tool: tool, size: 14).frame(width: 28, height: 28).background(Theme.background, in: RoundedRectangle(cornerRadius: 5)) } }
                }.padding(18).frame(width: 210).background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(color: Theme.green.opacity(0.08), radius: 16, y: 8).rotationEffect(.degrees(4))
                Image(systemName: "cursorarrow").font(.system(size: 25, weight: .bold)).foregroundStyle(Theme.green).offset(x: 61, y: 33)
            }.frame(width: 244, height: 210).accessibilityHidden(true)
        }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.91, green: 0.94, blue: 0.89), in: RoundedRectangle(cornerRadius: 18))
    }
    private var captureActions: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
            actionCard("区域截图", subtitle: "单击选窗口，拖动自由框选", icon: "viewfinder", shortcut: state.shortcutLabel(.region)) { state.capture?(.region) }
            actionCard("全屏截图", subtitle: "截取鼠标所在屏幕", icon: "display", shortcut: state.shortcutLabel(.fullscreen)) { state.capture?(.fullscreen) }
            actionCard("打开图片", subtitle: "为已有图片添加标注", icon: "photo.badge.plus", shortcut: "⌘ O") { state.importImage?() }
        }
    }
    private func actionCard(_ title: String, subtitle: String, icon: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Image(systemName: icon).font(.system(size: 20)).foregroundStyle(Theme.green); Spacer(); Text(shortcut).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.secondary) }
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.black.opacity(0.04)))
        }.buttonStyle(.plain)
    }
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("最近截图").font(.system(size: 16, weight: .semibold))
                Text("\(state.history.count)").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                Spacer()
                Button("在访达中查看", systemImage: "folder") { state.revealHistory() }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Theme.secondary)
            }
            if state.history.isEmpty {
                HStack(spacing: 15) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 25)).foregroundStyle(Theme.secondary.opacity(0.65))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("你的第一张截图，从这里开始").font(.system(size: 12, weight: .medium))
                        Text("复制、保存或贴图后，成品会自动出现在这里。最多保留 30 张。").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Button("体验标注 →") { state.showDemo?() }.font(.system(size: 11, weight: .medium)).buttonStyle(.plain).foregroundStyle(Theme.green)
                }.padding(22).frame(maxWidth: .infinity).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                    ForEach(Array(state.history.prefix(state.page == .workbench ? 6 : 30))) { item in
                        Button { state.openHistory?(item.url) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(nsImage: item.thumbnail).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 120).background(Theme.background)
                                Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(Theme.secondary).padding(.horizontal, 10).padding(.bottom, 10)
                            }.background(.white, in: RoundedRectangle(cornerRadius: 10)).clipShape(RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).contextMenu {
                            Button("打开编辑") { state.openHistory?(item.url) }
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                            Button("从最近截图移除", role: .destructive) { state.deleteHistory(item) }
                        }
                    }
                }
            }
        }
    }
    private var guide: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("普通截图").font(.system(size: 24, weight: .semibold))
                        Text("三步，把重点说明白。").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Button("打开示例，体验标注") { state.showDemo?() }.buttonStyle(ActionButtonStyle(primary: true))
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array([("01", "截取画面", "点击「区域截图」或按 \(state.shortcutLabel(.region)) 开始：鼠标移到窗口上会自动高亮吸附，也可以直接拖动自由框选。Esc 随时取消。"),
                                   ("02", "标出重点", "拖动即可绘制箭头、矩形、文字或马赛克；数字键 1–7 切换工具，⌘Z 撤销。选中已有标注可直接拖动位置或调整大小。"),
                                   ("03", "复制或保存", "Enter 或 ⌘C 复制，⌘S 另存为 PNG/JPEG。也可以点「贴图」，把成品钉在屏幕上方对照查看。")].enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 14) {
                            Text(step.0).font(.system(size: 15, weight: .medium, design: .monospaced)).foregroundStyle(Theme.green.opacity(0.5)).padding(.top, 1)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(step.1).font(.system(size: 14, weight: .medium))
                                Text(step.2).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                            }
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        if index < 2 { Divider().padding(.horizontal, 18) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 12))
                Text("关闭工作台后应用仍驻留菜单栏，可按 ⌘Q 完全退出。完成的截图自动存入最近截图，最多保留 30 张。").font(.system(size: 12)).foregroundStyle(Theme.secondary).lineSpacing(4)
                if state.hotKeyFailed { Text("部分快捷键注册失败，可能与其他软件冲突。可在「设置 → 快捷键」中更改组合，或通过菜单栏截图。").font(.system(size: 12)).foregroundStyle(.orange) }
            }
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("长截图").font(.system(size: 24, weight: .semibold))
                        Text("把整段内容，连成一张图。").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Button("体验长截图（无需屏幕权限）") { state.showScrollDemo?() }.buttonStyle(ActionButtonStyle())
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("框选后点击选区工具栏的「长截图」，用触控板或滚轮缓慢向下滚动，新内容会自动拼接。到达末尾后点击「完成复制」或「另存为」。").font(.system(size: 12)).foregroundStyle(Theme.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    ForEach(["重复画面、短暂上滑和底部回弹都会自动处理", "灰色区域实时预览长图和像素尺寸，鼠标移入可滚动回看", "页内有多个面板时，把鼠标停在要截取的正文上滚动"], id: \.self) { tip in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(Theme.green).frame(width: 4, height: 4).padding(.top, 5)
                            Text(tip).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        }
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
