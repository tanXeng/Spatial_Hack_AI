import Foundation
import simd

/// One matched pair of frames between the reference punch and the user's attempt.
nonisolated struct AlignedPair: Sendable, Equatable {
    var reference: Int
    var attempt: Int
}

/// The result of warping the user's attempt onto the reference.
nonisolated struct DTWAlignment: Sendable {
    /// Mean per-pair distance along the warping path, in arm-reach units. Scale-free, and
    /// crucially independent of how many frames each sequence happened to contain.
    var normalizedDistance: Float
    /// The frame correspondence, used to compare other quantities (elbow, guard) at matched
    /// moments rather than at matched clock times.
    var pairs: [AlignedPair]
}

/// Dynamic Time Warping over 3D trajectories.
///
/// **Why DTW and not frame-by-frame comparison:** a beginner's jab is often slower than the
/// reference, and sometimes faster. Comparing frame *k* to frame *k* would score a
/// technically-perfect-but-slow punch as badly wrong, because every frame would be matched
/// against a reference frame from a different part of the motion. DTW stretches the time axis to
/// find the best correspondence, so what gets graded is the **shape of the path** — the form —
/// rather than the tempo. Speed, if we want to grade it, belongs in its own sub-metric where the
/// user can see it named.
nonisolated enum DTWComparator {
    /// Aligns two trajectories.
    ///
    /// - Parameter bandFraction: Sakoe-Chiba band width as a fraction of the longer sequence.
    ///   This caps how far the warp may drift from the diagonal. Without it, DTW can match a
    ///   single frozen frame of the attempt against half the reference and report a suspiciously
    ///   good distance — a user who simply held their fist still would score well.
    static func align(
        reference: [SIMD3<Float>],
        attempt: [SIMD3<Float>],
        bandFraction: Float = 0.34
    ) -> DTWAlignment? {
        let m = reference.count
        let n = attempt.count
        guard m > 1, n > 1 else { return nil }

        let band = max(2, Int(bandFraction * Float(max(m, n))))
        let infinity = Float.greatestFiniteMagnitude

        // Flat (m+1)×(n+1) DP grid, 1-indexed so row/column 0 can hold the boundary condition.
        var cost = [Float](repeating: infinity, count: (m + 1) * (n + 1))
        func index(_ i: Int, _ j: Int) -> Int { i * (n + 1) + j }
        cost[index(0, 0)] = 0

        // Ratio mapping reference index onto attempt index, so the band follows the diagonal
        // even when the two sequences have very different lengths.
        let slope = Float(n) / Float(m)

        for i in 1...m {
            let center = Int((Float(i) * slope).rounded())
            let lower = max(1, center - band)
            let upper = min(n, center + band)
            guard lower <= upper else { continue }

            for j in lower...upper {
                let d = simd_distance(reference[i - 1], attempt[j - 1])
                let best = min(
                    cost[index(i - 1, j)],      // reference advances, attempt repeats
                    cost[index(i, j - 1)],      // attempt advances, reference repeats
                    cost[index(i - 1, j - 1)]   // both advance
                )
                if best < infinity {
                    cost[index(i, j)] = d + best
                }
            }
        }

        let total = cost[index(m, n)]
        guard total < infinity else { return nil }

        // Backtrack to recover the correspondence.
        var pairs: [AlignedPair] = []
        var i = m
        var j = n
        while i > 0, j > 0 {
            pairs.append(AlignedPair(reference: i - 1, attempt: j - 1))
            let diagonal = cost[index(i - 1, j - 1)]
            let up = cost[index(i - 1, j)]
            let left = cost[index(i, j - 1)]

            if diagonal <= up, diagonal <= left {
                i -= 1
                j -= 1
            } else if up <= left {
                i -= 1
            } else {
                j -= 1
            }
        }
        pairs.reverse()

        guard !pairs.isEmpty else { return nil }

        return DTWAlignment(
            normalizedDistance: total / Float(pairs.count),
            pairs: pairs
        )
    }

    /// Mean distance between two other sequences, evaluated at an existing alignment.
    ///
    /// Reuses the warping path computed from the fist trajectory. That is deliberate: the elbow
    /// and the fist belong to the same arm at the same instant, so re-warping the elbow
    /// independently would align it to a *different* moment of the punch and measure something
    /// physically meaningless.
    static func meanDistance(
        reference: [SIMD3<Float>],
        attempt: [SIMD3<Float>],
        along alignment: DTWAlignment
    ) -> Float? {
        var total: Float = 0
        var count = 0

        for pair in alignment.pairs {
            guard pair.reference < reference.count, pair.attempt < attempt.count else { continue }
            total += simd_distance(reference[pair.reference], attempt[pair.attempt])
            count += 1
        }

        guard count > 0 else { return nil }
        return total / Float(count)
    }
}
