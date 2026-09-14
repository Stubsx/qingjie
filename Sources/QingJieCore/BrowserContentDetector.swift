import CoreGraphics

/// Finds a Chromium address field and the full-width boundary below its toolbar.
/// Kept separate from enclosed dialogs: web content normally touches three window edges.
enum BrowserContentDetector {
    static func contentRect(window: CGRect, occluders: [CGRect], image: CGImage, localSize: CGSize) -> CGRect? {
        guard window.width >= 360, window.height >= 240, localSize.width > 0, localSize.height > 0 else { return nil }
        let sx = CGFloat(image.width) / localSize.width, sy = CGFloat(image.height) / localSize.height
        var header = CGRect(x: window.minX, y: window.minY, width: window.width, height: min(180, window.height))
        // Only the visible toolbar is needed. A foreground window covering the page
        // below it should not disable snapping in the browser's exposed content.
        for occluder in occluders where occluder.intersects(header) {
            header.size.height = max(0, occluder.minY - header.minY)
        }
        guard header.height >= 60 else { return nil }
        let pixels = CGRect(x: header.minX * sx, y: header.minY * sy, width: header.width * sx, height: header.height * sy).integral
        guard let crop = image.cropping(to: pixels), let raster = HeaderRaster(crop),
              let boundary = raster.contentStart(scale: sy) else { return nil }
        let top = (pixels.minY + CGFloat(boundary)) / sy
        guard top > window.minY, window.maxY - top >= 120 else { return nil }
        return CGRect(x: window.minX, y: top, width: window.width, height: window.maxY - top)
    }

    private struct Color {
        let r: Int, g: Int, b: Int
        func distance(_ other: Color) -> Int { max(abs(r - other.r), abs(g - other.g), abs(b - other.b)) }
    }
    private struct HeaderRaster {
        let width: Int, height: Int
        let colors: [Color]
        init?(_ image: CGImage) {
            width = min(480, image.width); height = image.height
            guard width > 0, height > 0, width <= 2_000_000 / height,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            colors = (0..<(width * height)).map { Color(r: Int(bytes[$0 * 4]), g: Int(bytes[$0 * 4 + 1]), b: Int(bytes[$0 * 4 + 2])) }
        }
        func row(_ y: Int, _ start: Double, _ end: Double) -> [Color] {
            Array(colors[(y * width + Int(Double(width) * start))..<(y * width + Int(Double(width) * end))])
        }
        func median(_ values: [Color]) -> Color {
            Color(r: values.map(\.r).sorted()[values.count / 2],
                  g: values.map(\.g).sorted()[values.count / 2], b: values.map(\.b).sorted()[values.count / 2])
        }
        func fraction(_ values: [Color], like color: Color, tolerance: Int = 4) -> Double {
            Double(values.filter { $0.distance(color) <= tolerance }.count) / Double(values.count)
        }
        func fieldRow(_ y: Int) -> Color? {
            let left = row(y, 0.015, 0.06), right = row(y, 0.96, 0.99), center = row(y, 0.22, 0.82)
            let outside = median(left + right), inside = median(center)
            guard median(left).distance(median(right)) <= 8, inside.distance(outside) >= 5,
                  fraction(left + right, like: outside, tolerance: 8) >= 0.65,
                  fraction(center, like: inside) >= 0.70 else { return nil }
            return outside
        }
        func contentStart(scale: CGFloat) -> Int? {
            let unit = Double(scale)
            let first = max(1, Int(20 * unit)), last = min(height - 1, Int(130 * unit))
            guard first < last else { return nil }
            var y = first
            while y < last {
                guard let toolbar = fieldRow(y) else { y += 1; continue }
                let start = y
                while y < last, let color = fieldRow(y), color.distance(toolbar) <= 8 { y += 1 }
                let end = y
                guard Double(end - start) >= 18 * unit, Double(end - start) <= 48 * unit else { continue }
                // The address field sits inside a toolbar with visible padding above it.
                var toolbarTop = start
                while toolbarTop > max(0, start - Int(20 * unit)),
                      fraction(row(toolbarTop - 1, 0.02, 0.98), like: toolbar, tolerance: 6) >= 0.78 {
                    toolbarTop -= 1
                }
                let padding = start - toolbarTop
                guard Double(padding) >= 2 * unit, Double(padding) <= 16 * unit else { continue }
                let inferred = end + padding
                let searchStart = end + max(1, Int(2 * unit))
                let searchEnd = min(height - 1, end + Int(44 * unit))
                guard searchStart < searchEnd else { continue }
                // A browser separator spans the window, unlike the field's bottom
                // edge or a page card. This also handles an additional bookmarks row.
                for boundary in searchStart...searchEnd {
                    let before = row(boundary - 1, 0.02, 0.98), after = row(boundary, 0.02, 0.98)
                    let differences = zip(before, after).map { $0.distance($1) }
                    if Double(differences.filter { $0 >= 2 }.count) / Double(differences.count) >= 0.90 {
                        return boundary
                    }
                }
                // White-on-white pages can have no visible divider at all. Use the
                // measured field/padding geometry, rather than a fixed titlebar height.
                return inferred < height ? inferred : nil
            }
            return nil
        }
    }
}
