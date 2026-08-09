import AVFoundation
import Testing
@testable import BoxingCoach

@Suite("Sonic ring resource inventory")
struct AudioResourceInventoryTests {
    @Test("Every authored sonic-ring sound resolves as safe, audible PCM")
    func sonicRingResourcesResolveWithSafeAudibleFormat() throws {
        for asset in SonicRingAsset.required {
            let url = try #require(
                CoachClipLibrary.url(for: asset.name),
                "Missing runtime resource: \(asset.name)"
            )
            let file = try AVAudioFile(forReading: url)
            let duration = Double(file.length) / file.processingFormat.sampleRate

            #expect(url.pathExtension.lowercased() == "wav")
            #expect(file.fileFormat.commonFormat == .pcmFormatInt16)
            #expect(file.processingFormat.channelCount == 1)
            #expect(file.processingFormat.sampleRate == 22_050)
            #expect(asset.duration.contains(duration), "\(asset.name) duration was \(duration)s")

            let levels = try decodedLevels(for: file)
            #expect(levels.peak > 0.02, "\(asset.name) decoded as silence")
            #expect(levels.rms > 0.003, "\(asset.name) decoded as effectively silent")
            #expect(levels.peak <= 0.9, "\(asset.name) peak exceeds safety ceiling")
            #expect(levels.rms <= 0.4, "\(asset.name) RMS exceeds safety ceiling")
        }
    }

    @Test("Looping beds meet at their boundaries without a discontinuity")
    func loopingBedsHaveContinuousBoundaries() throws {
        for asset in SonicRingAsset.loopingBeds {
            let url = try #require(CoachClipLibrary.url(for: asset.name))
            let samples = try decodedSamples(from: AVAudioFile(forReading: url))
            let boundary = try #require(loopBoundaryError(samples))

            #expect(boundary.sampleStep < 0.08, "\(asset.name) loop endpoint clicks")
            #expect(boundary.slopeStep < 0.08, "\(asset.name) loop endpoint changes slope")
        }
    }

    private func decodedLevels(for file: AVAudioFile) throws -> (peak: Float, rms: Float) {
        let samples = try decodedSamples(from: file)
        let peak = samples.map { abs($0) }.max() ?? 0
        let meanSquare = samples.reduce(Float.zero) { $0 + ($1 * $1) } / Float(samples.count)
        return (peak, sqrt(meanSquare))
    }

    private func decodedSamples(from file: AVAudioFile) throws -> [Float] {
        let frameCount = try #require(AVAudioFrameCount(exactly: file.length))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
    }

    private func loopBoundaryError(_ samples: [Float]) -> (sampleStep: Float, slopeStep: Float)? {
        guard samples.count > 1 else { return nil }
        let sampleStep = abs(samples[0] - samples[samples.count - 1])
        let firstSlope = samples[1] - samples[0]
        let lastSlope = samples[samples.count - 1] - samples[samples.count - 2]
        return (sampleStep, abs(firstSlope - lastSlope))
    }
}

private struct SonicRingAsset: Sendable {
    let name: String
    let duration: ClosedRange<Double>
    let loops: Bool

    static let required: [Self] = [
        .init(name: "calibrate_reach", duration: 0.25...1.25, loops: false),
        .init(name: "extend_other_arm", duration: 0.25...1.25, loops: false),
        .init(name: "reach_calibrated", duration: 0.25...1.25, loops: false),
        .init(name: "gym_ambience_loop", duration: 4...12, loops: true),
        .init(name: "competition_crowd_low_loop", duration: 4...12, loops: true),
        .init(name: "bell_start", duration: 0.3...2, loops: false),
        .init(name: "bell_end", duration: 0.3...2, loops: false),
        .init(name: "clean_hit_1", duration: 0.05...0.75, loops: false),
        .init(name: "clean_hit_2", duration: 0.05...0.75, loops: false),
        .init(name: "clean_hit_3", duration: 0.05...0.75, loops: false),
        .init(name: "rejected_hit", duration: 0.05...0.75, loops: false),
        .init(name: "tracking_lost", duration: 0.15...1.5, loops: false),
        .init(name: "tracking_restored", duration: 0.15...1.5, loops: false),
        .init(name: "improvement_sting", duration: 0.25...1.5, loops: false),
        .init(name: "winner_swell", duration: 0.5...2.5, loops: false)
    ]

    static let loopingBeds = required.filter(\.loops)
}
