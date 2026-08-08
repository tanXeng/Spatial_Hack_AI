//
//  ContentView.swift
//  Test
//
//  Three-pillar Boxing Trainer shell, independently reimplemented from the
//  read-only reference repository's material-card information architecture.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppModel.self) var appModel
    @Environment(HandTrackingService.self) var handTracking
    @Environment(RoundEngine.self) var roundEngine
    @Environment(TrainingProfileStore.self) var profileStore
    @Environment(AuraPunchEngine.self) var auraPunch
    @Environment(DefenseEngine.self) var defense
    @Environment(TrainingSessionSettings.self) var trainingSettings

    @State var selectedFeature: TrainingFeature?
    @State var selectedReactiveMode: ReactiveStrikeMode?
    @State var pendingFeatureAfterProfile: TrainingFeature?
    @State var safetyAcknowledged = false
    @State private var didLoadDrafts = false

    @State var measurementUnit = MeasurementUnit.metric
    @State var draftStance = Stance.orthodox
    @State var draftDominantHand = HandSide.right
    @State var heightMeters = 1.75
    @State var armSpanMeters = 1.78
    @State var leftArmMeters = 0.70
    @State var rightArmMeters = 0.70
    @State var shoulderWidthMeters = 0.38

    @State var bagName = "Home bag"
    @State var bagType = BagType.hanging
    @State var bagLayout = BagTargetLayout.fourTarget
    @State var bagHeightMeters = 1.20
    @State var bagDiameterMeters = 0.36

    var body: some View {
        Group {
            if let selectedFeature {
                featureDetail(selectedFeature)
            } else {
                featureMenu
            }
        }
        .padding(32)
        .frame(
            minWidth: 560,
            idealWidth: 700,
            maxWidth: .infinity,
            minHeight: 620,
            idealHeight: 780,
            maxHeight: .infinity
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            immersiveActionBar
        }
        .onAppear {
            loadDraftsIfNeeded()
            restoreRouteIfNeeded()
        }
        .onChange(of: appModel.immersiveSpaceState) { _, newState in
            if newState == .closed {
                safetyAcknowledged = false
            }
        }
        .onChange(of: appModel.lastExperience) { _, experience in
            guard let experience else { return }
            route(to: experience)
        }
        .onChange(of: selectedFeature) { _, _ in
            safetyAcknowledged = false
        }
        .onChange(of: selectedReactiveMode) { _, _ in
            safetyAcknowledged = false
        }
        .onChange(of: auraPunch.summary) { _, summary in
            guard summary != nil else { return }
            refreshIntensityRecommendation(for: .auraPunch)
        }
        .onChange(of: roundEngine.summary) { _, summary in
            guard summary != nil else { return }
            refreshIntensityRecommendation(for: .reactiveBoard)
        }
        .onChange(of: defense.summary) { _, summary in
            guard summary != nil else { return }
            refreshIntensityRecommendation(for: .defense)
        }
    }

    // MARK: - Reference-format shell

    private var featureMenu: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 4)

                VStack(spacing: 6) {
                    Text("BOXER")
                        .font(.system(.largeTitle, design: .rounded, weight: .black))
                        .tracking(3)
                    Text("Boxing Trainer")
                        .font(.title3.weight(.semibold))
                    Text("Personalize. Learn. React.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 14) {
                    ForEach(TrainingFeature.allCases, id: \.self) { feature in
                        Button {
                            choose(feature)
                        } label: {
                            featureRow(feature)
                        }
                        .buttonStyle(.plain)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Label("Local profile", systemImage: "lock.shield")
                        Text("•")
                        Label("Mixed passthrough", systemImage: "vision.pro")
                        Text("•")
                        Label(
                            "No force claims",
                            systemImage: "gauge.with.dots.needle.0percent"
                        )
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Local profile", systemImage: "lock.shield")
                        Label("Mixed passthrough", systemImage: "vision.pro")
                        Label(
                            "No force claims",
                            systemImage: "gauge.with.dots.needle.0percent"
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private func featureRow(_ feature: TrainingFeature) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        featureIcon(feature)
                        Text(feature.title)
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    Text(feature.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    featureBadgeView(feature)
                }
            } else {
                HStack(spacing: 18) {
                    featureIcon(feature)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(feature.title)
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                        Text(feature.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                    featureBadgeView(feature)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .contentShape(RoundedRectangle(cornerRadius: 20))
    }

    private func featureIcon(_ feature: TrainingFeature) -> some View {
        Image(systemName: feature.symbol)
            .font(.system(size: 25, weight: .semibold))
            .frame(width: 46, height: 46)
            .foregroundStyle(feature.tint)
            .background(feature.tint.opacity(0.16), in: Circle())
    }

    private func featureBadgeView(_ feature: TrainingFeature) -> some View {
        Text(featureBadge(feature))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(feature.tint.opacity(0.18), in: Capsule())
    }

    @ViewBuilder
    private func featureDetail(_ feature: TrainingFeature) -> some View {
        VStack(spacing: 18) {
            HStack {
                Button {
                    goBack()
                } label: {
                    Label(backLabel, systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .disabled(appModel.immersiveSpaceState != .closed)

                Spacer()

                if profileStore.hasProfile {
                    Label("Profile ready", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }

            VStack(spacing: 5) {
                Text(detailTitle(feature))
                    .font(.largeTitle.bold())
                Text(detailSubtitle(feature))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            ScrollView {
                VStack(spacing: 16) {
                    switch feature {
                    case .anthropometry:
                        anthropometryPanel
                    case .auraPunch:
                        auraPunchPanel
                    case .reactiveStrike:
                        reactiveStrikePanel
                    }

                    if let message = appModel.immersiveSpaceError {
                        Label(message, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var immersiveActionBar: some View {
        if let experience = currentExperience {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appModel.immersiveSpaceState == .open ? appModel.activeExperienceTitle : experienceTitle(experience))
                            .font(.caption.bold())
                        Text(entryStatusText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ToggleImmersiveSpaceButton(
                        experience: experience,
                        entryAllowed: entryAllowed
                    )
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .background(.regularMaterial)
        }
    }

    // MARK: - Actions and derived state

    private var currentExperience: ImmersiveExperience? {
        switch selectedFeature {
        case .anthropometry:
            .anthropometryCalibration
        case .auraPunch:
            .auraPunch
        case .reactiveStrike:
            switch selectedReactiveMode {
            case .virtualBoard: .reactiveBoard
            case .bagPreview: .bagPreview
            case .defense: .defense
            case nil: nil
            }
        case nil:
            nil
        }
    }

    private var entryAllowed: Bool {
        guard let currentExperience else { return false }
        if appModel.immersiveSpaceState == .open { return true }
        guard safetyAcknowledged, profileStore.hasProfile else { return false }
        if currentExperience == .bagPreview {
            return profileStore.bagProfile != nil
        }
        return true
    }

    private var entryStatusText: String {
        if appModel.immersiveSpaceState == .open {
            return "Mixed passthrough active"
        }
        if !profileStore.hasProfile {
            return "Save Anthropometry first"
        }
        if currentExperience == .bagPreview, profileStore.bagProfile == nil {
            return "Save a bag profile first"
        }
        return safetyAcknowledged ? "Ready to enter" : "Complete the safety acknowledgement"
    }

    private func choose(_ feature: TrainingFeature) {
        if feature != .anthropometry, !profileStore.hasProfile {
            pendingFeatureAfterProfile = feature
            selectedFeature = .anthropometry
        } else {
            selectedFeature = feature
        }
        selectedReactiveMode = nil
        syncProfileStance()
    }

    private func goBack() {
        guard appModel.immersiveSpaceState == .closed else { return }
        if selectedFeature == .reactiveStrike, selectedReactiveMode != nil {
            selectedReactiveMode = nil
        } else {
            selectedFeature = nil
            selectedReactiveMode = nil
            pendingFeatureAfterProfile = nil
        }
        safetyAcknowledged = false
        appModel.activeExperience = nil
        appModel.lastExperience = nil
        appModel.immersiveSpaceError = nil
    }

    private func restoreRouteIfNeeded() {
        guard selectedFeature == nil,
              let experience = appModel.activeExperience ?? appModel.lastExperience else {
            return
        }

        route(to: experience)
    }

    private func route(to experience: ImmersiveExperience) {
        switch experience {
        case .anthropometryCalibration:
            selectedFeature = .anthropometry
            selectedReactiveMode = nil
        case .auraPunch:
            selectedFeature = .auraPunch
            selectedReactiveMode = nil
        case .reactiveBoard:
            selectedFeature = .reactiveStrike
            selectedReactiveMode = .virtualBoard
        case .bagPreview:
            selectedFeature = .reactiveStrike
            selectedReactiveMode = .bagPreview
        case .defense:
            selectedFeature = .reactiveStrike
            selectedReactiveMode = .defense
        }
        syncProfileStance()
    }

    private func loadDraftsIfNeeded() {
        guard !didLoadDrafts else { return }
        didLoadDrafts = true

        if let profile = profileStore.boxerProfile {
            measurementUnit = profile.preferredMeasurementUnit
            draftStance = Stance(rawValue: profile.stanceRawValue) ?? .orthodox
            draftDominantHand = HandSide(rawValue: profile.dominantHandRawValue) ?? .right
            heightMeters = profile.heightMeters
            armSpanMeters = profile.armSpanMeters
            leftArmMeters = profile.leftArmLengthMeters
            rightArmMeters = profile.rightArmLengthMeters
            shoulderWidthMeters = profile.shoulderWidthMeters
        }

        if let bag = profileStore.bagProfile {
            bagName = bag.name
            bagType = bag.type
            bagLayout = bag.targetLayout
            bagHeightMeters = bag.heightMeters
            bagDiameterMeters = bag.diameterMeters
        }
        syncProfileStance()
    }

    func syncProfileStance() {
        guard appModel.immersiveSpaceState == .closed else { return }
        let stance = profileStore.boxerProfile
            .flatMap { Stance(rawValue: $0.stanceRawValue) }
            ?? draftStance
        if roundEngine.selectedStance != stance {
            roundEngine.setStance(stance)
        }
    }

    // MARK: - Presentation helpers

    private func detailTitle(_ feature: TrainingFeature) -> String {
        if feature == .reactiveStrike, let selectedReactiveMode {
            return selectedReactiveMode.title
        }
        return feature.title
    }

    private func detailSubtitle(_ feature: TrainingFeature) -> String {
        if feature == .reactiveStrike, selectedReactiveMode == nil {
            return "Choose offense, a static bag preview, or head-movement defense"
        }
        if let selectedReactiveMode, feature == .reactiveStrike {
            return selectedReactiveMode.subtitle
        }
        return feature.subtitle
    }

    private var backLabel: String {
        selectedFeature == .reactiveStrike && selectedReactiveMode != nil
            ? "Activities"
            : "Trainer"
    }

    private func featureBadge(_ feature: TrainingFeature) -> String {
        switch feature {
        case .anthropometry:
            profileStore.hasProfile ? "Ready" : "Setup"
        case .auraPunch:
            profileStore.hasProfile ? "Jab + Cross" : "Setup first"
        case .reactiveStrike:
            "3 activities"
        }
    }

    private func experienceTitle(_ experience: ImmersiveExperience) -> String {
        switch experience {
        case .anthropometryCalibration: "Body & Reach Setup"
        case .auraPunch: "Aura Punch"
        case .reactiveBoard: "Virtual Punch Board"
        case .bagPreview: "Physical Bag Preview"
        case .defense: "Defense — Head Movement"
        }
    }

    func informationCard(title: String, symbol: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.cyan)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    func warningCard(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
    }

    func capabilityChip(_ title: String, symbol: String, color: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(color.opacity(0.14), in: Capsule())
    }

    func metricLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .font(.subheadline)
    }

    func length(_ meters: Double) -> String {
        let value = measurementUnit.displayLength(fromMeters: meters)
        return String(format: "%.1f %@", value, measurementUnit.displayLengthSymbol)
    }

    func percent(_ value: Double) -> String {
        "\(Int((min(1, max(0, value)) * 100).rounded()))%"
    }

    func optionalPercent(_ value: Double?) -> String {
        value.map(percent) ?? "—"
    }

    func milliseconds(_ value: TimeInterval?) -> String {
        value.map { "\(Int(($0 * 1_000).rounded())) ms" } ?? "—"
    }

}

extension TrainingFeature {
    var title: String {
        switch self {
        case .anthropometry: "Anthropometry"
        case .auraPunch: "Aura Punch"
        case .reactiveStrike: "Reactive Strike"
        }
    }

    var subtitle: String {
        switch self {
        case .anthropometry: "Configure body dimensions, stance, guard, and reach"
        case .auraPunch: "Follow personalized spatial hand-path guidance"
        case .reactiveStrike: "Practice a virtual board, static bag preview, and head movement"
        }
    }

    var symbol: String {
        switch self {
        case .anthropometry: "ruler.fill"
        case .auraPunch: "sparkles"
        case .reactiveStrike: "bolt.fill"
        }
    }

    var tint: Color {
        switch self {
        case .anthropometry: .cyan
        case .auraPunch: .purple
        case .reactiveStrike: .orange
        }
    }
}

extension View {
    func cardStyle() -> some View {
        self
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
        .environment(HandTrackingService())
        .environment(RoundEngine())
        .environment(TrainingProfileStore())
        .environment(AuraPunchEngine())
        .environment(DefenseEngine())
        .environment(TrainingSessionSettings())
}
