import SwiftUI
import PulseDeckCore

/// High-contrast dual Master and Cue output routing selector ribbon.
public struct OutputRoutingView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 4) {
            if let startupError = appState.coordinatorErrorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(Color.red)
                    Text("Audio Engine Notice: \(startupError)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color.red)
                    Spacer()
                }
                .padding(6)
                .background(Color.red.opacity(0.12))
                .cornerRadius(DJTheme.controlRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: DJTheme.controlRadius)
                        .stroke(Color.red.opacity(0.3), lineWidth: 1)
                )
            }

            if let masterUID = appState.masterOutputUID,
               let cueUID = appState.cueOutputUID,
               !masterUID.isEmpty,
               masterUID == cueUID {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(DJTheme.statusWarning)
                    Text("Master and Cue use the same device (\(appState.masterDeviceDescriptor?.name ?? masterUID)), so headphone audition is heard on Master.")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DJTheme.statusWarning)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(DJTheme.statusWarning.opacity(0.12))
                .cornerRadius(DJTheme.controlRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: DJTheme.controlRadius)
                        .stroke(DJTheme.statusWarning.opacity(0.4), lineWidth: 1)
                )
            }

            HStack(spacing: 8) {
                routingStrip(
                    role: .master,
                    title: "Master (FOH)",
                    color: DJTheme.master,
                    selectedUID: appState.masterOutputUID,
                    descriptor: appState.masterDeviceDescriptor,
                    isFallback: appState.isMasterFallback,
                    warning: appState.masterWarning,
                    error: appState.masterRoutingError
                )

                routingStrip(
                    role: .cue,
                    title: "Headphones / Cue",
                    color: DJTheme.cue,
                    selectedUID: appState.cueOutputUID,
                    descriptor: appState.cueDeviceDescriptor,
                    isFallback: appState.isCueFallback,
                    warning: appState.cueWarning,
                    error: appState.cueRoutingError
                )

                // Levels sit next to the outputs they measure instead of on their own row.
                AudioMeterStatusView(appState: appState)

                Button(action: {
                    appState.refreshOutputDevices()
                }) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10))
                        .foregroundColor(DJTheme.textSecondary)
                        .padding(6)
                        .frame(minHeight: DJTheme.minTouchTarget)
                        .background(DJTheme.cardBackground)
                        .cornerRadius(DJTheme.controlRadius)
                        .overlay(
                            RoundedRectangle(cornerRadius: DJTheme.controlRadius)
                                .stroke(DJTheme.border.opacity(0.7), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(StudioPressableStyle())
                .help("Refresh connected audio output devices")
            }
        }
    }

    private func routingStrip(
        role: AudioEngineRole,
        title: String,
        color: Color,
        selectedUID: String?,
        descriptor: AudioDeviceDescriptor?,
        isFallback: Bool,
        warning: String?,
        error: String?
    ) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)

            Text(title)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundColor(color)
                .lineLimit(1)

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
                        Text(device.name)
                            .tag(device.id)
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .font(.system(size: 10, weight: .medium))
            .accentColor(color)

            if isFallback {
                Text("Fallback")
                    .font(.system(size: 8, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(DJTheme.cue.opacity(0.18))
                    .foregroundColor(DJTheme.cue)
                    .cornerRadius(DJTheme.chipRadius)
                    .overlay(
                        RoundedRectangle(cornerRadius: DJTheme.chipRadius)
                            .stroke(DJTheme.cue.opacity(0.8), lineWidth: 1)
                    )
            }

            if descriptor?.isBluetooth == true {
                Text("BT")
                    .font(.system(size: 8, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(DJTheme.textAccent.opacity(0.2))
                    .foregroundColor(DJTheme.textAccent)
                    .cornerRadius(DJTheme.chipRadius)
            }

            Spacer(minLength: 4)

            if let error {
                Text(error)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(Color.red)
                    .lineLimit(1)
            } else if let warning {
                Text(warning)
                    .font(.system(size: 8.5, weight: .regular))
                    .foregroundColor(DJTheme.textAccent)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(DJTheme.cardBackground)
        .cornerRadius(DJTheme.cardRadius)
        .overlay(
            RoundedRectangle(cornerRadius: DJTheme.cardRadius)
                .stroke(isFallback ? DJTheme.cue.opacity(0.5) : DJTheme.border.opacity(0.6), lineWidth: 1)
        )
    }
}
