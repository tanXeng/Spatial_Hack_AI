import Foundation
import simd

/// The six punches used by conventional boxing number notation.
///
/// A punch is expressed relative to stance. Call `requiredHand(for:)` before validating a hit;
/// target proximity alone cannot establish that the correct punch was thrown.
nonisolated enum PunchType: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case jab
    case cross
    case leadHook
    case rearHook
    case leadUppercut
    case rearUppercut

    var id: String { rawValue }

    /// Stable conventional boxing number (1 through 6).
    var number: Int {
        switch self {
        case .jab: return 1
        case .cross: return 2
        case .leadHook: return 3
        case .rearHook: return 4
        case .leadUppercut: return 5
        case .rearUppercut: return 6
        }
    }

    var displayName: String {
        switch self {
        case .jab: return "Jab"
        case .cross: return "Cross"
        case .leadHook: return "Lead Hook"
        case .rearHook: return "Rear Hook"
        case .leadUppercut: return "Lead Uppercut"
        case .rearUppercut: return "Rear Uppercut"
        }
    }

    /// The physical hand that must throw this punch in the supplied stance.
    func requiredHand(for stance: Stance) -> BodySide {
        switch self {
        case .jab, .leadHook, .leadUppercut:
            return stance.leadSide
        case .cross, .rearHook, .rearUppercut:
            return stance.rearSide
        }
    }

    /// A deterministic shoulder-relative body-space target position for the punch.
    ///
    /// `forwardBase` is a positive reach distance in meters. In this model +X is the user's
    /// right, +Y is above the shoulder line, and +Z is forward. The scene layer is responsible
    /// for transforming this body-space value into RealityKit world space.
    func targetPosition(forwardBase: Float, stance: Stance) -> SIMD3<Float> {
        precondition(
            forwardBase.isFinite && forwardBase > 0,
            "forwardBase must be a positive finite distance"
        )

        switch self {
        case .jab:
            return SIMD3(0, 0.12, forwardBase)
        case .cross:
            return SIMD3(0, 0.12, forwardBase * 1.05)
        case .leadHook:
            // Finish through the centreline instead of pulling farther toward the throwing side.
            return SIMD3(-stance.leadSide.lateralSign * 0.04, 0.12, forwardBase * 0.88)
        case .rearHook:
            return SIMD3(-stance.rearSide.lateralSign * 0.04, 0.12, forwardBase * 0.88)
        case .leadUppercut:
            // An uppercut lands up the centreline near the chin; a below-shoulder endpoint would
            // turn the validator's required outbound path into a downward punch.
            return SIMD3(0, 0.22, forwardBase * 0.82)
        case .rearUppercut:
            return SIMD3(0, 0.22, forwardBase * 0.82)
        }
    }
}

/// One placed step of a combination, ready for an engine to present and validate.
nonisolated struct CombinationTarget: Identifiable, Sendable, Equatable {
    /// Stable within a combination as long as its ordered definition is unchanged.
    let id: String
    /// Zero-based position in the combination.
    let index: Int
    let punch: PunchType
    let requiredHand: BodySide
    let position: SIMD3<Float>
}

/// A stable, data-only definition of a boxing combination.
nonisolated struct Combination: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let name: String
    let punches: [PunchType]
    let summary: String

    var numberNotation: String {
        punches.map { String($0.number) }.joined(separator: "-")
    }

    var punchCount: Int { punches.count }

    /// Resolves both the physical hand and target position for every ordered punch.
    ///
    /// The resulting data says what the user should hit. The drill engine must still require an
    /// actual outbound punch and a return/retraction before arming the next target; otherwise a
    /// stationary extended fist could satisfy consecutive targets at the same position.
    func targets(forwardBase: Float, stance: Stance) -> [CombinationTarget] {
        punches.enumerated().map { index, punch in
            CombinationTarget(
                id: "\(id)-step-\(index)",
                index: index,
                punch: punch,
                requiredHand: punch.requiredHand(for: stance),
                position: punch.targetPosition(forwardBase: forwardBase, stance: stance)
            )
        }
    }

    func targetPositions(forwardBase: Float, stance: Stance) -> [SIMD3<Float>] {
        punches.map { $0.targetPosition(forwardBase: forwardBase, stance: stance) }
    }

    func requiredHands(for stance: Stance) -> [BodySide] {
        punches.map { $0.requiredHand(for: stance) }
    }

    static let oneTwo = Combination(
        id: "1-2",
        name: "Jab-Cross",
        punches: [.jab, .cross],
        summary: "The fundamental two-punch combination"
    )

    static let doubleJabCross = Combination(
        id: "1-1-2",
        name: "Double Jab-Cross",
        punches: [.jab, .jab, .cross],
        summary: "A double jab that sets up the rear-hand power shot"
    )

    static let jabCrossHook = Combination(
        id: "1-2-3",
        name: "Jab-Cross-Hook",
        punches: [.jab, .cross, .leadHook],
        summary: "The classic three-punch combination finishing with a lead hook"
    )

    static let jabCrossHookCross = Combination(
        id: "1-2-3-2",
        name: "Jab-Cross-Hook-Cross",
        punches: [.jab, .cross, .leadHook, .cross],
        summary: "A four-punch combination that finishes with the rear hand"
    )

    static let jabCrossUppercutCross = Combination(
        id: "1-2-5-2",
        name: "Jab-Cross-Uppercut-Cross",
        punches: [.jab, .cross, .leadUppercut, .cross],
        summary: "A four-punch combination with a lead uppercut on the centerline"
    )

    static let all: [Combination] = [
        .oneTwo,
        .doubleJabCross,
        .jabCrossHook,
        .jabCrossHookCross,
        .jabCrossUppercutCross
    ]

    static func combination(id: String) -> Combination? {
        all.first { $0.id == id }
    }
}

/// Adjusts authored combination targets against a freshly captured guard without changing their
/// lateral or vertical punch layout. This is pure so reach-edge cases can be regression tested
/// without ARKit or a running session.
nonisolated enum CombinationTargetResolver {
    static func resolve(
        _ authored: [CombinationTarget],
        guardPositions: [BodySide: SIMD3<Float>],
        minimumSeparation: Float,
        maximumForward: Float
    ) -> [CombinationTarget]? {
        guard minimumSeparation.isFinite,
              maximumForward.isFinite,
              minimumSeparation > 0,
              maximumForward > 0
        else { return nil }

        var resolved: [CombinationTarget] = []
        resolved.reserveCapacity(authored.count)

        for target in authored {
            guard let guardPosition = guardPositions[target.requiredHand],
                  guardPosition.x.isFinite,
                  guardPosition.y.isFinite,
                  guardPosition.z.isFinite
            else { return nil }

            var position = target.position
            let lateral = position.x - guardPosition.x
            let vertical = position.y - guardPosition.y
            let lateralVerticalSquared = lateral * lateral + vertical * vertical
            let requiredForwardSquared = max(
                0,
                minimumSeparation * minimumSeparation - lateralVerticalSquared
            )
            position.z = max(
                position.z,
                guardPosition.z + requiredForwardSquared.squareRoot()
            )

            guard position.z.isFinite, position.z <= maximumForward else { return nil }
            resolved.append(
                CombinationTarget(
                    id: target.id,
                    index: target.index,
                    punch: target.punch,
                    requiredHand: target.requiredHand,
                    position: position
                )
            )
        }

        return resolved
    }
}
