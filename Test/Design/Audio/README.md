# Spatial feedback audio

`Tools/generate_feedback_audio.swift` reproducibly creates the five mono PCM
WAV files bundled under `Test/Resources/Audio`. They are original synthesized
tones with no speech, samples, or third-party source material.

RealityKit plays them from scene entities as optional spatial cues. Captions
and VoiceOver announcements remain the accessibility fallback. Active scoring
and cues stop when a drill pauses, and one non-scoring pause earcon may play;
all playback stops and detaches on system interruption or immersive-space exit.

Apple Vision Pro has no native haptic actuator supported by Core Haptics. The
app therefore makes no headset-haptics claim. A future companion or spatial
accessory may consume the same feedback events only after device-specific
implementation and testing.
