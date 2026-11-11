import SwiftUI
import PulseDeckCore

/// PulseDeck AI › Settings… (⌘,). Only what a new user on another Mac needs to set once.
struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        TabView {
            GeneralSettings(appState: appState)
                .tabItem { Label("General", systemImage: "gearshape") }
            AISettings()
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 480)
        .padding(20)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            LabeledContent("Music library") {
                VStack(alignment: .trailing, spacing: 6) {
                    Text(appState.resolvedLibraryRootURL?.path(percentEncoded: false) ?? "Not chosen")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("Choose…") { appState.openLibrary() }
                        .disabled(!appState.canOpenLibrary)
                }
            }
            Toggle("Auto Gain", isOn: $appState.isAutoGainEnabled)
            Text("Levels every track to about -14 LUFS so no song is suddenly louder or quieter.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct AISettings: View {
    private let keychain = GeminiKeychain()
    @State private var draft = ""
    @State private var hasKey = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                if hasKey {
                    LabeledContent("Gemini API key") {
                        HStack {
                            Label("Saved in Keychain", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Button("Remove", role: .destructive) {
                                if keychain.delete() { hasKey = false; message = nil }
                            }
                        }
                    }
                } else {
                    SecureField("Gemini API key", text: $draft)
                        .onSubmit(save)
                    HStack {
                        Link("Get a free key in Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
                            .font(.caption)
                        Spacer()
                        Button("Save", action: save)
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("Optional. Without a key everything works offline. With one, PulseDeck can ask Gemini about track names, BPM and key; audio never leaves this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { hasKey = keychain.hasKey }
    }

    private func save() {
        if keychain.save(draft) {
            draft = ""
            hasKey = true
            message = nil
        } else {
            message = "Could not save the key to the Keychain."
        }
    }
}
