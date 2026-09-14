import CoreGraphics
import Foundation

/// Recognizes flat, enclosed UI surfaces in a frozen screenshot. No DOM, AX
/// permission, network model, or per-mouse-move image processing is needed.
public enum InAppPanelDetector {
    public static func enrich(_ windows: [WindowSelectionTarget], image: CGImage,
                              localSize: CGSize) -> [WindowSelectionTarget] {
        guard !windows.isEmpty, localSize.width > 0, localSize.height > 0,
              localSize.width.isFinite, localSize.height.isFinite,
              let raster = GrayRaster(image: image, maximumDimension: 1100) else { return windows }
        let sx = localSize.width / CGFloat(raster.width), sy = localSize.height / CGFloat(raster.height)
        let pixelX = CGFloat(image.width) / CGFloat(raster.width), pixelY = CGFloat(image.height) / CGFloat(raster.height)
        let minWidth = max(28, Int(120 / sx)), minHeight = max(24, Int(80 / sy))
        var candidates: [(owner: Int, rect: CGRect, strength: Double)] = []
        for shift in [0, 8, 16] {
            for rect in raster.surfaces(shift: shift, minWidth: minWidth, minHeight: minHeight) {
                let local = CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy)
                guard let owner = windows.firstIndex(where: { $0.rect.contains(CGPoint(x: local.midX, y: local.midY)) }),
                      windows[owner].rect.insetBy(dx: 2, dy: 2).contains(local),
                      local.width < windows[owner].rect.width * 0.96, local.height < windows[owner].rect.height * 0.96,
                      local.width * local.height >= windows[owner].rect.width * windows[owner].rect.height * 0.018,
                      !windows.prefix(owner).contains(where: { $0.rect.intersects(local) }),
                      let evidence = raster.enclosure(rect) else { continue }
                let source = CGRect(x: rect.minX * pixelX, y: rect.minY * pixelY,
                                    width: rect.width * pixelX, height: rect.height * pixelY)
                let refined = refine(source, image: image, polarity: evidence.polarity,
                                     search: Int(ceil(max(pixelX, pixelY) * 2)) + 3)
                let result = CGRect(x: refined.minX * localSize.width / CGFloat(image.width),
                                    y: refined.minY * localSize.height / CGFloat(image.height),
                                    width: refined.width * localSize.width / CGFloat(image.width),
                                    height: refined.height * localSize.height / CGFloat(image.height))
                guard windows[owner].rect.contains(result), !windows.prefix(owner).contains(where: { $0.rect.intersects(result) }) else { continue }
                candidates.append((owner, result, evidence.strength))
            }
        }
        return windows.enumerated().map { index, window in
            var panels: [CGRect] = []
            let sorted = candidates.filter { $0.owner == index }.sorted {
                let a = $0.rect.width * $0.rect.height, b = $1.rect.width * $1.rect.height
                return a != b ? a > b : $0.strength > $1.strength
            }
            for candidate in sorted {
                // Prefer a dialog's outer boundary over cards or controls inside it.
                if panels.contains(where: { $0.insetBy(dx: -3, dy: -3).contains(candidate.rect) }) { continue }
                panels.append(candidate.rect)
                if panels.count == 8 { break }
            }
            let content = window.canDetectBrowserContent
                ? BrowserContentDetector.contentRect(window: window.rect, occluders: windows.prefix(index).map(\.rect),
                                                     image: image, localSize: localSize) : nil
            return WindowSelectionTarget(id: window.id, rect: window.rect, name: window.name, panels: panels,
                                         browserContent: content, canDetectBrowserContent: window.canDetectBrowserContent)
        }
    }

    private static func refine(_ rect: CGRect, image: CGImage, polarity: Int, search: Int) -> CGRect {
        func edge(_ guess: CGFloat, start: CGFloat, end: CGFloat, horizontal: Bool, direction: Int) -> CGFloat {
            let inset = (end - start) * 0.15
            let band = horizontal
                ? CGRect(x: ceil(start + inset), y: floor(guess) - CGFloat(search), width: floor(end - start - inset * 2), height: CGFloat(search * 2 + 1))
                : CGRect(x: floor(guess) - CGFloat(search), y: ceil(start + inset), width: CGFloat(search * 2 + 1), height: floor(end - start - inset * 2))
            let clipped = band.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
            guard !clipped.isEmpty, let crop = image.cropping(to: clipped),
                  let strip = GrayRaster(image: crop, width: horizontal ? min(160, crop.width) : crop.width,
                                         height: horizontal ? crop.height : min(160, crop.height)) else { return guess.rounded() }
            let length = horizontal ? strip.width : strip.height, depth = horizontal ? strip.height : strip.width
            var bestScore = 6.0, best = guess.rounded()
            for p in 1..<depth {
                var sum = 0
                for t in 0..<length {
                    let a = horizontal ? strip[t, p - 1] : strip[p - 1, t]
                    let b = horizontal ? strip[t, p] : strip[p, t]
                    sum += (b - a) * direction * polarity
                }
                let score = Double(sum) / Double(length)
                if score > bestScore { bestScore = score; best = (horizontal ? clipped.minY : clipped.minX) + CGFloat(p) }
            }
            return best
        }
        let top = edge(rect.minY, start: rect.minX, end: rect.maxX, horizontal: true, direction: 1)
        let bottom = edge(rect.maxY, start: rect.minX, end: rect.maxX, horizontal: true, direction: -1)
        let left = edge(rect.minX, start: top, end: bottom, horizontal: false, direction: 1)
        let right = edge(rect.maxX, start: top, end: bottom, horizontal: false, direction: -1)
        return right > left && bottom > top ? CGRect(x: left, y: top, width: right - left, height: bottom - top) : rect
    }

    private struct GrayRaster {
        let width: Int, height: Int
        let values: [UInt8]
        subscript(_ x: Int, _ y: Int) -> Int { Int(values[y * width + x]) }
        init?(image: CGImage, maximumDimension: Int) {
            let scale = min(1, Double(maximumDimension) / Double(max(image.width, image.height)))
            self.init(image: image, width: max(1, Int(Double(image.width) * scale)), height: max(1, Int(Double(image.height) * scale)))
        }
        init?(image: CGImage, width: Int, height: Int) {
            guard width >= 1, height >= 1, width <= 2_000_000 / height,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .low; context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            self.width = width; self.height = height
            var gray = [UInt8](repeating: 0, count: width * height)
            for i in gray.indices {
                let red = Int(data[i * 4]) * 54, green = Int(data[i * 4 + 1]) * 183, blue = Int(data[i * 4 + 2]) * 19
                gray[i] = UInt8((red + green + blue) / 256)
            }
            values = gray
        }
        func surfaces(shift: Int, minWidth: Int, minHeight: Int) -> [CGRect] {
            guard width >= minWidth, height >= minHeight else { return [] }
            var visited = [Bool](repeating: false, count: values.count)
            var queue = [Int](repeating: 0, count: values.count), results: [CGRect] = []
            let bands = values.map { UInt8((Int($0) + shift) / 32) }
            for seed in values.indices where !visited[seed] {
                var head = 0, count = 1
                queue[0] = seed; visited[seed] = true
                let band = bands[seed]
                var minX = seed % width, maxX = minX, minY = seed / width, maxY = minY
                while head < count {
                    let i = queue[head], x = i % width, y = i / width; head += 1
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    func visit(_ next: Int) {
                        if !visited[next], bands[next] == band { visited[next] = true; queue[count] = next; count += 1 }
                    }
                    if x > 0 { visit(i - 1) }; if x + 1 < width { visit(i + 1) }
                    if y > 0 { visit(i - width) }; if y + 1 < height { visit(i + width) }
                }
                let w = maxX - minX + 1, h = maxY - minY + 1
                guard w >= minWidth, h >= minHeight, w < h * 7, h < w * 7,
                      Double(count) / Double(w * h) > 0.65 else { continue }
                results.append(CGRect(x: minX, y: minY, width: w, height: h))
            }
            return results
        }
        func enclosure(_ rect: CGRect) -> (polarity: Int, strength: Double)? {
            let left = Int(rect.minX), top = Int(rect.minY), right = Int(rect.maxX), bottom = Int(rect.maxY)
            guard left >= 4, top >= 4, right + 4 < width, bottom + 4 < height else { return nil }
            var sides: [[Int]] = [], interiors: [Int] = []
            for side in 0..<4 {
                var differences: [Int] = []
                for step in 0..<40 {
                    let fraction = 0.12 + 0.76 * Double(step) / 39
                    let x = left + Int(Double(right - left) * fraction), y = top + Int(Double(bottom - top) * fraction)
                    let inside: Int, outside: Int
                    switch side {
                    case 0: inside = self[x, top + 3]; outside = self[x, top - 3]
                    case 1: inside = self[x, bottom - 4]; outside = self[x, bottom + 2]
                    case 2: inside = self[left + 3, y]; outside = self[left - 3, y]
                    default: inside = self[right - 4, y]; outside = self[right + 2, y]
                    }
                    differences.append(inside - outside); interiors.append(inside)
                }
                sides.append(differences)
            }
            let polarity = sides[0].sorted()[20] >= 0 ? 1 : -1
            guard sides.allSatisfy({ side in side.filter { $0 * polarity >= 20 }.count >= 30 }) else { return nil }
            let levels = interiors.sorted()
            guard levels[levels.count * 9 / 10] - levels[levels.count / 10] <= 32 else { return nil }
            let strength = sides.map { $0.map { $0 * polarity }.sorted()[20] }.min() ?? 0
            return (polarity, Double(strength))
        }
    }
}
