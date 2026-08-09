import AVFoundation
import Testing
@testable import BoxingCoach

@Suite("Sonic ring resource inventory")
struct AudioResourceInventoryTests {
    @Test("Every authored sonic-ring sound resolves as safe, audible PCM")
    func sonicRingResourcesResolveWithSafeAudibleFormat() throws {
        for resource in TrainingAudioResourceID.sonicRingResources {
            let url = try #require(
                CoachClipLibrary.url(for: resource),
                "Missing runtime resource: \(resource.fileName)"
            )
            let file = try AVAudioFile(forReading: url)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            let expectedDuration = resource.isLoopingBed ? 4...12 : 0.05...2.5

            #expect(url.pathExtension.lowercased() == "wav")
            #expect(file.fileFormat.commonFormat == .pcmFormatInt16)
            #expect(file.processingFormat.channelCount == 1)
            #expect(file.processingFormat.sampleRate == 22_050)
            #expect(expectedDuration.contains(duration), "\(resource.fileName) duration was \(duration)s")

            let levels = try decodedLevels(for: file)
            #expect(levels.peak > 0.02, "\(resource.fileName) decoded as silence")
            #expect(levels.rms > 0.003, "\(resource.fileName) decoded as effectively silent")
            #expect(levels.peak <= 0.9, "\(resource.fileName) peak exceeds safety ceiling")
            #expect(levels.rms <= 0.4, "\(resource.fileName) RMS exceeds safety ceiling")
        }
    }

    @Test("Looping beds meet at their boundaries without a discontinuity")
    func loopingBedsHaveContinuousBoundaries() throws {
        for resource in TrainingAudioResourceID.sonicRingResources where resource.isLoopingBed {
            let url = try #require(CoachClipLibrary.url(for: resource))
            let samples = try decodedSamples(from: AVAudioFile(forReading: url))
            let boundary = try #require(loopBoundaryError(samples))

            #expect(boundary.sampleStep < 0.08, "\(resource.fileName) loop endpoint clicks")
            #expect(boundary.slopeStep < 0.08, "\(resource.fileName) loop endpoint changes slope")
        }
    }

    @Test("Validated impacts never resolve to the long spoken target prompt")
    func impactVariantsExcludeSpokenNarration() {
        #expect(
            TrainingAudioResourceID.cleanImpactVariants.allSatisfy {
                $0.fileName != CoachClipID.hitTarget.rawValue
            }
        )
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
