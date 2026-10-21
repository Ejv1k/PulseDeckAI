import SwiftUI
import PulseDeckCore

/// High-contrast dual Master and Cue output routing selector view.
public struct OutputRoutingView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        HStack(spacing: 12) {
            selectorCard(
                role: .master,
                title: "MASTER OUTPUT (FOH)",
                color: DJTheme.master,
                selectedUID: appState.masterOutputUID,
                descriptor: appState.masterDeviceDescriptor,
                isFallback: appState.isMasterFallback,
                warning: appState.masterWarning,
                error: appState.masterRoutingError
            )

            selectorCard(
                role: .cue,
                title: "HEADPHONES / CUE",
                color: DJTheme.cue,
                selectedUID: appState.cueOutputUID,
                descriptor: appState.cueDeviceDescriptor,
                isFallback: appState.isCueFallback,
                warning: appState.cueWarning,
                error: appState.cueRoutingError
            )
        }
    }

    private func selectorCard(
        role: AudioEngineRole,
        title: String,
        color: Color,
        selectedUID: String?,
        descriptor: AudioDeviceDescriptor?,
        isFallback: Bool,
        warning: String?,
        error: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)

                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(DJTheme.textPrimary)

                Spacer()

                if isFallback {
                    Text("FALLBACK")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(DJTheme.cue.opacity(0.2))
                        .foregroundColor(DJTheme.cue)
                        .cornerRadius(2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(DJTheme.cue, lineWidth: 1)
                        )
                }

                if descriptor?.isBluetooth == true {
                    Text("BT")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(DJTheme.textAccent.opacity(0.2))
                        .foregroundColor(DJTheme.textAccent)
                        .cornerRadius(2)
                }
            }

            // Output Device Picker
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { selectedUID ?? "" },
                    set: { newUID in
                        if !newUID.isEmpty {
                            appState.selectOutputDevice(role: role, uid: newUID)
                        }
                    }
                )) {
                    if appState.availableOutputDevices.isEmpty {
                        Text("No Output Devices Found").tag("")
                    } else {
                        ForEach(appState.availableOutputDevices) { device in
                            Text("\(device.name) (\(device.outputChannelCount)ch, \(Int(device.sampleRate / 1000))kHz)")
                                .tag(device.id)
                        }
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .accentColor(color)

                Button(action: {
                    appState.refreshOutputDevices()
                }) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10))
                        .foregroundColor(DJTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Refresh connected output devices")
            }

            if let error {
                Text(error)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.red)
                    .lineLimit(1)
            } else if let warning {
                Text(warning)
                    .font(.system(size: 8.5, weight: .regular, design: .monospaced))
                    .foregroundColor(DJTheme.textAccent)
                    .lineLimit(2)
            } else if let desc = descriptor {
                Text("\(desc.manufacturer) • \(desc.outputChannelCount) Channels • \(Int(desc.sampleRate)) Hz")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(DJTheme.textMuted)
                    .lineLimit(1)
            } else {
                Text("Default System Audio Routing")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(DJTheme.textMuted)
            }
        }
        .padding(8)
        .background(DJTheme.cardBackground)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isFallback ? DJTheme.cue.opacity(0.5) : DJTheme.border, lineWidth: 1)
        )
    }
}
