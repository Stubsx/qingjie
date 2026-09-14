import AppKit
import SwiftUI

struct MarkToolIcon: View {
    let tool: MarkTool
    var size: CGFloat = 20
    var body: some View {
        AnnotationIcon(kind: .tool(tool), size: size)
    }
}

struct MosaicStylePicker: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        Picker("马赛克样式", selection: $model.mosaicStyle) {
            ForEach(MosaicStyle.allCases) { style in Text(style.title).tag(style) }
        }.labelsHidden().pickerStyle(.menu).font(.system(size: 11))
            .onChange(of: model.mosaicStyle) { _, style in model.message = style.hint }
            .accessibilityLabel("马赛克样式").help("选择高斯模糊、像素块或纯色遮挡")
    }
}

struct ScreenColorPickerButton: View {
    @ObservedObject var model: EditorModel
    var beforeSampling: () -> Void = {}
    var compact = false
    var body: some View {
        Button { beforeSampling(); model.sampleColor() } label: {
            AnnotationIcon(kind: .eyedropper, size: compact ? 13 : 20)
        }.buttonStyle(AnnotationIconButtonStyle(target: compact ? 22 : 36)).disabled(model.isSamplingColor)
            .accessibilityLabel("吸取屏幕颜色").help("吸取屏幕颜色 · Esc 取消取色")
    }
}

struct CurrentAnnotationColor: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: model.color)).frame(width: 15, height: 15)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.gray.opacity(0.4)))
            Text(model.colorHex).font(.system(size: 10, design: .monospaced))
        }.accessibilityElement(children: .ignore).accessibilityLabel("当前颜色 \(model.colorHex)")
    }
}
