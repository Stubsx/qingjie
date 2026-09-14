import Foundation
import CoreGraphics

/// Finds stationary side chrome before the first accepted scroll. Coordinates stay in source pixels.
enum ScrollLayout {
    /// Compare both stationary and displacement-aligned pixels. Random changes must not widen the pane.
    static func motionContent(first: CGImage, next: CGImage, shift: Int) throws -> [CGRect] {
        let width = first.width, overlap = first.height - abs(shift)
        guard overlap >= 100 else { return [] }
        let height = min(384, overlap), start = max(0, -shift)
        func samples(_ image: CGImage, y: Int) throws -> [UInt8] {
            guard let crop = image.cropping(to: CGRect(x: 0, y: y, width: width, height: overlap)),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let data = context.data?.assumingMemoryBound(to: UInt8.self) else { throw StitchError.allocationFailed }
            context.interpolationQuality = .low
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return Array(UnsafeBufferPointer(start: data, count: width * height * 4))
        }
        let aligned = try samples(first, y: start + shift)
        let stationary = try samples(first, y: start)
        let current = try samples(next, y: start)
        func difference(_ lhs: [UInt8], _ i: Int, _ rhs: [UInt8], _ j: Int) -> Int {
            max(abs(Int(lhs[i]) - Int(rhs[j])), abs(Int(lhs[i + 1]) - Int(rhs[j + 1])), abs(Int(lhs[i + 2]) - Int(rhs[j + 2])))
        }
        var matches = [Int](repeating: 0, count: width), conflicts = matches, detail = matches
        var movingRows: [Int] = []
        for y in 1..<height {
            var rowMatches = 0
            for x in 0..<width {
                let i = (y * width + x) * 4
                let changed = difference(stationary, i, current, i)
                let error = difference(aligned, i, current, i)
                if changed > 12 {
                    if error <= 8 { matches[x] += 1; rowMatches += 1 }
                    else if error > 12 { conflicts[x] += 1 }
                }
            }
            if rowMatches >= max(4, width / 100) { movingRows.append(y) }
        }
        var opposition = [Int](repeating: 0, count: width)
        for y in movingRows {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if difference(stationary, i, stationary, i - width * 4) > 8 { detail[x] += 1 }
                // A column is a separate pane only when it contradicts this displacement.
                // Repeated table values and empty column gutters may match both positions;
                // their lack of change is not evidence of a stationary sidebar.
                if difference(aligned, i, current, i) > 12 { opposition[x] += 1 }
            }
        }
        let active = (0..<width).filter { matches[$0] >= max(4, height / 80) && matches[$0] >= conflicts[$0] * 2 }
        guard !active.isEmpty else { return [] }
        func hasChrome(_ range: Range<Int>) -> Bool {
            range.count >= 12 && range.filter {
                opposition[$0] >= max(4, height / 80) && opposition[$0] > matches[$0] * 2
            }.count >= 4
        }
        var groups: [[Int]] = []
        for x in active {
            if let last = groups.last?.last,
               x - last <= max(32, width / 20) || !hasChrome((last + 1)..<x) { groups[groups.count - 1].append(x) }
            else { groups.append([x]) }
        }
        func margin(_ boundary: Int, _ direction: Int) -> Int {
            let anchor = direction < 0 ? boundary - 1 : boundary
            guard (0..<width).contains(anchor), detail[anchor] < 3 else { return boundary }
            var x = anchor
            while (0..<width).contains(x) {
                let different = movingRows.filter {
                    difference(stationary, ($0 * width + x) * 4, stationary, ($0 * width + anchor) * 4) > 3
                }.count
                if different >= max(8, movingRows.count * 3 / 4) { return direction < 0 ? x + 1 : x }
                if detail[x] >= 3 { break }
                x += direction
            }
            return boundary
        }
        var regions: [CGRect] = []
        for group in groups {
            guard let firstX = group.first, let lastX = group.last, lastX - firstX + 1 >= 80 else { continue }
            // A small band at the selection edge can be a scroll bar or repeated
            // trailing table cells. Do not cut off a column on such little evidence.
            let minimumSideWidth = max(12, width / 20)
            let left = firstX >= minimumSideWidth && hasChrome(0..<firstX) ? margin(firstX, -1) : 0
            let right = width - lastX - 1 >= minimumSideWidth && hasChrome((lastX + 1)..<width) ? margin(lastX + 1, 1) : width
            let region = CGRect(x: left, y: 0, width: right - left, height: first.height)
            if !regions.contains(region) { regions.append(region) }
        }
        return regions
    }

    static func horizontalContent(first: CGImage, next: CGImage) throws -> CGRect {
        let width = first.width, height = min(256, first.height)
        func samples(_ image: CGImage) throws -> [UInt8] {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let data = context.data?.assumingMemoryBound(to: UInt8.self) else { throw StitchError.allocationFailed }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return Array(UnsafeBufferPointer(start: data, count: width * height * 4))
        }
        let a = try samples(first), b = try samples(next)
        func difference(_ i: Int, _ j: Int, _ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
            max(abs(Int(lhs[i]) - Int(rhs[j])), abs(Int(lhs[i + 1]) - Int(rhs[j + 1])), abs(Int(lhs[i + 2]) - Int(rhs[j + 2])))
        }
        var changes = [Int](repeating: 0, count: width)
        var detail = [Int](repeating: 0, count: width)
        var movingRows: [Int] = []
        // Ignore rows occupied entirely by fixed headers/footers when judging sidebar texture.
        for y in 1..<height {
            var moving = 0
            for x in 0..<width where difference((y * width + x) * 4, (y * width + x) * 4, a, b) > 8 { moving += 1 }
            guard moving >= max(4, width / 100) else { continue }
            movingRows.append(y)
            for x in 0..<width {
                let i = (y * width + x) * 4
                if difference(i, i, a, b) > 8 { changes[x] += 1 }
                if difference(i, i - width * 4, a, a) > 8 { detail[x] += 1 }
            }
        }
        let minimumChanges = max(3, height / 64)
        guard let firstMoving = changes.firstIndex(where: { $0 >= minimumChanges }),
              let lastMoving = changes.lastIndex(where: { $0 >= minimumChanges }),
              lastMoving - firstMoving + 1 >= 80 else {
            return CGRect(x: 0, y: 0, width: first.width, height: first.height)
        }
        func hasChrome(_ range: Range<Int>) -> Bool {
            // Plain document margins are not evidence of a sidebar. Require stationary detail.
            range.count >= 12 && range.filter { detail[$0] >= 3 && changes[$0] < minimumChanges }.count >= 4
        }
        func includeMargin(boundary: Int, direction: Int) -> Int {
            let anchor = direction < 0 ? boundary - 1 : boundary
            guard anchor >= 0, anchor < width, detail[anchor] < 3 else { return boundary }
            var x = anchor
            while x >= 0 && x < width {
                // A solid color seam/divider separates the sidebar from otherwise still document padding.
                let differentRows = movingRows.filter {
                    difference(($0 * width + x) * 4, ($0 * width + anchor) * 4, a, a) > 3
                }.count
                if differentRows >= max(8, movingRows.count * 3 / 4) {
                    return direction < 0 ? x + 1 : x
                }
                // Never expand across sidebar text merely to retain a white margin.
                if detail[x] >= 3 { break }
                x += direction
            }
            return boundary
        }
        let left = hasChrome(0..<firstMoving) ? includeMargin(boundary: firstMoving, direction: -1) : 0
        let right = hasChrome((lastMoving + 1)..<width) ? includeMargin(boundary: lastMoving + 1, direction: 1) : width
        return CGRect(x: left, y: 0, width: right - left, height: first.height)
    }
}
