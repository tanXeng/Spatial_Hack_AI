import Foundation
import simd

enum PunchType: String, Sendable, CaseIterable {
    case jab
    case cross
    case leadHook
    case rearHook
    case leadUppercut
    case rearUppercut

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

    func targetPosition(forwardBase: Float, stance: Stance = .orthodox) -> SIMD3<Float> {
        let forward = forwardBase
        let sign = stance == .orthodox ? Float(1) : Float(-1)
        switch self {
        case .jab:
            return SIMD3(0, 1.25, -forward)
        case .cross:
            return SIMD3(0, 1.25, -(forward * 1.05))
        case .leadHook:
            return SIMD3(-sign * 0.25, 1.30, -(forward * 0.90))
        case .rearHook:
            return SIMD3(sign * 0.25, 1.30, -(forward * 0.90))
        case .leadUppercut:
            return SIMD3(-sign * 0.08, 1.05, -(forward * 0.88))
        case .rearUppercut:
            return SIMD3(sign * 0.08, 1.05, -(forward * 0.88))
        }
    }
}

struct Combination: Identifiable, Sendable {
    let id: String
    let name: String
    let punches: [PunchType]
    let summary: String

    var numberNotation: String {
        punches.map { "\($0.number)" }.joined(separator: "-")
    }

    var punchCount: Int { punches.count }

    static let oneTwo = Combination(
        id: "1-2",
        name: "Jab-Cross",
        punches: [.jab, .cross],
        summary: "The fundamental two-punch combo"
    )

    static let doubleJabCross = Combination(
        id: "1-1-2",
        name: "Double Jab-Cross",
        punches: [.jab, .jab, .cross],
        summary: "Double jab sets up the power shot"
    )

    static let jabCrossHook = Combination(
        id: "1-2-3",
        name: "Jab-Cross-Hook",
        punches: [.jab, .cross, .leadHook],
        summary: "Classic three-punch finishing with a hook"
    )

    static let jabCrossHookCross = Combination(
        id: "1-2-3-2",
        name: "Jab-Cross-Hook-Cross",
        punches: [.jab, .cross, .leadHook, .cross],
        summary: "The bread-and-butter four-punch combo"
    )

    static let jabCrossUppercutCross = Combination(
        id: "1-2-5-2",
        name: "Jab-Cross-Uppercut-Cross",
        punches: [.jab, .cross, .leadUppercut, .cross],
        summary: "Four-punch with a body shot mixed in"
    )

    static let all: [Combination] = [
        .oneTwo,
        .doubleJabCross,
        .jabCrossHook,
        .jabCrossHookCross,
        .jabCrossUppercutCross
    ]

    func targetPositions(forwardBase: Float, stance: Stance = .orthodox) -> [SIMD3<Float>] {
        punches.map { $0.targetPosition(forwardBase: forwardBase, stance: stance) }
    }
}