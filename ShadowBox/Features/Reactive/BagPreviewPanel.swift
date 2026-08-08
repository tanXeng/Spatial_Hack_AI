//
//  BagPreviewPanel.swift
//  Test
//
//  Physical-bag profile and non-contact preview presentation.
//

import SwiftUI

extension ContentView {
    var bagPreviewPanel: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Physical Bag", systemImage: "cylinder.fill")
                        .font(.headline)
                    Spacer()
                    Text("EXPERIMENTAL PREVIEW")
                        .font(.caption2.bold())
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.orange.opacity(0.20), in: Capsule())
                }

                TextField("Bag name", text: $bagName)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 12) {
                    Picker("Type", selection: $bagType) {
                        Text("Hanging").tag(BagType.hanging)
                        Text("Freestanding").tag(BagType.freestanding)
                        Text("Reflex").tag(BagType.reflex)
                    }
                    Picker("Targets", selection: $bagLayout) {
                        Text("2 zones").tag(BagTargetLayout.twoTarget)
                        Text("4 zones").tag(BagTargetLayout.fourTarget)
                        Text("6 zones").tag(BagTargetLayout.sixTarget)
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                    measurementRow("Bag height", meters: $bagHeightMeters)
                    measurementRow("Bag diameter", meters: $bagDiameterMeters)
                }

                Button(profileStore.bagProfile == nil ? "Save bag profile" : "Update bag profile") {
                    saveBagProfile()
                }
                .buttonStyle(.borderedProminent)

                if let error = profileStore.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .cardStyle()

            warningCard(
                "Preview only. This build renders a stationary size-and-layout proxy approximately one metre ahead. It does not align to, track, or score a real bag, motion, impact, contact, or force. Do not strike a physical bag while wearing Vision Pro."
            )

            informationCard(
                title: "Companion and marker status",
                symbol: "iphone.and.arrow.forward",
                message: "iPhone/iPad scanning, shared-coordinate alignment, and a rigid bag marker are not included in this software MVP. The app never reports a fake connection."
            )

            safetyCard(for: .bagPreview)

            if appModel.immersiveSpaceState == .open,
               appModel.activeExperience == .bagPreview {
                informationCard(
                    title: "Static preview visible",
                    symbol: "eye.fill",
                    message: "Inspect the configured target layout from a stationary position. The proxy is not aligned to the room or a real bag, and no contact scoring is active."
                )
            }
        }
    }

    func saveBagProfile() {
        _ = profileStore.saveBag(BagProfile(
            name: bagName,
            type: bagType,
            targetLayout: bagLayout,
            heightMeters: bagHeightMeters,
            diameterMeters: bagDiameterMeters
        ))
    }
}
