import SwiftUI

/// One 20-point drawing grid and stroke for every action in the capture toolbar.
enum AnnotationIconKind {
    case tool(MarkTool), undo, redo, eyedropper, close, save, scrolling, reselect, copy, confirm, pause, resume, advance
}

struct AnnotationIcon: View {
    let kind: AnnotationIconKind
    var size: CGFloat = 20
    var body: some View {
        AnnotationIconShape(kind: kind)
            .stroke(style: StrokeStyle(lineWidth: 1.7 * size / 20, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

private struct AnnotationIconShape: Shape {
    let kind: AnnotationIconKind
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func line(_ points: [CGPoint], closed: Bool = false) {
            guard let first = points.first else { return }
            path.move(to: first); points.dropFirst().forEach { path.addLine(to: $0) }
            if closed { path.closeSubpath() }
        }
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        switch kind {
        case .tool(.select):
            line([p(4, 3), p(16, 11), p(11, 12), p(8, 17)], closed: true)
            line([p(11, 12), p(14, 17)])
        case .tool(.rectangle): path.addRoundedRect(in: CGRect(x: 3, y: 4, width: 14, height: 12), cornerSize: CGSize(width: 1, height: 1))
        case .tool(.ellipse): path.addEllipse(in: CGRect(x: 3, y: 4, width: 14, height: 12))
        case .tool(.arrow):
            line([p(4, 16), p(16, 4)]); line([p(7, 4), p(16, 4), p(16, 13)])
        case .tool(.pen):
            line([p(4, 16), p(5, 12), p(13, 4), p(16, 7), p(8, 15)], closed: true)
            line([p(11, 6), p(14, 9)])
        case .tool(.text):
            line([p(3, 5), p(3, 3), p(17, 3), p(17, 5)])
            line([p(10, 3), p(10, 17)]); line([p(7, 17), p(13, 17)])
        case .tool(.mosaic):
            path.addRect(CGRect(x: 3, y: 3, width: 14, height: 14))
            for offset in [CGFloat(7.67), 12.33] {
                line([p(offset, 3), p(offset, 17)]); line([p(3, offset), p(17, offset)])
            }
        case .tool(.crop):
            line([p(3, 6), p(14, 6), p(14, 18)])
            line([p(6, 2), p(6, 14), p(18, 14)])
        case .undo, .redo:
            let reversed: Bool = { if case .redo = kind { return true }; return false }()
            func q(_ x: CGFloat, _ y: CGFloat) -> CGPoint { p(reversed ? 20 - x : x, y) }
            path.move(to: q(3, 7)); path.addLine(to: q(11, 7))
            path.addQuadCurve(to: q(16, 12), control: q(16, 7))
            path.addQuadCurve(to: q(11, 17), control: q(16, 17)); path.addLine(to: q(7, 17))
            line([q(7, 3), q(3, 7), q(7, 11)])
        case .eyedropper:
            line([p(4, 16), p(5, 12), p(13, 4), p(16, 7), p(8, 15)], closed: true)
            line([p(10, 5), p(15, 10)]); line([p(3, 17), p(4, 16)])
        case .close:
            line([p(4, 4), p(16, 16)]); line([p(16, 4), p(4, 16)])
        case .save:
            line([p(4, 12), p(4, 17), p(16, 17), p(16, 12)])
            line([p(10, 3), p(10, 12)]); line([p(6, 8), p(10, 12), p(14, 8)])
        case .scrolling:
            path.addRoundedRect(in: CGRect(x: 3, y: 2, width: 14, height: 16), cornerSize: CGSize(width: 1.5, height: 1.5))
            line([p(8, 11), p(10, 13), p(12, 11)]); line([p(10, 6), p(10, 13)])
        case .reselect:
            line([p(3, 7), p(3, 3), p(7, 3)]); line([p(13, 3), p(17, 3), p(17, 7)])
            line([p(17, 13), p(17, 17), p(13, 17)]); line([p(7, 17), p(3, 17), p(3, 13)])
            line([p(7, 10), p(13, 10)]); line([p(10, 7), p(10, 13)])
        case .copy:
            line([p(5, 13), p(3, 13), p(3, 3), p(13, 3), p(13, 5)])
            path.addRoundedRect(in: CGRect(x: 7, y: 7, width: 10, height: 10), cornerSize: CGSize(width: 1, height: 1))
        case .confirm:
            line([p(3, 10), p(8, 15), p(17, 5)])
        case .pause:
            line([p(6, 4), p(6, 16)]); line([p(14, 4), p(14, 16)])
        case .resume:
            line([p(5, 3), p(17, 10), p(5, 17)], closed: true)
        case .advance:
            line([p(10, 3), p(10, 17)]); line([p(4, 11), p(10, 17), p(16, 11)])
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 20, y: rect.height / 20)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

struct AnnotationIconButtonStyle: ButtonStyle {
    var selected = false
    var primary = false
    var target: CGFloat = 36
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: target, height: target)
            .contentShape(Rectangle())
            .background(Theme.green.opacity(primary ? (configuration.isPressed ? 0.78 : hovered ? 0.90 : 1) : enabled ? (configuration.isPressed ? 0.19 : selected ? 0.13 : hovered ? 0.07 : 0) : 0),
                        in: RoundedRectangle(cornerRadius: target >= 36 ? 6 : 5))
            .foregroundStyle(primary ? Color.white : Theme.green)
            .opacity(enabled ? 1 : 0.32)
            .onHover { hovered = $0 }
    }
}

/// An icon-only action with a stable hit target and a readable VoiceOver/hover name.
struct CaptureIconButton: View {
    let kind: AnnotationIconKind
    let title: String
    var help: String? = nil
    var primary = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { AnnotationIcon(kind: kind) }
            .buttonStyle(AnnotationIconButtonStyle(primary: primary))
            .accessibilityLabel(title).help(help ?? title)
    }
}
