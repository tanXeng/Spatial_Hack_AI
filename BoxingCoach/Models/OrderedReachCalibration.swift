import Foundation

nonisolated struct OrderedReachCalibration: Sendable {
    enum Stage: Equatable, Sendable {
        case awaitingGuard(BodySide)
        case measuring(BodySide)
        case complete

        /// The arm this stage concerns, or `nil` once both are done. Lives here rather than only on
        /// the sequence so the calibration screen can render per-arm progress from the published
        /// stage alone.
        var activeSide: BodySide? {
            switch self {
            case .awaitingGuard(let side), .measuring(let side): return side
            case .complete: return nil
            }
        }

        var isMeasuring: Bool {
            if case .measuring = self { return true }
            return false
        }
    }

    private(set) var stage: Stage = .awaitingGuard(.left)
    private(set) var reaches: [BodySide: Float] = [:]

    var activeSide: BodySide? { stage.activeSide }

    var completedReaches: [BodySide: Float]? {
        guard stage == .complete,
              ReachCalibration.conservativeBilateralReach(reaches) != nil
        else { return nil }
        return reaches
    }

    @discardableResult
    mutating func confirmGuard(for side: BodySide) -> Bool {
        guard case .awaitingGuard(let expected) = stage, expected == side else { return false }
        stage = .measuring(side)
        return true
    }

    @discardableResult
    mutating func acceptSettledReach(_ reach: Float, for side: BodySide) -> Bool {
        guard case .measuring(let expected) = stage,
              expected == side,
              ReachCalibration.plausibleForwardRange.contains(reach)
        else { return false }

        reaches[side] = reach
        stage = side == .left ? .awaitingGuard(.right) : .complete
        return true
    }
}
