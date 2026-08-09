---
name: coach-assets
description: Regenerate the Aura Punch coach character's USDZ assets from the Tripo FBX sources in Art/. Use when the coach model or its punch animations change, when adding a new punch clip, or when the coach fails to load or animate.
---

# Regenerating the coach assets

Sources live in `Art/` as Tripo FBX exports: one file per animation, with the skinned mesh embedded
**only** in `Left_hand_jab.fbx`. All five share an identical 65-bone Mixamo skeleton rooted at a
single `mixamorig10:Hips`, which is why the actions are interchangeable.

`Art/*.fbx` and `Art/usdz/` are **gitignored** (~79 MB) — only `Art/build_coach.py` and the final
`BoxingCoach/Resources/Coach/*.usdz` are tracked. If the FBX sources are missing they must be
re-exported from Tripo; they exist nowhere else.

## Run the conversion

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
  --python Art/build_coach.py
```

Output lands in `Art/usdz/`. Copy to `BoxingCoach/Resources/Coach/` to install:

```sh
cp Art/usdz/*.usdz BoxingCoach/Resources/Coach/
```

## Three things the script works around

Each of these cost a debugging cycle — do not "simplify" them away.

- **Every clip file must carry the skinned mesh.** RealityKit only surfaces `availableAnimations`
  for a skeleton that actually drives geometry. A skeleton-plus-`SkelAnimation` file loads with no
  error and exposes *nothing*. Materials are dropped from the clip files instead, so they cost
  ~3 MB each rather than 17 MB — they exist only to hand their animation to the base model and are
  never rendered.
- **Blender emits `SkelBindingAPI` under a plain `Xform`**, which `usdchecker` rejects and which can
  make skeletal animation silently not bind. Only files that contain a mesh get a proper `SkelRoot`.
- **Textures are capped at 2048** via `usdz_downscale_size`. Tripo shipped seven 4096×4096 maps;
  uncompressed that is roughly half a gigabyte of VRAM.

## Verify

```sh
usdchecker BoxingCoach/Resources/Coach/coach.usdz
```

Expect `Success!` on all five files. Filter the `RegisterBehaviorForPrimTypeId` lines — that is
plugin chatter, not an asset problem.

Then run `CoachCharacterEntityTests`, which loads every asset through RealityKit in the simulator
and asserts the clips bind. **That test is the only thing that catches a rig which imports cleanly
and refuses to animate** — `usdchecker` passing proves nothing about playback.

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project BoxingCoach.xcodeproj -scheme BoxingCoach -configuration Debug \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=27.0' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

## Adding a new punch clip

1. Export the animation from Tripo as FBX into `Art/`.
2. Add a `(filename, clip_name)` pair to `CLIPS` in `Art/build_coach.py`.
3. Add the clip to `CoachCharacterEntity.punchClips`, keyed by `Technique.id`, with the coach's
   authored side — the mirroring rule in `CLAUDE.md` derives the rest.
4. Re-run the conversion, install, and re-run the tests.
