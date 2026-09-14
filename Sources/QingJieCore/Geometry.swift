import Foundation
import CoreGraphics

public enum CaptureGeometry {
    /// Top-left display points. Prefer below, then above, then inside the selection.
    public static func toolbarFrame(selection: CGRect, bounds: CGSize, size: CGSize) -> CGRect {
        let margin: CGFloat = 10
        let width = min(size.width, max(1, bounds.width - margin * 2))
        let height = min(size.height, max(1, bounds.height - margin * 2))
        let x = min(max(margin, selection.maxX - width), max(margin, bounds.width - width - margin))
        let below = selection.maxY + margin
        let above = selection.minY - height - margin
        let y = below + height <= bounds.height - margin ? below : above >= margin ? above : max(margin, bounds.height - height - margin)
        return CGRect(x: x, y: y, width: width, height: height)
    }
    public static func rectangle(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// Selection coordinates are top-left display points; CGImage cropping uses pixel coordinates.
    public static func pixelRect(selection: CGRect, bounds: CGSize, pixels: CGSize) -> CGRect? {
        guard bounds.width > 0, bounds.height > 0, pixels.width > 0, pixels.height > 0 else { return nil }
        let clipped = selection.standardized.intersection(CGRect(origin: .zero, size: bounds))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        let sx = pixels.width / bounds.width, sy = pixels.height / bounds.height
        let rect = CGRect(x: floor(clipped.minX * sx), y: floor(clipped.minY * sy),
                          width: ceil(clipped.maxX * sx) - floor(clipped.minX * sx),
                          height: ceil(clipped.maxY * sy) - floor(clipped.minY * sy))
        return rect.intersection(CGRect(origin: .zero, size: pixels))
    }

    public static func fit(image: CGSize, in available: CGSize, inset: CGFloat = 32) -> CGRect {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = max(0.001, min((available.width - inset * 2) / image.width,
                                   (available.height - inset * 2) / image.height, 1))
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (available.width - size.width) / 2, y: (available.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    public static func imagePoint(_ point: CGPoint, displayedIn frame: CGRect, imageSize: CGSize) -> CGPoint {
        CGPoint(x: min(max((point.x - frame.minX) / frame.width * imageSize.width, 0), imageSize.width),
                y: min(max((point.y - frame.minY) / frame.height * imageSize.height, 0), imageSize.height))
    }
}
