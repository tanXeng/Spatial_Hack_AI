import SwiftUI

/// Semantic presentation colors shared by window, immersive, and audience surfaces.
/// Meaning stays stable even when the concrete palette is tuned for the headset display.
nonisolated enum TrainingPalette {
    static let activeAmber = Color.orange
    static let validMint = Color.green
    static let invalidCoral = Color.red
    static let referenceCyan = Color.cyan
    static let glassPrimary = Color.white
    static let glassSecondary = Color.white.opacity(0.76)
    static let glassMuted = Color.white.opacity(0.72)
    static let glassSubdued = Color.white.opacity(0.64)
    static let glassOpaqueBackground = Color.black
    static let glassBackground = Color.black.opacity(0.72)
}
