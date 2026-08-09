import Foundation
import simd

/// A completed attempt, cleaned up and ready to score.
struct RecordedAttempt: Sendable {
    /// Normalized samples covering just the punch itself (idle time at either end trimmed).
    var samples: [MotionSample]
    /// Fraction of frames in the **trimmed punch** that came from real tracking rather than
    /// interpolation across a dropout. Idle guard time in the capture window is excluded.
    var trackedFraction: Float
    /// Wall-clock length of the trimmed punch.
    var duration: TimeInterval

    /// Whether this attempt is worth scoring at all.
    ///
    /// Scoring a punch that was half-guessed produces a confident-looking number built on
    /// interpolation, which is worse than admitting the capture failed — the user would be
    /// coached on motion they never made.
    var isUsable: Bool {
        samples.count >= 8 && trackedFraction >= 0.6 && duration > 0.08
    }

    var peakReach: Float {
        samples.map(\.reachFraction).max() ?? 0
    }

    /// Technique-aware magnitude used by the Extension score and to decide which arm threw.
    /// Uppercuts are defined by the ordered rise from their low load to their later landing; their
    /// hip load can be radially farther from the shoulder than the fist is at the chin. Every
    /// other punch keeps the established shoulder-to-fist peak-reach measure.
    func extensionMagnitude(for techniqueID: String) -> Float {
        PunchExtensionSemantics.magnitude(samples: samples, techniqueID: techniqueID)
    }
}

/// Pure punch-extension rules shared by recorded attempts and authored references.
enum PunchExtensionSemantics {
    static func magnitude(samples: [MotionSample], techniqueID: String) -> Float {
        if techniqueID == Technique.uppercut.id {
            return orderedVerticalRise(in: samples)
        }

        return samples.lazy
            .map(\.reachFraction)
            .filter(\.isFinite)
            .max() ?? 0
    }

    /// Largest upward displacement whose low sample occurs before its high sample.
    ///
    /// Order matters: `maxY - minY` would credit a hand that starts high and only drops to the hip,
    /// even though it never performs the upward half of an uppercut.
    static func orderedVerticalRise(in samples: [MotionSample]) -> Float {
        var lowestEarlierY: Float?
        var largestRise: Float = 0

        for sample in samples {
            let y = sample.fist.y
            guard y.isFinite else { continue }

            if let priorLowestY = lowestEarlierY {
                largestRise = max(largestRise, y - priorLowestY)
                lowestEarlierY = min(priorLowestY, y)
            } else {
                lowestEarlierY = y
            }
        }

        return largestRise
    }
}

/// Captures the user's attempt as a normalized time series.
///
/// **Dropouts are a first-class case, not an edge case.** Hands routinely leave the Vision Pro's
/// downward-facing cameras mid-punch — a fully extended jab can put the fist at the very edge of
/// the tracking volume, which is exactly the instant the score cares most about. So the recorder
/// records the *absence* of data explicitly rather than silently skipping frames, which would
/// otherwise compress a gap into a false straight line and quietly inflate the path score.
@MainActor
final class MotionRecorder {
    private(set) var isRecording = false

    /// `nil` entries are frames where tracking was lost.
    private var raw: [(time: TimeInterval, sample: MotionSample?)] = []
    private var startTime: TimeInterval = 0

    /// Live reach fraction, used by the UI to show the punch developing.
    private(set) var latestReach: Float = 0

    var sampleCount: Int { raw.count }

    func begin(at time: TimeInterval) {
        raw.removeAll(keepingCapacity: true)
        startTime = time
        isRecording = true
        latestReach = 0
    }

    func record(_ sample: MotionSample) {
        guard isRecording else { return }
        raw.append((time: sample.time, sample: sample))
        latestReach = sample.reachFraction
    }

    /// Records that tracking was unavailable at this instant.
    func recordDropout(at time: TimeInterval) {
        guard isRecording else { return }
        raw.append((time: time - startTime, sample: nil))
    }

    func cancel() {
        isRecording = false
        raw.removeAll(keepingCapacity: true)
        latestReach = 0
    }

