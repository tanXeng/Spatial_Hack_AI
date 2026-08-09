import RealityKit
import XCTest
@testable import BoxingCoach

/// Two kinds of test here.
///
/// The mapping tests are pure logic and run anywhere. The asset tests actually load the USDZ files
/// through RealityKit and assert the animations bind — the only way to catch a rig that imports
/// but silently refuses to animate, which no amount of `usdchecker` output proves.
@MainActor
final class CoachCharacterEntityTests: XCTestCase {

    // MARK: Clip mapping

    func testEveryTechniqueResolvesToAClip() throws {
        for technique in Technique.all {
            for side in [BodySide.left, .right] {
                let resolved = CoachCharacterEntity.resolveClip(technique: technique, side: side)
                XCTAssertNotNil(
                    resolved,
                    "\(technique.id) on the \(side.rawValue) has no coach clip"
                )
            }
        }
    }

    /// The coach faces the user, so his motion has to land on the same side the user is about to
    /// throw. Reflecting exactly when the clip's own side matches the request is what lets four
    /// one-sided clips cover all eight technique/side combinations.
    func testMirroringPutsTheMotionOnTheUsersSide() throws {
        // Jab is authored on the coach's left. An orthodox jab is the user's left, so it reflects.
        let leftJab = try XCTUnwrap(
            CoachCharacterEntity.resolveClip(technique: .jab, side: .left)
        )
        XCTAssertEqual(leftJab.clip, "jab_left")
        XCTAssertTrue(leftJab.reflected)

        // A southpaw jab is the user's right, which the unreflected left-arm clip already reads as.
        let rightJab = try XCTUnwrap(
            CoachCharacterEntity.resolveClip(technique: .jab, side: .right)
        )
        XCTAssertEqual(rightJab.clip, "jab_left")
        XCTAssertFalse(rightJab.reflected)

        // Cross is authored on the coach's right, so the reflection flips the other way.
        let rightCross = try XCTUnwrap(
            CoachCharacterEntity.resolveClip(technique: .cross, side: .right)
        )
        XCTAssertEqual(rightCross.clip, "cross_right")
        XCTAssertTrue(rightCross.reflected)

        let leftCross = try XCTUnwrap(
            CoachCharacterEntity.resolveClip(technique: .cross, side: .left)
        )
        XCTAssertFalse(leftCross.reflected)
    }

    func testReflectionRuleIsSymmetric() {
        for clipSide in [BodySide.left, .right] {
            for requested in [BodySide.left, .right] {
                XCTAssertEqual(
                    CoachCharacterEntity.shouldReflect(
                        clipSide: clipSide,
                        requestedSide: requested
                    ),
                    clipSide == requested
                )
            }
        }
    }

    // MARK: Asset binding

    func testBaseAssetLoadsWithASkeletonAndAnIdleAnimation() async throws {
        let coach = try await Entity(named: "coach", in: Bundle.main)

        XCTAssertFalse(
            coach.availableAnimations.isEmpty,
            "coach.usdz exposed no animations — the skeleton or SkelAnimation did not survive export"
        )
        XCTAssertNotNil(
            findSkeleton(in: coach),
            "coach.usdz has no skinned mesh; the model would render unrigged"
        )
    }

    func testEveryPunchClipAssetExposesAnAnimation() async throws {
        for file in [
            "coach_jab_left",
            "coach_cross_right",
            "coach_hook_right",
            "coach_uppercut_right"
        ] {
            let holder = try await Entity(named: file, in: Bundle.main)
            let animations = holder.availableAnimations
            XCTAssertFalse(
                animations.isEmpty,
                "\(file).usdz exposed no animation — RealityKit will have nothing to play"
            )
        }
    }

    /// The one that matters: the whole library assembled the way the session uses it.
    func testLoadedCoachExposesEveryClipItNeeds() async throws {
        let coach = CoachCharacterEntity()
        let loaded = await coach.load()
        XCTAssertTrue(loaded, "coach failed to load from the app bundle")
        XCTAssertTrue(coach.isLoaded)

        // Playback returns a duration only when the clip resolved out of the library.
        for technique in Technique.all {
            let resolved = try XCTUnwrap(
                CoachCharacterEntity.resolveClip(technique: technique, side: .left)
            )
            let duration = coach.play(clip: resolved.clip)
            XCTAssertNotNil(
                duration,
                "clip '\(resolved.clip)' for \(technique.id) is missing from the animation library"
            )
            if let duration {
                XCTAssertGreaterThan(duration, 0.2, "'\(resolved.clip)' is suspiciously short")
                XCTAssertLessThan(duration, 10, "'\(resolved.clip)' is suspiciously long")
            }
        }
    }

    private func findSkeleton(in entity: Entity) -> ModelEntity? {
        if let model = entity as? ModelEntity, model.model?.mesh != nil {
            return model
        }
        for child in entity.children {
            if let found = findSkeleton(in: child) { return found }
        }
        return nil
    }
}
