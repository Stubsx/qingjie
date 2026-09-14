import Foundation
import CoreGraphics

public enum StitchError: Error, LocalizedError {
    case invalidImage, invalidRegion, differentSize, allocationFailed, limitReached
    public var errorDescription: String? {
        switch self {
        case .invalidImage: return "截取区域太小，请选择至少 80 × 100 像素的滚动内容。"
        case .invalidRegion: return "内容区必须在截图内，且至少为 80 × 100 像素。"
        case .differentSize: return "截图尺寸发生变化，请保持窗口大小和显示器缩放不变。"
        case .allocationFailed: return "无法分配图片内存，请缩小截图区域后重试。"
        case .limitReached: return "已达到长截图长度上限，请完成当前截图后另起一张。"
        }
    }
}

public enum StitchOutcome: Equatable {
    case appended(Int), unchanged, backwards, settling, noOverlap, limitReached
}

/// Narrow horizontal samples retain every source row, so displacement is refined to one original pixel.
public struct ScrollFingerprint: Sendable {
    let width: Int
    let height: Int
    let values: [UInt8]
    let energy: [Double]

    public init(image: CGImage) throws {
        guard image.width >= 80, image.height >= 100 else { throw StitchError.invalidImage }
        width = min(96, image.width); height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { throw StitchError.allocationFailed }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Drop side margins, including common scroll bars and selection borders.
        let margin = max(2, image.width / 25)
        guard let center = image.cropping(to: CGRect(x: margin, y: 0, width: image.width - margin * 2, height: height)) else { throw StitchError.invalidImage }
        context.interpolationQuality = .low
        context.draw(center, in: CGRect(x: 0, y: 0, width: width, height: height))
        var gray = [UInt8](repeating: 0, count: width * height)
        for i in gray.indices {
            let red = Int(data[i * 4]) * 54
            let green = Int(data[i * 4 + 1]) * 183
            let blue = Int(data[i * 4 + 2]) * 19
            gray[i] = UInt8((red + green + blue) / 256)
        }
        values = gray
        var detail = [Double](repeating: 0, count: height)
        for y in 0..<height {
            var sum = 0
            for x in 1..<width {
                sum += abs(Int(gray[y * width + x]) - Int(gray[y * width + x - 1]))
                if y > 0 { sum += abs(Int(gray[y * width + x]) - Int(gray[(y - 1) * width + x])) }
            }
            detail[y] = Double(sum) / Double(width)
        }
        energy = detail
    }

    public func distance(to other: ScrollFingerprint) -> Double {
        guard width == other.width, height == other.height else { return .infinity }
        var sum = 0, count = 0
        for y in stride(from: 0, to: height, by: max(1, height / 240)) {
            for x in stride(from: 0, to: width, by: 2) {
                sum += abs(Int(values[y * width + x]) - Int(other.values[y * width + x])); count += 1
            }
        }
        return Double(sum) / Double(max(1, count))
    }

    private func rowDistance(_ row: Int, to other: ScrollFingerprint, row otherRow: Int) -> Double {
        var sum = 0
        for x in 2..<(width - 2) { sum += abs(Int(values[row * width + x]) - Int(other.values[otherRow * width + x])) }
        return Double(sum) / Double(width - 4)
    }

    /// Rubber-band overscroll often exposes a flat strip below the document. Do not
    /// commit that strip until it settles; genuine page padding is accepted afterward.
    func hasQuietTail(shift: Int, bottom: Int) -> Bool {
        let end = height - bottom
        // Inspect the entire newly exposed strip, not just its last few rows:
        // ordinary text cards often end in whitespace during continuous scrolling.
        let length = shift
        guard length > 0, end >= length else { return false }
        let detailed = energy[(end - length)..<end].filter { $0 > 1.8 }.count
        return detailed <= length / 10
    }