    /// Ends capture and returns a cleaned, trimmed attempt.
    func finish() -> RecordedAttempt {
        isRecording = false

        let filled = fillDropouts()
        let trimmed = trimToPunch(filled)

        let duration = (trimmed.last?.time ?? 0) - (trimmed.first?.time ?? 0)

        // Measured on the trimmed punch only — not the full capture window. The attempt window
        // includes seconds of cheek-height guard while the user waits to throw, and that pose
        // often sits in the Vision Pro's side/bottom camera blind spot. Counting those idle frames
        // against the 60 % threshold rejected technically fine punches with a tracking error.
        // Guard discipline during the punch is scored separately via the guard-hand sub-metric.
        let trackedFraction: Float
        if trimmed.isEmpty {
            trackedFraction = 0
        } else {
            let trackedCount = trimmed.filter(\.isTracked).count
            trackedFraction = Float(trackedCount) / Float(trimmed.count)
        }

        // Rebase to zero so DTW compares two sequences that both start at t=0.
        let offset = trimmed.first?.time ?? 0
        let rebased = trimmed.map { sample -> MotionSample in
            var copy = sample
            copy.time -= offset
            return copy
        }

        return RecordedAttempt(
            samples: rebased,
            trackedFraction: trackedFraction,
            duration: duration
        )
    }

    // MARK: - Cleanup

    /// Linearly interpolates across tracking gaps, flagging every filled frame as untracked.
    ///
    /// Leading and trailing gaps are dropped rather than filled — there is nothing on one side
    /// to interpolate from, and extrapolating a punch is how you invent motion that never
    /// happened.
    private func fillDropouts() -> [MotionSample] {
        guard !raw.isEmpty else { return [] }

        let knownIndices = raw.indices.filter { raw[$0].sample != nil }
        guard let first = knownIndices.first, let last = knownIndices.last else { return [] }

        var result: [MotionSample] = []
        var previousKnown = first

        for index in first...last {
            if let sample = raw[index].sample {
                result.append(sample)
                previousKnown = index
                continue
            }

            // Find the next tracked frame to interpolate toward.
            guard let nextKnown = knownIndices.first(where: { $0 > index }),
                  let before = raw[previousKnown].sample,
                  let after = raw[nextKnown].sample
            else { continue }

            let span = after.time - before.time
            let t = span > 0 ? Float((raw[index].time - before.time) / span) : 0

            result.append(
                MotionSample(
                    time: raw[index].time,
                    fist: simd_mix(before.fist, after.fist, SIMD3(repeating: t)),
                    elbow: simd_mix(before.elbow, after.elbow, SIMD3(repeating: t)),
                    guardHand: before.guardHand.flatMap { a in
                        after.guardHand.map { b in simd_mix(a, b, SIMD3(repeating: t)) }
                    },
                    isTracked: false
                )
            )
        }

        return result
    }

    /// Trims idle time so DTW aligns punch-to-punch rather than pause-to-punch.
    ///
    /// Without this the user's "sequence" would include however many seconds they spent standing
    /// still before deciding to throw, and DTW — which is free to stretch time — would happily
    /// smear the reference's guard pose across all of it and report a decent match.
    private func trimToPunch(_ samples: [MotionSample]) -> [MotionSample] {
        guard samples.count > 4 else { return samples }

        let reaches = samples.map(\.reachFraction)
        guard let peak = reaches.max(),
              let peakIndex = reaches.firstIndex(of: peak)
        else { return samples }

        // Baseline is the resting guard extension. Anything meaningfully above it is the punch.
        let baseline = reaches.min() ?? 0
        guard peak - baseline > 0.08 else { return samples }
        let threshold = baseline + (peak - baseline) * 0.15

        var start = peakIndex
        while start > 0, reaches[start - 1] > threshold { start -= 1 }

        var end = peakIndex
        while end < samples.count - 1, reaches[end + 1] > threshold { end += 1 }

        // Keep a few frames of context on each side so retraction has something to measure.
        let padding = 3
        let lower = max(0, start - padding)
        let upper = min(samples.count - 1, end + padding)

        return Array(samples[lower...upper])
    }
}
