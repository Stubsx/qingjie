import SwiftUI

struct EditorView: View {
    @ObservedObject var model: EditorModel
    let colors: [NSColor] = [NSColor(calibratedRed: 0.95, green: 0.30, blue: 0.24, alpha: 1), .systemOrange, .systemYellow,
                             NSColor(calibratedRed: 0.12, green: 0.56, blue: 0.40, alpha: 1), .systemBlue, .white, .black]
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 5) {
                ForEach(Array(MarkTool.allCases.enumerated()), id: \.element.id) { index, tool in
                    Button {
                        model.tool = tool; model.selectedID = nil
                        model.message = tool == .select ? "点击标注并拖动 · Delete 删除选中标注" : tool == .text ? "点击图片放置文字" : "拖动绘制\(tool.title) · ⌘Z 撤销"
                    } label: {
                        HStack(spacing: 6) { MarkToolIcon(tool: tool); Text(tool.title).font(.system(size: 11, weight: .medium)) }
                            .padding(.horizontal, 12).frame(height: 36)
                            .foregroundStyle(model.tool == tool ? Theme.green : Theme.secondary)
                            .background(model.tool == tool ? Theme.green.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [])
                        .help("\(tool.title)（\(index + 1)）").accessibilityLabel("\(tool.title)")
                }
                Spacer(minLength: 5)
                Button { model.undo() } label: { AnnotationIcon(kind: .undo) }.buttonStyle(AnnotationIconButtonStyle()).disabled(model.undoStack.isEmpty)
                    .keyboardShortcut("z", modifiers: .command).help("撤销 ⌘Z")
                Button { model.redo() } label: { AnnotationIcon(kind: .redo) }.buttonStyle(AnnotationIconButtonStyle()).disabled(model.redoStack.isEmpty)
                    .keyboardShortcut("z", modifiers: [.command, .shift]).help("重做 ⇧⌘Z")
            }.buttonStyle(.borderless).padding(.horizontal, 18).padding(.vertical, 11).background(.white)
            Divider()
            HStack(spacing: 0) {
                EditorCanvas(model: model)
                    .overlay(alignment: .bottom) { CanvasModeSwitcher(model: model).padding(.bottom, 18) }
                Divider()
                inspector
            }
            Divider()
            HStack(spacing: 7) {
                Circle().fill(Theme.green).frame(width: 5, height: 5)
                Text(model.message).lineLimit(1)
                Spacer()
            }.font(.system(size: 10)).padding(.horizontal, 20).frame(height: 33).background(.white)
        }.foregroundStyle(Theme.ink).frame(minWidth: 980, minHeight: 650).preferredColorScheme(.light)
        .sheet(isPresented: $model.showingText) { textSheet }
        .sheet(isPresented: $model.showingOCR) { ocrSheet }
    }
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "viewfinder").font(.system(size: 20)).foregroundStyle(Theme.green)
            VStack(alignment: .leading, spacing: 3) {
                Text("截图标注").font(.system(size: 14, weight: .semibold))
                Text("\(model.image.width) × \(model.image.height) px").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button { model.recognize() } label: { Label(model.recognizing ? "识别中…" : "识别文字", systemImage: "text.viewfinder") }
                .disabled(model.recognizing).buttonStyle(ActionButtonStyle())
            Button {
                guard let image = model.rendered() else { return }
                model.onPin?(image); model.onExport?(image); model.message = "已贴到屏幕上方 · 拖动移动，双击关闭"
            } label: { Label("贴图", systemImage: "pin") }.buttonStyle(ActionButtonStyle())
            Button { model.copy() } label: { Label("复制", systemImage: "doc.on.doc") }.buttonStyle(ActionButtonStyle()).keyboardShortcut("c", modifiers: .command)
            Button { model.save() } label: { Label("保存图片", systemImage: "square.and.arrow.down") }.buttonStyle(ActionButtonStyle(primary: true)).keyboardShortcut("s", modifiers: .command)
        }.padding(.horizontal, 22).frame(height: 68).background(.white)
    }
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 23) {
            VStack(alignment: .leading, spacing: 6) {
                Text("标注样式").font(.system(size: 13, weight: .semibold))
                Text("应用于接下来添加的标注").font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("颜色").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                    Spacer(); ScreenColorPickerButton(model: model, compact: true)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(27), spacing: 9), count: 4), alignment: .leading, spacing: 10) {
                    ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                        Button { model.color = color } label: {
                            Circle().fill(Color(nsColor: color)).frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(.black.opacity(0.13)))
                                .padding(3).overlay(Circle().strokeBorder(model.color == color ? Theme.green : .clear, lineWidth: 1.5))
                        }.buttonStyle(.plain).accessibilityLabel(color.accessibilityName)
                    }
                    Button { showColorPanel() } label: {
                        Circle()
                            .fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(.black.opacity(0.13)))
                            .padding(3)
                            .overlay(Circle().strokeBorder(colors.contains(model.color) ? .clear : Theme.green, lineWidth: 1.5))
                    }.buttonStyle(.plain).help("自选颜色").accessibilityLabel("自选颜色")
                        .onReceive(NotificationCenter.default.publisher(for: NSColorPanel.colorDidChangeNotification)) { note in
                            guard let panel = note.object as? NSColorPanel else { return }
                            model.color = panel.color
                        }
                }
            }
            CurrentAnnotationColor(model: model)
            if model.tool == .mosaic { MosaicStylePicker(model: model) }
            if model.tool != .mosaic || model.mosaicStyle != .solid {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text(model.tool == .mosaic ? "马赛克强度" : "线条粗细"); Spacer(); Text("\(Int(model.lineWidth))").monospacedDigit() }.font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    Slider(value: $model.lineWidth, in: 2...16, step: 1).tint(Theme.green)
                    RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: model.color)).frame(height: model.lineWidth).frame(height: 22)
                }
            }
            if model.tool == .text {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("文字大小"); Spacer(); Text("\(Int(model.fontSize)) px") }.font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    Slider(value: $model.fontSize, in: 16...100, step: 2).tint(Theme.green)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("小提示", systemImage: "lightbulb").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.green)
                Text(hint).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text("每一处重点，\n都值得被看见。").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.green.opacity(0.30)).lineSpacing(5)
        }.padding(22).frame(width: 200).frame(maxHeight: .infinity).background(Color.white)
    }
    private var hint: String {
        switch model.tool {
        case .select: return "点击选中已有标注，拖动调整位置。按 Delete 删除。长图可在画布下方切换为适应宽度，再滚动查看。"
        case .rectangle, .ellipse: return "按住 Shift 拖动，可绘制正方形或正圆。绘制后可用选择工具移动。"
        case .arrow: return "从起点拖向重点，箭头会指向松开鼠标的位置。"
        case .pen: return "按住鼠标自由绘制，适合圈出重点或手写批注。"
        case .text: return "点击图片选择位置，输入文字。支持多行，中英文都可以。"
        case .mosaic: return model.mosaicStyle.hint
        case .crop: return "框选要保留的范围，松开完成裁剪。已有标注会合并到图片，可用 ⌘Z 恢复。"
        }
    }
    private func showColorPanel() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = model.color
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFront(nil)
    }
    private var textSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("添加文字").font(.system(size: 20, weight: .semibold))
            Text("输入标注内容，支持换行。").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            TextEditor(text: $model.textInput).font(.system(size: 16)).padding(8).frame(height: 130)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.gray.opacity(0.25)))
            HStack {
                Spacer()
                Button("取消") { model.showingText = false }.keyboardShortcut(.cancelAction)
                Button("添加文字") { model.addText(); model.showingText = false }.keyboardShortcut(.defaultAction)
                    .disabled(model.textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 430)
    }
    private var ocrSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label("识别结果", systemImage: "text.viewfinder").font(.system(size: 20, weight: .semibold)); Spacer(); Text("本机识别").font(.system(size: 11)).foregroundStyle(Theme.secondary) }
            if model.recognizedText.isEmpty { Text("没有识别到文字，试试包含清晰文字的图片。").foregroundStyle(Theme.secondary).frame(height: 220) }
            else { TextEditor(text: $model.recognizedText).font(.system(size: 14)).padding(8).frame(height: 280).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.gray.opacity(0.25))) }
            HStack {
                Text("识别结果可编辑").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Spacer(); Button("关闭") { model.showingOCR = false }.keyboardShortcut(.cancelAction)
                Button("复制文字") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.recognizedText, forType: .string)
                    model.message = "已复制识别文字"; model.showingOCR = false
                }.disabled(model.recognizedText.isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 550)
    }
}

private struct CanvasModeSwitcher: View {
    @ObservedObject var model: EditorModel
    @Namespace private var selection
    var body: some View {
        HStack(spacing: 2) {
            ForEach(CanvasMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { model.canvasMode = mode }
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 11, weight: model.canvasMode == mode ? .semibold : .medium))
                        .foregroundStyle(model.canvasMode == mode ? Theme.green : Theme.secondary)
                        .padding(.horizontal, 13).frame(height: 27)
                        .background {
                            if model.canvasMode == mode {
                                Capsule().fill(.white)
                                    .shadow(color: .black.opacity(0.10), radius: 2.5, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: selection)
                            }
                        }
                }.buttonStyle(.plain).accessibilityLabel(mode.rawValue)
            }
        }
        .padding(3)
        .background { capsuleBackground }
    }
    @ViewBuilder private var capsuleBackground: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: .capsule)
        } else {
            Capsule().fill(.ultraThinMaterial)
                .overlay(Capsule().strokeBorder(.black.opacity(0.08)))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        }
    }
}
