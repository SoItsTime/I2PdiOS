import SwiftUI

struct BrowserSettingsView: View {
    @EnvironmentObject private var settings: BrowserSettingsStore
    @StateObject private var viewState = BrowserSettingsViewState()

    var body: some View {
        Form {
            Section("User Agent") {
                LabeledContent("Selected", value: settings.usesDefaultUserAgent ? "Generic Android" : "Custom")
                NavigationLink("Edit User Agent") {
                    UserAgentEditorView()
                }
                Text(settings.effectiveUserAgent)
                    .font(.footnote)
                    .textSelection(.enabled)
                Button("Use generic Android default") {
                    settings.useDefaultUserAgent()
                    viewState.didApplyDefault = true
                }
                .buttonStyle(.bordered)
                if viewState.didApplyDefault && settings.usesDefaultUserAgent {
                    Label("Generic Android default saved and applied", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
                Text("Used by the I2P browser. Saving reloads an open page. This changes the identifier; the browser still uses WebKit.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("JavaScript") {
                Toggle("Allow JavaScript", isOn: $settings.javaScriptEnabled)
                Text("Off blocks page scripts. This setting applies to the I2P browser and the local i2pd console. Open pages reload when it changes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Browser settings")
    }
}

@MainActor
private final class BrowserSettingsViewState: ObservableObject {
    @Published var didApplyDefault = false
}

@MainActor
private final class UserAgentEditorModel: ObservableObject {
    @Published var draft = ""
}

private struct UserAgentEditorView: View {
    @EnvironmentObject private var settings: BrowserSettingsStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var editor = UserAgentEditorModel()

    var body: some View {
        Form {
            Section("Custom User Agent") {
                TextEditor(text: $editor.draft)
                    .frame(minHeight: 130)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save User Agent") { save() }
                    .buttonStyle(.borderedProminent)
                Button("Use generic Android default") {
                    settings.useDefaultUserAgent()
                    dismiss()
                }
                Text("An empty value uses the generic Android default.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Edit User Agent")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
            }
        }
        .onAppear { editor.draft = settings.userAgent }
    }

    private func save() {
        settings.saveUserAgent(editor.draft)
        dismiss()
    }
}
