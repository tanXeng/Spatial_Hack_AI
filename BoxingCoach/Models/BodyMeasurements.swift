import Foundation
import simd

/// Which side leads. Orthodox = left hand forward, Southpaw = right hand forward.
nonisolated enum Stance: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case orthodox
    case southpaw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .orthodox: return "Orthodox"
        case .southpaw: return "Southpaw"
        }
    }

    var footDescription: String {
        switch self {
        case .orthodox: return "Left foot forward, right foot back"
        case .southpaw: return "Right foot forward, left foot back"
        }
    }

    /// The forward (weak) hand — throws the jab and lead hook.
    var leadSide: BodySide {
        self == .orthodox ? .left : .right
    }

    /// The rear (power) hand — throws the cross.
    var rearSide: BodySide {
        self == .orthodox ? .right : .left
    }
}

nonisolated enum BodySide: String, Hashable, Sendable, Codable {
    case left
    case right

    var opposite: BodySide { self == .left ? .right : .left }

    /// Sign along the body-space X axis (+X is the user's right).
    var lateralSign: Float { self == .left ? -1 : 1 }
}

/// Anthropometric measurements used to place the shoulder and scale the arm silhouette.
///
/// **This is the seam for the Anthropometry feature.** Nothing here is measured yet — every
/// value comes from `averageAdult` or is derived from a stated height. When Anthropometry is
/// built it should produce one of these and nothing downstream needs to change.
///
/// All lengths are in meters.
struct BodyMeasurements: Sendable, Equatable, Codable {
    /// Standing height. Used to scale every other measurement when only height is known.
    var height: Float

    /// Biacromial width — distance between the two shoulder joints.
    var shoulderWidth: Float

    /// Shoulder joint to elbow joint.
    var upperArmLength: Float

    /// Elbow joint to wrist joint.
    var forearmLength: Float

    /// Wrist to the center of a closed fist. The fist, not the wrist, is what "lands" a punch,
    /// so scoring extension against the wrist alone under-reports reach by roughly this much.
    var wristToFistLength: Float

    /// Vertical drop from the device (roughly eye level) down to the shoulder line.
    ///
    /// The visionOS device transform sits at the user's eyes, but the arm chain hangs from the
    /// shoulders. Without this offset the whole silhouette floats around the user's face.
    var eyeToShoulderDrop: Float

    /// How far *behind* the eyes the shoulder line sits, along body-forward.
    ///
    /// Eyes are on the front of the head; the shoulder joints are meaningfully further back.
    /// Skipping this pushes the ghost arms forward into the user's field of view.
    var eyeToShoulderSetback: Float

    /// Total reach from shoulder to fist. The normalization scale for all motion comparison —
    /// dividing by this is what makes a tall user's jab and a short user's jab comparable.
    var armReach: Float {
        upperArmLength + forearmLength + wristToFistLength
    }

    /// Shoulder-to-wrist only, which is what the two-bone IK solves over.
    var ikChainLength: Float {
        upperArmLength + forearmLength
    }

    /// Proportions of a ~1.75 m adult, used both as the standalone default and as the ratios
    /// that `init(height:)` scales. Sources are standard anthropometric tables rounded to the
    /// centimeter — good enough to place a ghost limb, not good enough for a tailor.
    static let averageAdult = BodyMeasurements(
        height: 1.75,
        shoulderWidth: 0.40,
        upperArmLength: 0.32,
        forearmLength: 0.26,
        wristToFistLength: 0.08,
        eyeToShoulderDrop: 0.20,
        eyeToShoulderSetback: 0.10
    )

    /// Scales the average adult's proportions to a given height.
    ///
    /// Crude isometric scaling — real bodies do not scale uniformly, and this will be wrong for
    /// users with unusual limb-to-torso ratios. That is precisely the error Anthropometry is
    /// meant to remove later.
    init(height: Float) {
        let reference = BodyMeasurements.averageAdult
        let k = height / reference.height
        self.height = height
        self.shoulderWidth = reference.shoulderWidth * k
        self.upperArmLength = reference.upperArmLength * k
        self.forearmLength = reference.forearmLength * k
        self.wristToFistLength = reference.wristToFistLength * k
        self.eyeToShoulderDrop = reference.eyeToShoulderDrop * k
        self.eyeToShoulderSetback = reference.eyeToShoulderSetback * k
    }

    init(
        height: Float,
        shoulderWidth: Float,
        upperArmLength: Float,
        forearmLength: Float,
        wristToFistLength: Float,
        eyeToShoulderDrop: Float,
        eyeToShoulderSetback: Float
    ) {
        self.height = height
        self.shoulderWidth = shoulderWidth
        self.upperArmLength = upperArmLength
        self.forearmLength = forearmLength
        self.wristToFistLength = wristToFistLength
        self.eyeToShoulderDrop = eyeToShoulderDrop
        self.eyeToShoulderSetback = eyeToShoulderSetback
    }
}
