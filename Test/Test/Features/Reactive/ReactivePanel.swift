//
//  ReactivePanel.swift
//  Test
//
//  Reactive Strike activity selection presentation.
//

import SwiftUI

extension ContentView {
    var reactiveStrikePanel: some View {
        VStack(spacing: 16) {
            if let selectedReactiveMode {
                switch selectedReactiveMode {
                case .virtualBoard:
                    virtualBoardPanel
                case .bagPreview:
                    bagPreviewPanel
                case .defense:
                    defensePanel
                }
            } else {
                reactiveModePicker
            }
        }
    }

    var reactiveModePicker: some View {
        VStack(spacing: 13) {
            ForEach(ReactiveStrikeMode.allCases, id: \.self) { mode in
                Button {
                    selectedReactiveMode = mode
                    syncProfileStance()
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: mode.symbol)
                            .font(.title2)
                            .foregroundStyle(mode.tint)
                            .frame(width: 38)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mode.title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(mode.subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(mode.badge)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(mode.tint.opacity(0.16), in: Capsule())
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
                .buttonStyle(.plain)
            }

            informationCard(
                title: "Personalized reach envelope",
                symbol: "figure.boxing",
                message: "Every active hand target stays in the calibrated forward area. No cue asks you to spin, chase, move backward, or strike behind you."
            )
        }
    }
}

extension ReactiveStrikeMode {
    var title: String {
        switch self {
        case .virtualBoard: "Virtual Punch Board"
        case .bagPreview: "Physical Bag"
        case .defense: "Defense Lab"
        }
    }

    var subtitle: String {
        switch self {
        case .virtualBoard: "React to six personalized virtual pads"
        case .bagPreview: "Configure and inspect a static bag overlay"
        case .defense: "Practice stationary slips and ducks with head tracking"
        }
    }

    var badge: String {
        switch self {
        case .virtualBoard: "Playable"
        case .bagPreview: "Preview"
        case .defense: "Head only"
        }
    }

    var symbol: String {
        switch self {
        case .virtualBoard: "circle.grid.2x2.fill"
        case .bagPreview: "cylinder.fill"
        case .defense: "figure.boxing"
        }
    }

    var tint: Color {
        switch self {
        case .virtualBoard: .orange
        case .bagPreview: .yellow
        case .defense: .mint
        }
    }
}
