import Foundation

/// Which hand throws a given punch, expressed relative to stance rather than to a fixed side
/// so the same technique data works for orthodox and southpaw users.
enum PunchHand: String, Sendable, Codable {
    case lead
    case rear
    /// Thrown correctly from either side — hooks and uppercuts are drilled off both hands, and
    /// the guided follow-along alternates arms rep to rep rather than showing one fixed side.
    case either

    /// The side the ghost arm demonstrates on.
    ///
    /// `either` still has to pick one arm to draw, so this returns the lead side as the default;
    /// the user is free to answer with the other one and `allows` will accept it. The guided
    /// loop overrides this per rep — see `AuraPunchSession.demoSide(forRep:technique:stance:)`.
    func side(for stance: Stance) -> BodySide {
        switch self {
        case .lead, .either: return stance.leadSide
        case .rear: return stance.rearSide
        }
    }

    /// Whether a punch thrown with `side` counts as the right hand for this technique.
    func allows(_ side: BodySide, stance: Stance) -> Bool {
        self == .either || side == self.side(for: stance)
    }

    /// How the requirement reads in coaching copy, e.g. "left hand".
    func requirementDescription(for stance: Stance) -> String {
        self == .either ? "either hand" : "\(side(for: stance).rawValue) hand"
    }
}

/// A punch the user can train.
///
/// Techniques are **data, not screens**. Adding a punch means appending to
/// `all` and adding a matching entry in `ReferencePunchLibrary` — no view code changes.
nonisolated struct Technique: Identifiable, Sendable, Hashable, Codable {
    let id: String
    let name: String
    let summary: String
    let hand: PunchHand

    /// Whether a reference trajectory exists for this punch. Unimplemented techniques render
    /// as disabled rather than being hidden, so the roadmap stays visible in the UI.
    let isImplemented: Bool

    /// Short cues shown before the attempt and used to ground the LLM's coaching language.
    let coachingCues: [String]

    static let jab = Technique(
        id: "jab",
        name: "Jab",
        summary: "Straight lead-hand punch. Fast, straight out and straight back.",
        hand: .lead,
        isImplemented: true,
        coachingCues: [
            "Punch straight from your guard — no winding up",
            "Keep the elbow tucked until the arm extends",
            "Rear hand stays glued to your chin",
            "Snap it back the same way it went out"
        ]
    )

    static let cross = Technique(
        id: "cross",
        name: "Cross",
        summary: "Straight rear-hand power punch. Rotates through the shoulder.",
        hand: .rear,
        isImplemented: true,
        coachingCues: [
            "Drive from the rear shoulder, not just the arm",
            "Travel in a straight line to the target",
            "Lead hand stays up as you extend",
            "Return to guard before you reset"
        ]
    )

    static let hook = Technique(
        id: "hook",
        name: "Hook",
        summary: "Horizontal arcing punch with the elbow raised. Thrown off either hand.",
        hand: .either,
        isImplemented: true,
        coachingCues: [
            "Elbow comes up to roughly shoulder height",
            "Keep the forearm level through the arc",
            "The turn comes from the body, not the shoulder alone",
            "Do not wind the hand back before throwing"
        ]
    )

    static let uppercut = Technique(
        id: "uppercut",
        name: "Uppercut",
        summary: "Short punch that loads low at the hip and drives up to the centreline. Alternates hands.",
        hand: .either,
        isImplemented: true,
        coachingCues: [
            "Load low at your hip, then drive up toward the centre",
            "Keep the elbow under the fist and close to your ribs",
            "Travel in a straight line from hip to chin — no looping out",
            "Spare hand stays at your chin",
            "Snap it back to guard"
        ]
    )

    static let all: [Technique] = [.jab, .cross, .hook, .uppercut]

    static func technique(id: String) -> Technique? {
        all.first { $0.id == id }
    }
}
