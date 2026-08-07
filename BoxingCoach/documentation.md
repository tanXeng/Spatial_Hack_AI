## Official Apple documentation

Use Apple's official documentation as the primary source of truth for all visionOS, RealityKit, and ARKit APIs.

### Required references

* visionOS:
  https://developer.apple.com/documentation/visionos

* RealityKit:
  https://developer.apple.com/documentation/realitykit

* ARKit:
  https://developer.apple.com/documentation/arkit

* ARKit hand tracking:
  https://developer.apple.com/documentation/arkit/arkit-session/hand-tracking

### API accuracy requirement

Before implementing hand tracking or other visionOS-specific functionality:

1. Check the current Apple documentation.
2. Verify that the API is available on the visionOS deployment target used by this project.
3. Do not assume an API exists based on older tutorials, Stack Overflow answers, or knowledge from previous versions of visionOS.
4. Prefer Apple's official documentation and sample code.
5. If an API or capability is unavailable, tell me clearly and implement the closest viable MVP alternative.

In particular, verify the current APIs for:

* ARKit hand tracking
* Hand joints
* Hand joint transforms / positions
* ARKit session setup
* RealityKit entities
* Spatial positioning
* visionOS immersive/spatial experiences
* SwiftUI ↔ RealityKit integration

Do not invent APIs or method names.

If you find conflicting information online, prioritize the current Apple developer documentation.