    func fixedEdges(comparedTo other: ScrollFingerprint, shift: Int? = nil) -> (top: Int, bottom: Int) {
        func edge(reverse: Bool) -> Int {
            var count = 0, texturedRows = 0
            for index in 0..<((height - 100) / 2) {
                let y = reverse ? height - index - 1 : index
                guard rowDistance(y, to: other, row: y) < 0.9 else { break }
                count += 1
                if energy[y] > 2 { texturedRows += 1 }
            }
            // Pure white padding is scrolling content, not evidence of a fixed toolbar.
            if count >= 12 && texturedRows >= 3 { return count }
            // A 1–8px viewport divider/shadow has too few textured rows for the
            // toolbar test. Require a known displacement and a stable, almost
            // uniform band that disagrees with its scrolling counterpart.
            guard let shift, shift != 0 else { return 0 }
            var thin = 0, hasRule = false
            for index in 0..<min(8, height) {
                let y = reverse ? height - index - 1 : index
                let row = values[(y * width)..<((y + 1) * width)].sorted()
                guard rowDistance(y, to: other, row: y) < 2.5,
                      Int(row[width * 9 / 10]) - Int(row[width / 10]) <= 10 else { break }
                thin += 1
                let alignedY = y - shift
                let error: Double
                if (0..<height).contains(alignedY) {
                    error = rowDistance(y, to: other, row: alignedY)
                } else if (0..<height).contains(y + shift) {
                    error = rowDistance(y + shift, to: other, row: y)
                } else { error = 0 }
                if row[width / 2] < 240 && error > 16 { hasRule = true }
            }
            return hasRule ? thin : 0
        }
        return (edge(reverse: false), edge(reverse: true))
    }

    func displacement(to next: ScrollFingerprint, top: Int, bottom: Int) -> Int? {
        let contentHeight = height - top - bottom
        guard contentHeight >= 80 else { return nil }
        let maximum = contentHeight - max(64, contentHeight / 5)
        // Test every pixel displacement. Skipping offsets can miss thin text strokes entirely.
        let step = 1
        struct Candidate { let shift: Int; let error: Double }
        func score(_ shift: Int, dense: Bool = false) -> Double {
            let first = top + max(0, -shift), last = height - bottom - max(0, shift)
            guard last - first >= max(64, contentHeight / 5) else { return .infinity }
            var errors: [Double] = [], firstDetail = last, lastDetail = first
            let rowStep = dense ? 1 : max(1, (last - first) / 96)
            for (probe, baseRow) in stride(from: first, to: last, by: rowStep).enumerated() {
                // Jitter avoids aliasing repeated line heights with the sampling interval.
                let row = min(last - 1, baseRow + (probe * 37 + 11) % rowStep)
                let oldRow = row + shift
                guard max(energy[oldRow], next.energy[row]) >= 1.8 else { continue }
                errors.append(rowDistance(oldRow, to: next, row: row))
                firstDetail = min(firstDetail, row); lastDetail = max(lastDetail, row)
            }
            guard errors.count >= 6, lastDetail - firstDetail >= (last - first) / 3 else { return .infinity }
            errors.sort()
            // Small animated elements may change independently of the scrollable document.
            let keep = max(6, Int(Double(errors.count) * 0.90))
            let retained = errors.prefix(keep)
            return retained.reduce(0, +) / Double(retained.count)
        }
        var coarse: [Candidate] = []
        for shift in stride(from: -maximum, through: maximum, by: step) {
            coarse.append(Candidate(shift: shift, error: score(shift)))
        }
        coarse.sort { $0.error < $1.error }
        var seeds: [Candidate] = []
        for candidate in coarse where candidate.error.isFinite {
            if seeds.allSatisfy({ abs($0.shift - candidate.shift) > step * 3 }) { seeds.append(candidate) }
            if seeds.count == 8 { break }
        }
        var refined: [Int: Double] = [:]
        for seed in seeds {
            for shift in max(-maximum, seed.shift - step * 2)...min(maximum, seed.shift + step * 2) {
                refined[shift] = score(shift)
            }
        }
        let sampled = refined.map { Candidate(shift: $0.key, error: $0.value) }.sorted { $0.error < $1.error }
        var finalists = Array(sampled.prefix(12))
        // Include the best representative of every distant basin when checking ambiguity.
        for candidate in sampled where finalists.allSatisfy({ abs($0.shift - candidate.shift) > max(3, step * 2) }) {
            finalists.append(candidate)
            if finalists.count >= 20 { break }
        }
        let ranked = finalists.map { Candidate(shift: $0.shift, error: score($0.shift, dense: true)) }.sorted { $0.error < $1.error }
        guard let best = ranked.first, best.error <= 5.0 else { return nil }
        // Repeated rows, blank documents, and non-overlapping pages must never be guessed.
        if let alternative = ranked.first(where: { abs($0.shift - best.shift) > max(3, step * 2) }),
           alternative.error <= best.error + 0.05 || alternative.error < best.error * 1.35 { return nil }
        return best.shift
    }
}

