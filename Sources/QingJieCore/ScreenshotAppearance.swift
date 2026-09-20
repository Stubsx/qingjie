import CoreGraphics
import Foundation

public struct ScreenshotAppearance: Equatable, Sendable {
    public var roundedCorners: Bool
    public var shadow: Bool
    /// AppKit has no public API for the current system window radius. Use a
    /// consistent macOS-style radius in points, independent of display density.
    public static let defaultCornerRadius: CGFloat = 12
    public static let defaultShadowBlur: CGFloat = 12
    public static let defaultShadowOffset: CGFloat = 6
    public static let defaultShadowOpacity: CGFloat = 0.24
    public static let cornerRadiusRange: ClosedRange<CGFloat> = 0...64
    public static let shadowBlurRange: ClosedRange<CGFloat> = 0...48
    public static let shadowOffsetRange: ClosedRange<CGFloat> = 0...32
    public static let shadowOpacityRange: ClosedRange<CGFloat> = 0...1
    public let cornerRadius: CGFloat
    public let shadowBlur: CGFloat
    public let shadowOffset: CGFloat
    public let shadowOpacity: CGFloat

    public init(roundedCorners: Bool = false, shadow: Bool = false,
                cornerRadius: CGFloat = defaultCornerRadius, shadowBlur: CGFloat = defaultShadowBlur,
                shadowOffset: CGFloat = defaultShadowOffset, shadowOpacity: CGFloat = defaultShadowOpacity) {
        self.roundedCorners = roundedCorners; self.shadow = shadow
        self.cornerRadius = Self.clamp(cornerRadius, to: Self.cornerRadiusRange, fallback: Self.defaultCornerRadius)
        self.shadowBlur = Self.clamp(shadowBlur, to: Self.shadowBlurRange, fallback: Self.defaultShadowBlur)
        self.shadowOffset = Self.clamp(shadowOffset, to: Self.shadowOffsetRange, fallback: Self.defaultShadowOffset)
        self.shadowOpacity = Self.clamp(shadowOpacity, to: Self.shadowOpacityRange, fallback: Self.defaultShadowOpacity)
    }
    private static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>, fallback: CGFloat) -> CGFloat {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    public func render(_ image: CGImage, pixelsPerPoint: CGFloat = 1) throws -> CGImage {
        let hasShadow = shadow && shadowOpacity > 0 && (shadowBlur > 0 || shadowOffset > 0)
        guard roundedCorners || hasShadow else { return image }
        guard pixelsPerPoint.isFinite, pixelsPerPoint > 0, pixelsPerPoint <= 8 else { throw AppearanceError.invalidScale }
        let blur = shadowBlur * pixelsPerPoint, offset = shadowOffset * pixelsPerPoint
        let padding = hasShadow ? ceil(blur * 3 + offset) : 0
        let width = image.width + Int(padding) * 2, height = image.height + Int(padding) * 2
        guard width > 0, height > 0, width <= 64_000_000 / height else { throw AppearanceError.tooLarge }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AppearanceError.allocation }
        try draw(in: context, imageSize: CGSize(width: image.width, height: image.height), pixelsPerPoint: pixelsPerPoint) { rect in
            context.draw(image, in: rect)
        }
        guard let result = context.makeImage() else { throw AppearanceError.allocation }
        return result
    }

    // Shared geometry keeps ordinary screenshots and banded long exports identical.
    func padding(pixelsPerPoint: CGFloat) throws -> Int {
        guard pixelsPerPoint.isFinite, pixelsPerPoint > 0, pixelsPerPoint <= 8 else { throw AppearanceError.invalidScale }
        let hasShadow = shadow && shadowOpacity > 0 && (shadowBlur > 0 || shadowOffset > 0)
        return hasShadow ? Int(ceil((shadowBlur * 3 + shadowOffset) * pixelsPerPoint)) : 0
    }
    func draw(in context: CGContext, imageSize: CGSize, pixelsPerPoint: CGFloat,
              drawContent: (CGRect) throws -> Void) throws {
        let hasShadow = shadow && shadowOpacity > 0 && (shadowBlur > 0 || shadowOffset > 0)
        let blur = shadowBlur * pixelsPerPoint, offset = shadowOffset * pixelsPerPoint
        let padding = CGFloat(try padding(pixelsPerPoint: pixelsPerPoint))
        let width = imageSize.width + padding * 2, height = imageSize.height + padding * 2
        let rect = CGRect(x: padding, y: padding, width: imageSize.width, height: imageSize.height)
        let radius = roundedCorners ? min(cornerRadius * pixelsPerPoint, min(rect.width, rect.height) / 2) : 0
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if hasShadow {
            context.saveGState()
            // Clip the finished shadow outside the silhouette so existing alpha
            // inside the source image remains transparent instead of turning black.
            context.addRect(CGRect(x: 0, y: 0, width: width, height: height)); context.addPath(path)
            context.clip(using: .evenOdd)
            context.setShadow(offset: CGSize(width: 0, height: -offset), blur: blur,
                              color: CGColor(gray: 0, alpha: shadowOpacity))
            context.setFillColor(CGColor(gray: 0, alpha: 1)); context.addPath(path); context.fillPath()
            context.restoreGState()
        }
        context.addPath(path); context.clip()
        context.interpolationQuality = .none
        try drawContent(rect)
    }

    public enum AppearanceError: LocalizedError {
        case invalidScale, tooLarge, allocation
        public var errorDescription: String? {
            switch self {
            case .invalidScale: "截图缩放比例无效。"
            case .tooLarge: "添加美化后的图片过大，请缩小截图范围或关闭阴影。"
            case .allocation: "无法生成美化效果，请重试或在设置中关闭截图美化。"
            }
        }
    }
}
