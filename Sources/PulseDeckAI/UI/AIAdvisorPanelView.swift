import SwiftUI
import PulseDeckCore

/// Apple-native macOS popover and panel for the cooperative AI DJ adviser.
/// Displays local fast provisional advice and optional Gemini background refinement.
/// Strictly read-only advisory suggestions; never mutates live transport or arms transitions automatically.
@MainActor
public struct AIAdvisorPanelView: View {
    @ObservedObject var appState: AppState
    @State private var showingKeyInput = false
    @State private var apiKeyText = ""
    @State private var showingDisclosure = false

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            Divider().background(DJTheme.border)

            modeAndProviderSection
            Divider().background(DJTheme.border)

            trackContextSection

            if let error = appState.advisorErrorMessage {
                errorBanner(error)
            }

            if let rec = appState.activeRecommendation {
                recommendationSection(rec)
            } else if !appState.isAdvisorLoading {
                emptyStateSection
            }

            if appState.isAdvisorLoading {
                loadingSection
            }

            Spacer(minLength: 0)

            Divider().background(DJTheme.border)
            footerSection
        }
        .padding(14)
        .frame(width: 450, height: 540)
        .background(DJTheme.background)
        .foregroundColor(DJTheme.textPrimary)
    }

    // MARK: - Header Section

    private var headerSection: some View {
        HStack {
            Label("AI DJ Adviser", systemImage: "sparkles")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(DJTheme.textAccent)

            Spacer()

            Button {
                showingDisclosure.toggle()
            } label: {
                Label("Privacy Disclosure", systemImage: "info.circle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DJTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingDisclosure) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Metadata-Only Privacy Boundary")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(DJTheme.textPrimary)
                    Text("The AI Adviser only processes track metadata: BPM, duration, Camelot key, and relative file path.\n\nRaw audio data, stems, and personal folders are NEVER transmitted to cloud endpoints.")
                        .font(.system(size: 10))
                        .foregroundColor(DJTheme.textSecondary)
                }
                .padding(12)
                .frame(width: 280)
                .background(DJTheme.cardBackground)
            }
        }
    }

    // MARK: - Mode & Provider Section

    private var modeAndProviderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Mode:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DJTheme.textSecondary)

                Picker("Advisor Mode", selection: $appState.advisorMode) {
                    ForEach(AdvisorMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DJTheme.statusSuccess)
                        .frame(width: 6, height: 6)
                    Text("Local: \(appState.selectedLocalModel)")
                        .font(.system(size: 10))
                        .foregroundColor(DJTheme.textSecondary)
                }

                if appState.advisorMode == .cooperative {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(appState.hasGeminiAPIKey ? DJTheme.statusSuccess : DJTheme.statusWarning)
                            .frame(width: 6, height: 6)
                        Text(appState.hasGeminiAPIKey ? "Cloud: Gemini Ready" : "Cloud: Key Required")
                            .font(.system(size: 10))
                            .foregroundColor(DJTheme.textSecondary)

                        Button {
                            showingKeyInput.toggle()
                        } label: {
                            Text(appState.hasGeminiAPIKey ? "Change" : "Add Key")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundColor(DJTheme.textAccent)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showingKeyInput) {
                            keyInputPopover
                        }
                    }
                }

                Spacer()
            }
        }
    }

    private var keyInputPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gemini API Key")
                .font(.system(size: 11, weight: .bold))

            SecureField("Paste API key", text: $apiKeyText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10))

            HStack {
                Button("Save") {
                    appState.setGeminiAPIKey(apiKeyText.isEmpty ? nil : apiKeyText)
                    apiKeyText = ""
                    showingKeyInput = false
                }
                .font(.system(size: 10, weight: .semibold))

                if appState.hasGeminiAPIKey {
                    Button("Clear") {
                        appState.setGeminiAPIKey(nil)
                        apiKeyText = ""
                        showingKeyInput = false
                    }
                    .font(.system(size: 10))
                    .foregroundColor(DJTheme.statusError)
                }
            }
        }
        .padding(12)
        .frame(width: 260)
        .background(DJTheme.cardBackground)
    }

    // MARK: - Track Context Section

    private var trackContextSection: some View {
        let current = appState.selectedTrack ?? appState.referenceTrack

        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CURRENT REFERENCE")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(DJTheme.textMuted)

                if let track = current {
                    Text(track.relativePath)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DJTheme.textPrimary)
                        .lineLimit(1)
                    Text("\(String(format: "%.1f", track.bpm)) BPM · Key \(track.musicalKey) · \(formatDuration(track.duration))")
                        .font(.system(size: 9.5))
                        .foregroundColor(DJTheme.textSecondary)
                } else {
                    Text("No track selected (select in library or load deck)")
                        .font(.system(size: 10.5))
                        .foregroundColor(DJTheme.textMuted)
                }
            }

            Spacer()

            Button {
                appState.requestAdvice(for: current)
            } label: {
                Label("Get Advice", systemImage: "sparkles")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(current != nil && !appState.isAdvisorLoading ? DJTheme.cue : DJTheme.textMuted)
                    .padding(.horizontal, 10)
                    .frame(minHeight: DJTheme.minTouchTarget)
                    .background(DJTheme.cardHeader)
                    .cornerRadius(DJTheme.controlRadius)
                    .overlay(
                        RoundedRectangle(cornerRadius: DJTheme.controlRadius)
                            .stroke(current != nil && !appState.isAdvisorLoading ? DJTheme.cue.opacity(0.7) : DJTheme.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(StudioPressableStyle())
            .disabled(current == nil || appState.isAdvisorLoading)
        }
        .padding(8)
        .background(DJTheme.cardBackground)
        .cornerRadius(DJTheme.cardRadius)
        .overlay(
            RoundedRectangle(cornerRadius: DJTheme.cardRadius)
                .stroke(DJTheme.border, lineWidth: 1)
        )
    }

    // MARK: - Recommendation Section

    private func recommendationSection(_ rec: CooperativeRecommendation) -> some View {
        let active = rec.activeRecommendation

        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // Provider Provenance Badges
                HStack(spacing: 6) {
                    badgeView(
                        label: rec.refinement != nil ? "Provisional: \(rec.localModelLabel)" : "Active: \(rec.localModelLabel)",
                        color: DJTheme.deckA
                    )

                    if let cloud = rec.cloudModelLabel {
                        badgeView(label: "Refined: \(cloud)", color: DJTheme.deckB)
                    }

                    if rec.isRefining {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Refining with Gemini...")
                                .font(.system(size: 9))
                                .foregroundColor(DJTheme.textMuted)
                        }
                    }

                    Spacer()
                }

                // Suggested Track Card
                VStack(alignment: .leading, spacing: 4) {
                    Text("SUGGESTED NEXT TRACK")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(DJTheme.textMuted)

                    Text(active.suggestedTrackPath)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(DJTheme.textPrimary)
                        .lineLimit(1)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DJTheme.cardHeader)
                .cornerRadius(DJTheme.controlRadius)

                // Compatibility Metrics
                HStack(spacing: 12) {
                    metricTile(title: "HARMONIC", value: active.harmonicCompatibility, color: DJTheme.deckA)
                    metricTile(title: "ENERGY", value: active.energyProgression, color: DJTheme.deckB)
                    metricTile(title: "PHRASE", value: "\(active.transitionBars) Bars", color: DJTheme.master)
                }

                // Transition Cue Advisory
                HStack {
                    Text("Suggested Mix-In: \(String(format: "%.1f", active.suggestedMixInSeconds))s")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DJTheme.textSecondary)

                    Spacer()

                    Button {
                        appState.applySuggestedBars(active.transitionBars)
                    } label: {
                        Text("Apply \(active.transitionBars) Bars to Macro")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(DJTheme.master)
                            .padding(.horizontal, 8)
                            .frame(minHeight: 22)
                            .background(DJTheme.surfaceRaised)
                            .cornerRadius(DJTheme.chipRadius)
                            .overlay(
                                RoundedRectangle(cornerRadius: DJTheme.chipRadius)
                                    .stroke(DJTheme.master.opacity(0.6), lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(StudioPressableStyle())
                    .help("Sets the phrase length in the transition controls without starting playback")
                }
                .padding(.vertical, 2)

                // Musical Rationale
                VStack(alignment: .leading, spacing: 3) {
                    Text("ADVISORY RATIONALE")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(DJTheme.textMuted)

                    Text(active.rationale)
                        .font(.system(size: 10))
                        .foregroundColor(DJTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DJTheme.cardBackground)
                .cornerRadius(DJTheme.controlRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: DJTheme.controlRadius)
                        .stroke(DJTheme.border, lineWidth: 1)
                )
            }
        }
    }

    private func metricTile(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(DJTheme.textMuted)
            Text(value)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(color)
                .lineLimit(1)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DJTheme.surfaceRaised)
        .cornerRadius(DJTheme.chipRadius)
    }

    private func badgeView(label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .cornerRadius(DJTheme.chipRadius)
            .overlay(
                RoundedRectangle(cornerRadius: DJTheme.chipRadius)
                    .stroke(color.opacity(0.4), lineWidth: 0.5)
            )
    }

    // MARK: - Auxiliary States

    private var emptyStateSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 24))
                .foregroundColor(DJTheme.textMuted)
            Text("Ready for AI DJ Guidance")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DJTheme.textSecondary)
            Text("Click 'Get Advice' to analyze harmonic alignment and energy progression using local fast inference and optional Gemini refinement.")
                .font(.system(size: 9.5))
                .foregroundColor(DJTheme.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    private var loadingSection: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(appState.activeRecommendation?.isRefining == true ? "Refining with Gemini..." : "Analyzing tracks with \(appState.selectedLocalModel)...")
                .font(.system(size: 10))
                .foregroundColor(DJTheme.textSecondary)
            Spacer()
            Button("Cancel") {
                appState.cancelAdvisor()
            }
            .font(.system(size: 9.5))
            .foregroundColor(DJTheme.statusError)
        }
        .padding(8)
        .background(DJTheme.cardBackground)
        .cornerRadius(DJTheme.controlRadius)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(DJTheme.statusWarning)
                .font(.system(size: 10))
            Text(message)
                .font(.system(size: 9.5))
                .foregroundColor(DJTheme.textSecondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(6)
        .background(DJTheme.statusError.opacity(0.12))
        .cornerRadius(DJTheme.controlRadius)
        .overlay(
            RoundedRectangle(cornerRadius: DJTheme.controlRadius)
                .stroke(DJTheme.statusError.opacity(0.4), lineWidth: 1)
        )
    }

    private var footerSection: some View {
        HStack {
            Label("Read-Only Advisory · Direct transport control disabled", systemImage: "shield.fill")
                .font(.system(size: 8.5))
                .foregroundColor(DJTheme.textMuted)
            Spacer()
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
