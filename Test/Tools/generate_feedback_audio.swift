#!/usr/bin/env swift

import Foundation

/// Reproducibly generates the original, mono PCM cues bundled with ShadowBox.
/// The tones carry no speech or copyrighted source material. RealityKit places
/// them in the scene; this script only creates the source WAV files.
private let sampleRate = 48_000

private struct Tone {
    let start: Double
    let duration: Double
    let startFrequency: Double
    let endFrequency: Double
    let amplitude: Double
}

private func envelope(_ progress: Double) -> Double {
    let attack = min(1, progress / 0.08)
    let release = min(1, (1 - progress) / 0.22)
    return max(0, min(attack, release))
}

private func samples(duration: Double, tones: [Tone]) -> [Int16] {
    let frameCount = Int((duration * Double(sampleRate)).rounded())
    return (0..<frameCount).map { frame in
        let time = Double(frame) / Double(sampleRate)
        var value = 0.0

        for tone in tones where time >= tone.start && time < tone.start + tone.duration {
            let localTime = time - tone.start
            let progress = localTime / tone.duration
            let frequency = tone.startFrequency
                + (tone.endFrequency - tone.startFrequency) * progress
            let phase = 2 * Double.pi * frequency * localTime
            value += sin(phase) * tone.amplitude * envelope(progress)
        }

        let limited = max(-0.92, min(0.92, value))
        return Int16((limited * Double(Int16.max)).rounded())
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

private func wavData(_ samples: [Int16]) -> Data {
    let bytesPerSample = 2
    let dataByteCount = samples.count * bytesPerSample
    var data = Data()
    data.append(contentsOf: "RIFF".utf8)
    data.appendLittleEndian(UInt32(36 + dataByteCount))
    data.append(contentsOf: "WAVE".utf8)
    data.append(contentsOf: "fmt ".utf8)
    data.appendLittleEndian(UInt32(16))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(UInt32(sampleRate))
    data.appendLittleEndian(UInt32(sampleRate * bytesPerSample))
    data.appendLittleEndian(UInt16(bytesPerSample))
    data.appendLittleEndian(UInt16(16))
    data.append(contentsOf: "data".utf8)
    data.appendLittleEndian(UInt32(dataByteCount))
    for sample in samples {
        data.appendLittleEndian(sample)
    }
    return data
}

private struct Cue {
    let filename: String
    let duration: Double
    let tones: [Tone]
}

private let cues = [
    Cue(
        filename: "coach-cue.wav",
        duration: 0.15,
        tones: [Tone(start: 0, duration: 0.15, startFrequency: 640, endFrequency: 880, amplitude: 0.42)]
    ),
    Cue(
        filename: "clean-hit.wav",
        duration: 0.19,
        tones: [
            Tone(start: 0, duration: 0.14, startFrequency: 150, endFrequency: 105, amplitude: 0.58),
            Tone(start: 0.035, duration: 0.15, startFrequency: 620, endFrequency: 790, amplitude: 0.24),
        ]
    ),
    Cue(
        filename: "miss.wav",
        duration: 0.18,
        tones: [Tone(start: 0, duration: 0.18, startFrequency: 230, endFrequency: 125, amplitude: 0.38)]
    ),
    Cue(
        filename: "paused.wav",
        duration: 0.22,
        tones: [Tone(start: 0, duration: 0.22, startFrequency: 410, endFrequency: 285, amplitude: 0.30)]
    ),
    Cue(
        filename: "set-complete.wav",
        duration: 0.52,
        tones: [
            Tone(start: 0.00, duration: 0.20, startFrequency: 523.25, endFrequency: 523.25, amplitude: 0.28),
            Tone(start: 0.14, duration: 0.20, startFrequency: 659.25, endFrequency: 659.25, amplitude: 0.28),
            Tone(start: 0.28, duration: 0.24, startFrequency: 783.99, endFrequency: 783.99, amplitude: 0.32),
        ]
    ),
]

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: generate_feedback_audio.swift <output-directory>\n".utf8))
    exit(64)
}

let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

for cue in cues {
    let destination = outputDirectory.appendingPathComponent(cue.filename)
    try wavData(samples(duration: cue.duration, tones: cue.tones)).write(
        to: destination,
        options: .atomic
    )
    print(destination.path)
}
