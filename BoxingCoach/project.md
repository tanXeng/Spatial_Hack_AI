# Apple Vision Pro Boxing Trainer — Project Brief

## 1. Problem

Beginner boxers often struggle to know **where, when, and how** to punch correctly. Traditional training relies heavily on coaches or repeated drills, which can be difficult to personalize.

We want to use **spatial computing** to turn boxing practice into an interactive training experience that provides immediate visual guidance and measurable performance.

## 2. Target User

**Beginner boxers** who want an accessible way to practice fundamental boxing movements and improve their reaction time, speed, and accuracy.

## 3. Core User Flow

1. User puts on Apple Vision Pro.
2. User completes a basic body/reach calibration.
3. The system personalizes training based on the user's physical dimensions.
4. A virtual boxing coach demonstrates movements.
5. The user follows the visual guidance.
6. The user enters a reactive punching drill.
7. Virtual targets appear around the user's punching range.
8. The user punches the targets as quickly and accurately as possible.
9. The system provides performance metrics.

## 4. MVP Features

### Feature 1 — Anthropometry

Baseline calibration of:

* Height
* Arm span/reach
* Guard position

Used to personalize target placement and punching distance.

### Feature 2 — Aura Punch

A spatial visual guide around the user's fist that demonstrates the desired punch direction and trajectory. The user mimics the demonstrated movement.

### Feature 3 — Reactive Strike

The user reacts to virtual targets appearing in space.

Two planned modes:

* **Air Mode:** targets float in front of the user.
* **Bag Mode:** virtual targets appear on/around a real punching bag.

Measure:

* Reaction time
* Estimated punch speed
* Accuracy

**Current development priority: Feature 3 only.** Features 1 and 2 are planned but have not been implemented yet.

## 5. Tech Stack

* Swift
* SwiftUI
* visionOS
* RealityKit
* ARKit
* Xcode
* Apple Vision Pro

Use Apple's official documentation as the source of truth for visionOS, RealityKit, and ARKit APIs.

## 6. Important Constraints

* This is a hackathon MVP, not a production application.
* Prioritize getting the experience working on a **physical Apple Vision Pro**.
* Do not implement AI yet.
* Do not attempt to measure punch force.
* Do not implement automatic punching-bag recognition yet.
* Do not add unnecessary third-party dependencies.
* Features 1 and 2 should not be implemented as part of the current task.
* Use simple 3D primitives rather than spending time creating complex 3D assets.
* Prefer a simple, testable implementation over sophisticated architecture.

## 7. Acceptance Criteria

The Reactive Strike MVP is successful when:

1. The app runs on a physical Apple Vision Pro.
2. A virtual 3D target appears in the user's space.
3. The user's hand can be tracked.
4. The system detects when the user's hand reaches the target.
5. The system records reaction time.
6. Multiple targets can be presented sequentially.
7. The user can see basic results such as reaction time and accuracy.
8. The implementation is structured so anthropometry data can be integrated later.
