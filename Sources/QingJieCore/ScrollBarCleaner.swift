import Foundation
import CoreGraphics

/// Recognizes an overlay thumb in a flat right gutter. A second, successfully
/// matched frame must prove that it does not move with the document before any
/// pixels are covered. Only a narrow edge sample is retained between frames.
struct ScrollBarSample {
    struct Mask {
        let rect: CGRect
        let background: UInt32
        var isConfirmed = false

        var track: Range<Int> { Int(rect.minX)..<Int(rect.maxX) }

        func cropped(to region: CGRect) -> Mask? {
            let intersection = rect.intersection(region)
            guard !intersection.isNull, !intersection.isEmpty else { return nil }
            return Mask(rect: intersection.offsetBy(dx: -region.minX, dy: -region.minY), background: background, isConfirmed: isConfirmed)
        }

        func draw(in context: CGContext, imageHeight: Int, offset: Int) {
            guard isConfirmed else { return }
            context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         components: [CGFloat((background >> 16) & 255) / 255,
                                                      CGFloat((background >> 8) & 255) / 255,
                                                      CGFloat(background & 255) / 255, 1])!)
            context.fill(CGRect(x: rect.minX, y: CGFloat(imageHeight - offset) - rect.maxY,
                                width: rect.width, height: rect.height))
        }

        static func sameTrack(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
            abs(a.lowerBound - b.lowerBound) <= 2 && abs(a.upperBound - b.upperBound) <= 2
        }
    }

    let mask: Mask?
    private let originX: Int
    private let width: Int
    private let height: Int
    private let pixels: [UInt32]

    init(image: CGImage) throws {
        let width = min(64, image.width / 4), height = image.height, originX = image.width - width
        self.width = width; self.height = height; self.originX = originX
        guard let edge = image.cropping(to: CGRect(x: originX, y: 0, width: width, height: height)),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { throw StitchError.allocationFailed }
        context.draw(edge, in: CGRect(x: 0, y: 0, width: width, height: height))
        var values = [UInt32](repeating: 0, count: width * height)
        var colors: [UInt32: Int] = [:]
        for i in values.indices {
            let color = UInt32(data[i * 4]) << 16 | UInt32(data[i * 4 + 1]) << 8 | UInt32(data[i * 4 + 2])
            // Transparent window corners cannot supply replacement pixels.
            values[i] = color | UInt32(data[i * 4 + 3]) << 24
            if data[i * 4 + 3] == 255 { colors[color, default: 0] += 1 }
        }
        pixels = values
        guard let background = colors.max(by: { $0.value < $1.value }), background.value >= values.count / 3 else {
            mask = nil; return
        }
        let bg = background.key
        func isBackground(_ i: Int) -> Bool { values[i] >> 24 == 255 && Self.distance(values[i], bg) <= 2 }
        var visited = [Bool](repeating: false, count: values.count)
        var candidates: [Mask] = []
        for start in values.indices where !visited[start] && !isBackground(start) {
            var component = [start], cursor = 0
            visited[start] = true
            var left = start % width, right = left, top = start / width, bottom = top
            while cursor < component.count {
                let i = component[cursor], x = i % width, y = i / width
                cursor += 1
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let next = ny * width + nx
                    if !visited[next] && !isBackground(next) { visited[next] = true; component.append(next) }
                }
            }
            let w = right - left + 1, h = bottom - top + 1
            guard w >= 3, w <= 32, h >= max(24, w * 3), h <= height * 4 / 5,
                  left >= 3, right + 3 < width, width - right <= 24,
                  component.count >= w * h * 4 / 5 else { continue }
            // A neutral translucent thumb changes all channels by the same amount,
            // on both light and dark surfaces. Colored content is never removed.
            guard component.allSatisfy({ i in
                let deltas = [16, 8, 0].map { Int((values[i] >> $0) & 255) - Int((bg >> $0) & 255) }
                return values[i] >> 24 == 255 && deltas.max()! - deltas.min()! <= 8
            }) else { continue }
            let surround = (max(0, top - 2)...min(height - 1, bottom + 2)).allSatisfy { y in
                (left - 3...right + 3).allSatisfy { x in
                    (x >= left && x <= right && y >= top && y <= bottom) || isBackground(y * width + x)
                }
            }
            guard surround else { continue }
            // Include the faint antialiased fringe; the surrounding band above
            // has already been checked to be empty and the same background color.
            candidates.append(Mask(rect: CGRect(x: originX + left - 1, y: max(0, top - 1), width: w + 2,
                                                 height: min(height, bottom + 2) - max(0, top - 1)), background: bg))
        }
        mask = candidates.count == 1 ? candidates[0] : nil
    }

    func confirmedTrack(comparedTo next: ScrollBarSample, shift: Int) -> Range<Int>? {
        guard shift > 0, originX == next.originX, width == next.width, height == next.height else { return nil }
        switch (mask, next.mask) {
        case let (old?, new?):
            guard Mask.sameTrack(old.track, new.track), Self.distance(old.background, new.background) <= 2,
                  abs(old.rect.height - new.rect.height) <= max(4, old.rect.width) else { return nil }
            let movement = new.rect.minY - old.rect.minY
            // Forward scrolling moves document marks upwards; the scroll thumb
            // stays put or moves down by less than the document displacement.
            guard movement >= 0, movement <= CGFloat(shift) + 1 else { return nil }
            return new.track
        case let (old?, nil):
            return next.isBlank(old.rect.offsetBy(dx: 0, dy: -CGFloat(shift)), color: old.background) ? old.track : nil
        case let (nil, new?):
            return isBlank(new.rect.offsetBy(dx: 0, dy: CGFloat(shift)), color: new.background) ? new.track : nil
        default: return nil
        }
    }

    private func isBlank(_ rect: CGRect, color: UInt32) -> Bool {
        let bounds = CGRect(x: originX, y: 0, width: width, height: height)
        // An ordinary document mark entering/leaving the viewport is not a fade.
        guard bounds.contains(rect) else { return false }
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let pixel = pixels[y * width + x - originX]
                if pixel >> 24 != 255 || Self.distance(pixel, color) > 2 { return false }
            }
        }
        return true
    }

    private static func distance(_ a: UInt32, _ b: UInt32) -> Int {
        max(abs(Int((a >> 16) & 255) - Int((b >> 16) & 255)),
            abs(Int((a >> 8) & 255) - Int((b >> 8) & 255)), abs(Int(a & 255) - Int(b & 255)))
    }
}
