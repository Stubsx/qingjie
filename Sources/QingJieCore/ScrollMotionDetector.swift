import Foundation
import CoreGraphics

/// Local block matching distinguishes coherent scrolling from clocks, hover effects and animation.
/// It proposes a region; the stitcher still validates the complete overlap at original-pixel precision.
enum ScrollMotionDetector {
    struct Proposal {
        let region: CGRect
        let shift: Int
    }
    private struct Vote {
        let x: Int
        let shift: Int
    }

    static func detect(first: CGImage, next: CGImage, focus: CGPoint?) throws -> Proposal? {
        let width = first.width, height = first.height
        let laneWidth = min(80, width)
        let coarseStep = max(40, (width - laneWidth) / 12)
        var examined = Set<Int>()
        var votes: [Vote] = []
        func scan(step: Int) throws {
            let positions = Array(stride(from: 0, through: width - laneWidth, by: step)) + [width - laneWidth]
            for x in positions where examined.insert(x).inserted {
                let rect = CGRect(x: x, y: 0, width: laneWidth, height: height)
                guard let a = first.cropping(to: rect), let b = next.cropping(to: rect) else { continue }
                let old = try ScrollFingerprint(image: a), new = try ScrollFingerprint(image: b)
                if old.distance(to: new) < 0.35 { continue }
                let edges = old.fixedEdges(comparedTo: new)
                if let shift = old.displacement(to: new, top: edges.top, bottom: edges.bottom), shift != 0 {
                    votes.append(Vote(x: x + laneWidth / 2, shift: shift))
                }
            }
        }
        try scan(step: coarseStep)
        // Narrow panes can fall between the coarse probes. Overlapping 80px lanes close those gaps.
        if votes.count < 2 && coarseStep > 40 { try scan(step: 40) }
        guard votes.count >= 2 else { return nil }
        var candidates: [(Proposal, Int)] = []
        for shift in Set(votes.map(\.shift)).sorted() {
            let agreeing = votes.filter { $0.shift == shift }
            guard agreeing.count >= 2 else { continue }
            let regions = try ScrollLayout.motionContent(first: first, next: next, shift: shift)
            for region in regions {
                let support = agreeing.filter { CGFloat($0.x) >= region.minX && CGFloat($0.x) <= region.maxX }.count
                guard support >= 2 else { continue }
                candidates.append((Proposal(region: region, shift: shift), support))
            }
        }
        candidates.sort { $0.1 > $1.1 }
        if let focus {
            let pointed = candidates.filter { $0.0.region.contains(focus) }
            if let best = pointed.first { return best.0 }
        }
        guard let best = candidates.first else { return nil }
        // Independent panes of comparable strength need another frame or an implicit pointer hint.
        if candidates.dropFirst().contains(where: { $0.1 * 4 >= best.1 * 3 }) { return nil }
        return best.0
    }
}
