//
//  ProfilePanel.swift
//  Test
//
//  Anthropometry profile presentation owned by the Profile feature.
//

import SwiftUI

extension ContentView {
    var anthropometryPanel: some View {
        VStack(spacing: 16) {
            informationCard(
                title: "Personalization, not sensor calibration",
                symbol: "ruler",
                message: "Manual dimensions help catch entry mistakes and document fit. They do not improve ARKit’s hand-tracking accuracy and are not used as silent target-placement substitutes. Live guard-and-reach calibration remains authoritative."
            )

            measurementProtocolCard

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Body & reach profile")
                        .font(.headline)
                    Spacer()
                    Picker("Units", selection: $measurementUnit) {
                        Text("Metric").tag(MeasurementUnit.metric)
                        Text("Imperial").tag(MeasurementUnit.imperial)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }

                HStack(spacing: 12) {
                    Picker("Stance", selection: $draftStance) {
                        ForEach(Stance.allCases, id: \.self) { stance in
                            Text(stance.title).tag(stance)
                        }
                    }
                    Picker("Dominant hand", selection: $draftDominantHand) {
                        Text("Left").tag(HandSide.left)
                        Text("Right").tag(HandSide.right)
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                    measurementRow("Height", meters: $heightMeters)
                    measurementRow("Arm span", meters: $armSpanMeters)
                    measurementRow("Left arm", meters: $leftArmMeters)
                    measurementRow("Right arm", meters: $rightArmMeters)
                    measurementRow("Shoulder width", meters: $shoulderWidthMeters)
                }

                if storedReachWillBeCleared {
                    Label(
                        "These fit changes will clear the saved live-reach value. Recapture reach before the next hand-led drill.",
                        systemImage: "arrow.clockwise.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                HStack {
                    Button(profileStore.hasProfile ? "Update profile" : "Save profile") {
                        saveBoxerProfile()
                    }
                    .buttonStyle(.borderedProminent)

                    if profileStore.hasProfile {
                        Button("Reset", role: .destructive) {
                            profileStore.resetBoxer()
                        }
                        .buttonStyle(.borderless)
                    }

                    Spacer()

                    if let pendingFeatureAfterProfile, profileStore.hasProfile {
                        Button("Continue to \(pendingFeatureAfterProfile.title)") {
                            selectedFeature = pendingFeatureAfterProfile
                            self.pendingFeatureAfterProfile = nil
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if let error = profileStore.lastError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))

            if let draftProfile = try? draftBoxerProfile.validated() {
                anthropometryQualityCard(
                    draftProfile.anthropometryAssessment,
                    measuredReachMeters: draftProfile.measuredComfortableReachMeters
                )
            }

            safetyCard(for: .anthropometryCalibration)

            if appModel.immersiveSpaceState == .open,
               appModel.activeExperience == .anthropometryCalibration {
                trackingStatusCard
                calibrationCard(includeRound: false)
            }
        }
    }

    func measurementRow(_ label: String, meters: Binding<Double>) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            TextField(
                label,
                value: displayLengthBinding(meters),
                format: .number.precision(.fractionLength(0...1))
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 130)
            Text(measurementUnit.displayLengthSymbol)
                .foregroundStyle(.secondary)
        }
    }

    var measurementProtocolCard: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                protocolStep(
                    "Height",
                    "Barefoot against a wall: level floor to the crown of the head."
                )
                protocolStep(
                    "Arm span",
                    "Back to wall, arms level and relaxed: middle fingertip to middle fingertip."
                )
                protocolStep(
                    "Left & right arm",
                    "Measure each outer shoulder point to the middle fingertip using the same straight-arm posture."
                )
                protocolStep(
                    "Shoulder width",
                    "Straight across between the same outer shoulder points—not around the back."
                )

                Divider()

                Label(
                    "Relax and reposition between three readings of every dimension; enter the middle value. This app stores one value, so it can check internal agreement but cannot prove repeatability.",
                    systemImage: "repeat"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                Divider()

                protocolStep(
                    "Live functional reach",
                    "In the mixed space, begin with both fists at guard. Extend and return each fist twice, finishing one hand's pair before switching; the other fist stays at guard."
                )
                protocolStep(
                    "Session repeatability",
                    "Each hand is checked independently. Its shorter repetition is accepted only when the pair differs by no more than the larger of the provisional 5 cm floor and 12% allowance."
                )
                Label(
                    "Only the minimum uncapped accepted left/right reach is added to your local profile. Per-hand results, repetition values, and world-space capture state remain session-only.",
                    systemImage: "lock.shield"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(.top, 12)
        } label: {
            Label("How to measure consistently", systemImage: "list.number")
                .font(.headline)
        }
        .cardStyle()
    }

    func protocolStep(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func anthropometryQualityCard(
        _ assessment: AnthropometryAssessment,
        measuredReachMeters: Double?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label(
                    assessment.qualityGrade.title,
                    systemImage: assessment.qualityGrade.symbol
                )
                .font(.headline)
                .foregroundStyle(assessment.qualityGrade.color)

                Spacer()

                Text("Consistency preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(assessment.qualityGrade.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 7) {
                ForEach(assessment.checks, id: \.kind) { check in
                    HStack(spacing: 8) {
                        Image(systemName: check.level.symbol)
                            .foregroundStyle(check.level.color)
                            .frame(width: 18)
                        Text(check.kind.title)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(checkValue(check.kind, assessment: assessment))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    .font(.footnote)
                }
            }

            Divider()

            metricLine(
                "Conservative manual reach",
                length(assessment.conservativeReachMeters)
            )
            metricLine(
                "Heuristic uncertainty",
                "±\(length(assessment.reachUncertaintyMeters))"
            )
            metricLine(
                "Live comfortable reach",
                measuredReachMeters.map(length) ?? "Capture in immersion"
            )

            if assessment.qualityGrade != .strong {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(
                        assessment.checks.filter { $0.level != .consistent },
                        id: \.kind
                    ) { check in
                        Label(check.kind.guidance, systemImage: "arrow.counterclockwise")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text("The ± value is a transparent entry-consistency allowance, not a statistical confidence interval or a clinical assessment. Live guard and comfortable reach—not this estimate—drive the training fit.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    func checkValue(
        _ kind: AnthropometryCheckKind,
        assessment: AnthropometryAssessment
    ) -> String {
        switch kind {
        case .armSpanClosure:
            "\(length(assessment.armSpanClosureErrorMeters)) gap"
        case .sideAsymmetry:
            "\(length(assessment.armLengthAsymmetryMeters))"
        case .armSpanToHeight:
            String(format: "%.2fx", assessment.armSpanToHeightRatio)
        case .shoulderWidthToHeight:
            String(format: "%.2fx", assessment.shoulderWidthToHeightRatio)
        case .armLengthToHeight:
            String(format: "%.2fx", assessment.averageArmLengthToHeightRatio)
        }
    }

    func saveBoxerProfile() {
        if profileStore.saveBoxer(draftBoxerProfile) {
            roundEngine.setStance(draftStance)
        }
    }

    var draftBoxerProfile: BoxerProfile {
        var draft = draftBodyMeasurements
        if let stored = profileStore.boxerProfile,
           stored.hasEquivalentBodyMeasurements(to: draft) {
            draft.measuredComfortableReachMeters = stored.measuredComfortableReachMeters
        }
        return draft
    }

    var draftBodyMeasurements: BoxerProfile {
        BoxerProfile(
            preferredMeasurementUnit: measurementUnit,
            stanceRawValue: draftStance.rawValue,
            dominantHandRawValue: draftDominantHand.rawValue,
            heightMeters: heightMeters,
            armSpanMeters: armSpanMeters,
            leftArmLengthMeters: leftArmMeters,
            rightArmLengthMeters: rightArmMeters,
            shoulderWidthMeters: shoulderWidthMeters
        )
    }

    var storedReachWillBeCleared: Bool {
        guard let stored = profileStore.boxerProfile,
              stored.measuredComfortableReachMeters != nil else { return false }
        return !stored.hasEquivalentBodyMeasurements(to: draftBodyMeasurements)
    }

    func displayLengthBinding(_ meters: Binding<Double>) -> Binding<Double> {
        Binding(
            get: { measurementUnit.displayLength(fromMeters: meters.wrappedValue) },
            set: { meters.wrappedValue = measurementUnit.meters(fromDisplayLength: $0) }
        )
    }
}

private extension AnthropometryQualityGrade {
    var title: String {
        switch self {
        case .strong: "Strong measurement agreement"
        case .usable: "Usable — verify flagged values"
        case .recheck: "Recheck before training"
        }
    }

    var summary: String {
        switch self {
        case .strong:
            "The redundant entries agree within the app’s broad heuristic checks. Repeated readings are still recommended."
        case .usable:
            "The values are plausible but one or more cross-checks show moderate disagreement. Repeat the flagged measurements."
        case .recheck:
            "At least one broad consistency check is outside the review band. This may be genuine anatomy or a measurement issue—verify rather than forcing a ‘normal’ value."
        }
    }

    var symbol: String {
        switch self {
        case .strong: "checkmark.shield.fill"
        case .usable: "exclamationmark.triangle.fill"
        case .recheck: "arrow.clockwise.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .strong: .green
        case .usable: .yellow
        case .recheck: .orange
        }
    }
}

private extension AnthropometryCheckLevel {
    var symbol: String {
        switch self {
        case .consistent: "checkmark.circle.fill"
        case .caution: "exclamationmark.circle.fill"
        case .recheck: "arrow.clockwise.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .consistent: .green
        case .caution: .yellow
        case .recheck: .orange
        }
    }
}

private extension AnthropometryCheckKind {
    var title: String {
        switch self {
        case .armSpanClosure: "Arm-span cross-check"
        case .sideAsymmetry: "Left/right difference"
        case .armSpanToHeight: "Arm span ÷ height"
        case .shoulderWidthToHeight: "Shoulders ÷ height"
        case .armLengthToHeight: "Average arm ÷ height"
        }
    }

    var guidance: String {
        switch self {
        case .armSpanClosure:
            "Repeat arm span, both arms, and shoulder width with identical shoulder and fingertip landmarks."
        case .sideAsymmetry:
            "Repeat both sides with the same posture. A persistent side difference can be genuine; keep the measured values."
        case .armSpanToHeight:
            "Verify arm span and height definitions and units. Unusual proportions can be genuine."
        case .shoulderWidthToHeight:
            "Verify that shoulder width is a straight landmark-to-landmark distance, not a curved tape path."
        case .armLengthToHeight:
            "Verify shoulder-to-middle-fingertip measurements on both sides using relaxed, level arms."
        }
    }
}
