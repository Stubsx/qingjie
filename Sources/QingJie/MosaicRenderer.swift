import AppKit
import CoreImage

enum MosaicStyle: String, CaseIterable, Identifiable {
    case gaussian, pixelated, solid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .gaussian: "高斯模糊"
        case .pixelated: "像素块"
        case .solid: "纯色遮挡"
        }
    }
    var hint: String {
        switch self {
        case .gaussian: "框选要模糊的内容。增大强度会加重毛玻璃效果。"
        case .pixelated: "框选需要遮挡的内容。增大强度会得到更大的像素块。"
        case .solid: "框选后用当前颜色完全覆盖。可选择黑色，或用吸管取屏幕颜色。"
        }
    }
}

/// Reuse filtered patches while the canvas redraws; never retain an unbounded set of drag frames.
enum MosaicRenderer {
    private final class Patch {
        let base: CGImage // Keeps pointer-based cache identities valid until eviction.
        let image: CGImage
        init(base: CGImage, image: CGImage) { self.base = base; self.image = image }
    }
    private static let cache: NSCache<NSString, Patch> = {
        let cache = NSCache<NSString, Patch>()
        cache.countLimit = 24; cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let context = CIContext(options: [.workingColorSpace: colorSpace, .outputColorSpace: colorSpace, .cacheIntermediates: false])

    static func image(base: CGImage, rect: CGRect, style: MosaicStyle, strength: CGFloat) -> CGImage? {
        guard style != .solid, !rect.isEmpty else { return nil }
        let key = "\(ObjectIdentifier(base))-\(rect)-\(style.rawValue)-\(strength)" as NSString
        if let patch = cache.object(forKey: key) { return patch.image }
        let result: CGImage?
        if style == .gaussian {
            // Core Image coordinates start at the bottom left; annotation coordinates start at the top left.
            let region = CGRect(x: rect.minX, y: CGFloat(base.height) - rect.maxY, width: rect.width, height: rect.height)
            let blurred = CIImage(cgImage: base).clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(6, strength * 3)])
            result = context.createCGImage(blurred, from: region, format: .RGBA8, colorSpace: colorSpace)
        } else {
            guard let crop = base.cropping(to: rect) else { return nil }
            let block = max(12, Int(strength * 5))
            let w = max(1, Int(ceil(rect.width / CGFloat(block)))), h = max(1, Int(ceil(rect.height / CGFloat(block))))
            guard let tiny = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            tiny.interpolationQuality = .low; tiny.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            result = tiny.makeImage()
        }
        if let result {
            cache.setObject(Patch(base: base, image: result), forKey: key,
                            cost: result.bytesPerRow * result.height + base.bytesPerRow * base.height)
        }
        return result
    }
}