/// Stores only new, independently owned strips; old screenshot buffers are not retained per frame.
public final class VerticalStitcher {
    public struct Limits: Sendable {
        public var maximumPixels: Int
        public var maximumHeight: Int
        public var maximumFrames: Int
        public init(maximumPixels: Int = 32_000_000, maximumHeight: Int = 40_000, maximumFrames: Int = 1_000) {
            self.maximumPixels = maximumPixels; self.maximumHeight = maximumHeight; self.maximumFrames = maximumFrames
        }
    }
    public private(set) var frameCount = 1
    public private(set) var totalHeight: Int
    public var width: Int { Int(outputRegion.width) }
    public var frameHeight: Int { Int(outputRegion.height) }
    public private(set) var outputRegion: CGRect
    public var scrollingRegion: CGRect {
        let top = edges?.top ?? 0, bottom = edges?.bottom ?? 0
        return CGRect(x: outputRegion.minX, y: outputRegion.minY + CGFloat(top),
                      width: outputRegion.width, height: outputRegion.height - CGFloat(top + bottom))
    }
    public var layoutLocked: Bool { edges != nil }
    public private(set) var usesMotionRecognition = false
    private let sourceWidth: Int
    private let sourceHeight: Int
    private let automaticSides: Bool
    private let limits: Limits
    private var previous: ScrollFingerprint
    private var strips: [CGImage]
    private var footer: CGImage?
    private var edges: (top: Int, bottom: Int)?
    private struct TailCheckpoint {
        let previous: ScrollFingerprint
        let stripCount: Int
        let firstStrip: CGImage
        let footer: CGImage?
        let edges: (top: Int, bottom: Int)?
        let region: CGRect
        let height: Int
        let count: Int
        let recognized: Bool
    }
    private var quietTailCheckpoint: TailCheckpoint?

    /// A manual region disables automatic side cropping, preserving its exact horizontal bounds.
    public init(first: CGImage, contentRegion: CGRect? = nil, limits: Limits = Limits()) throws {
        let bounds = CGRect(x: 0, y: 0, width: first.width, height: first.height)
        let region = contentRegion ?? bounds
        guard region.minX.isFinite, region.minY.isFinite, region.width.isFinite, region.height.isFinite,
              region == region.integral, bounds.contains(region), region.width >= 80, region.height >= 100 else { throw StitchError.invalidRegion }
        guard Int(region.height) <= limits.maximumHeight, Int(region.width) <= limits.maximumPixels / Int(region.height) else { throw StitchError.limitReached }
        let firstContent = try Self.copy(first, rect: region)
        previous = try ScrollFingerprint(image: firstContent)
        sourceWidth = first.width; sourceHeight = first.height
        outputRegion = region; totalHeight = Int(region.height); self.limits = limits
        automaticSides = contentRegion == nil
        strips = [firstContent]
    }

