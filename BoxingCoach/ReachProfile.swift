import Foundation
import simd

/// Reactive Strike modes from the project brief.
/// Bag Mode does not recognize a real bag yet — targets spawn in a tighter "bag zone" volume.
enum ReactiveStrikeMode: String, CaseIterable, Identifiable, Sendable {
    case air
    case bag

    var id: String { rawValue }

    var title: String {
        switch self {
        case .air: return "Air Mode"
        case .bag: return "Bag Mode"
        }
    }

    var subtitle: String {
        switch self {
        case .air: return "Targets float in front of you"
        case .bag: return "Targets appear in a punching-bag zone"
        }
    }

    var reachProfile: ReachProfile {
        switch self {
        case .air: return .air
        case .bag: return .bagZone
        }
    }
}

/// Spawn bounds for Air / Bag Mode targets.
/// Feature 1 (Anthropometry) can replace these defaults later without changing the drill loop.
struct ReachProfile: Sendable, Equatable {
    /// Forward distance from the user origin (meters). Negative Z is in front in RealityKit.
    var forwardMin: Float
    var forwardMax: Float
    /// Lateral offset (meters). Negative = left, positive = right.
    var lateralMin: Float
    var lateralMax: Float
    /// Height above the immersive origin (meters).
    var heightMin: Float
    var heightMax: Float

    static let `default` = air

    /// Wider floating volume in front of the user.
    static let air = ReachProfile(
        forwardMin: 0.45,
        forwardMax: 0.75,
        lateralMin: -0.35,
        lateralMax: 0.35,
        heightMin: 1.05,
        heightMax: 1.45
    )

    /// Tighter forward volume approximating a standing bag (no bag recognition yet).
    static let bagZone = ReachProfile(
        forwardMin: 0.55,
        forwardMax: 0.70,
        lateralMin: -0.18,
        lateralMax: 0.18,
        heightMin: 1.00,
        heightMax: 1.55
    )

    func randomTargetPosition() -> SIMD3<Float> {
        let forward = Float.random(in: forwardMin...forwardMax)
        let lateral = Float.random(in: lateralMin...lateralMax)
        let height = Float.random(in: heightMin...heightMax)
        return SIMD3(lateral, height, -forward)
    }
}
