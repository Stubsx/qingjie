import Foundation

/// Advance only after the previous screenshot was matched, with overlap and time to settle.
public struct ScrollAutoAdvance {
    public enum Decision: Equatable { case wait, advance, stopped, lostOverlap }
    private var lastStep: TimeInterval?
    private var heightAtStep = 0
    private var stationarySteps = 0
    public init() {}

    public mutating func observe(_ outcome: StitchOutcome?, height: Int, now: TimeInterval) -> Decision {
        switch outcome {
        case .noOverlap, .backwards, .limitReached: return .lostOverlap
        case nil, .settling:
            return lastStep.map { now - $0 >= 4 } == true ? .lostOverlap : .wait
        case .appended, .unchanged: break
        }
        if let lastStep, now - lastStep < 0.8 { return .wait }
        if lastStep != nil {
            stationarySteps = height > heightAtStep ? 0 : stationarySteps + 1
            if stationarySteps >= 3 { return .stopped }
        }
        heightAtStep = height; lastStep = now
        return .advance
    }
}