    @discardableResult public func append(_ image: CGImage, focusPoint: CGPoint? = nil, allowQuietTail: Bool = true) throws -> StitchOutcome {
        guard image.width == sourceWidth, image.height == sourceHeight else { throw StitchError.differentSize }
        var candidateRegion = automaticSides && edges == nil ? try ScrollLayout.horizontalContent(first: strips[0], next: image) : outputRegion
        guard var content = image.cropping(to: candidateRegion) else { throw StitchError.invalidRegion }
        var next = try ScrollFingerprint(image: content)
        var reference: ScrollFingerprint
        if candidateRegion != outputRegion {
            guard let initial = strips[0].cropping(to: candidateRegion) else { throw StitchError.invalidRegion }
            reference = try ScrollFingerprint(image: initial)
        } else { reference = previous }
        var insets = edges ?? reference.fixedEdges(comparedTo: next)
        var matchedShift = reference.distance(to: next) < 0.35 ? 0 : reference.displacement(to: next, top: insets.top, bottom: insets.bottom)
        var recognizedMotion = false
        if automaticSides && edges == nil && reference.distance(to: next) >= 0.35,
           let proposal = try ScrollMotionDetector.detect(first: strips[0], next: image, focus: focusPoint),
           let oldContent = strips[0].cropping(to: proposal.region), let newContent = image.cropping(to: proposal.region) {
            let old = try ScrollFingerprint(image: oldContent), new = try ScrollFingerprint(image: newContent)
            let borders = old.fixedEdges(comparedTo: new)
            // A local vote alone is insufficient: validate the whole proposed pane before changing state.
            if old.displacement(to: new, top: borders.top, bottom: borders.bottom) == proposal.shift {
                candidateRegion = proposal.region; reference = old; next = new; content = newContent
                insets = borders; matchedShift = proposal.shift; recognizedMotion = true
            }
        }
        guard let shift = matchedShift else { return .noOverlap }
        if shift < 0 {
            if let checkpoint = quietTailCheckpoint {
                // A held rubber-band can look stable. Reclaim only the flat tail if
                // it subsequently springs back; already confirmed content is untouched.
                strips.removeLast(strips.count - checkpoint.stripCount); strips[0] = checkpoint.firstStrip
                previous = checkpoint.previous; footer = checkpoint.footer; edges = checkpoint.edges
                outputRegion = checkpoint.region; totalHeight = checkpoint.height; frameCount = checkpoint.count
                usesMotionRecognition = checkpoint.recognized; quietTailCheckpoint = nil
                return try append(image, focusPoint: focusPoint, allowQuietTail: false)
            }
            return .backwards
        }
        if shift == 0 { return .unchanged }
        if edges == nil {
            insets = reference.fixedEdges(comparedTo: next, shift: shift)
        }
        let quietTail = next.hasQuietTail(shift: shift, bottom: insets.bottom)
        if !allowQuietTail && quietTail { return .settling }
        let contentWidth = Int(candidateRegion.width), contentHeight = Int(candidateRegion.height)
        guard totalHeight + shift <= limits.maximumHeight, totalHeight + shift <= limits.maximumPixels / contentWidth,
              frameCount < limits.maximumFrames else { return .limitReached }
        let end = contentHeight - insets.bottom
        let addition = try Self.copy(content, rect: CGRect(x: 0, y: end - shift, width: contentWidth, height: shift))
        let newFooter = insets.bottom > 0 ? try Self.copy(content, rect: CGRect(x: 0, y: end, width: contentWidth, height: insets.bottom)) : nil
        if quietTail && quietTailCheckpoint == nil {
            quietTailCheckpoint = TailCheckpoint(previous: previous, stripCount: strips.count, firstStrip: strips[0], footer: footer,
                                                 edges: edges, region: outputRegion, height: totalHeight, count: frameCount, recognized: usesMotionRecognition)
        } else if !quietTail { quietTailCheckpoint = nil }
        if edges == nil {
            // Commit the layout only after a reliable forward match. Rejected frames cannot crop the result.
            let x = candidateRegion.minX - outputRegion.minX
            strips[0] = try Self.copy(strips[0], rect: CGRect(x: x, y: 0, width: CGFloat(contentWidth), height: CGFloat(end)))
        }
        strips.append(addition); footer = newFooter; edges = insets; previous = next; outputRegion = candidateRegion
        usesMotionRecognition = usesMotionRecognition || recognizedMotion
        totalHeight += shift; frameCount += 1
        return .appended(shift)
    }

    public func compose() throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: totalHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw StitchError.allocationFailed }
        var offset = 0
        for part in strips + (footer.map { [$0] } ?? []) {
            context.draw(part, in: CGRect(x: 0, y: totalHeight - offset - part.height, width: width, height: part.height))
            offset += part.height
        }
        guard offset == totalHeight, let result = context.makeImage() else { throw StitchError.allocationFailed }
        return result
    }

    public func preview(maximumHeight: Int = 260, maximumWidth: Int = 160) throws -> CGImage {
        let scale = min(1, Double(min(4096, max(1, maximumHeight))) / Double(totalHeight),
                        Double(min(1024, max(1, maximumWidth))) / Double(width))
        let w = max(1, Int(Double(width) * scale)), h = max(1, Int(Double(totalHeight) * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw StitchError.allocationFailed }
        // Adjacent strips share fractional device-pixel edges when scaled. Edge
        // antialiasing blends each strip separately with the transparent canvas,
        // leaving a translucent horizontal seam even when the source is opaque.
        // Use the same hard coverage for both sides of each join; image
        // interpolation still smooths the screenshot's pixels inside the strips.
        context.setShouldAntialias(false)
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(w) / CGFloat(width), y: CGFloat(h) / CGFloat(totalHeight))
        var offset = 0
        for part in strips + (footer.map { [$0] } ?? []) {
            context.draw(part, in: CGRect(x: 0, y: totalHeight - offset - part.height, width: width, height: part.height)); offset += part.height
        }
        guard let image = context.makeImage() else { throw StitchError.allocationFailed }; return image
    }

    private static func copy(_ image: CGImage, rect: CGRect) throws -> CGImage {
        guard let cropped = image.cropping(to: rect), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(rect.width), height: Int(rect.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw StitchError.allocationFailed }
        context.draw(cropped, in: CGRect(origin: .zero, size: rect.size))
        guard let copy = context.makeImage() else { throw StitchError.allocationFailed }; return copy
    }
}
