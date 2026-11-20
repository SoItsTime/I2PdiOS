import SwiftUI

struct BrowserSettingsView: View {
    @EnvironmentObject private var settings: BrowserSettingsStore
    @EnvironmentObject private var router: RouterStore
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

            Section("Outproxy") {
                Toggle("Allow non-.i2p websites", isOn: $viewState.outproxyEnabled)
                Text("I2P HTTP outproxy address")
                    .font(.subheadline)
                TextField("http://outproxy.example.i2p:3128", text: $viewState.outproxyURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Save and apply outproxy") {
                    if settings.saveOutproxy(url: viewState.outproxyURL,
                                             enabled: viewState.outproxyEnabled) {
                        viewState.outproxyURL = settings.outproxyURL
                        viewState.outproxyError = nil
                        viewState.didSaveOutproxy = true
                        router.applyOutproxy(settings.activeOutproxyURL)
                    } else {
                        viewState.didSaveOutproxy = false
                        viewState.outproxyError = "Enter an http:// address ending in .i2p, with an optional port."
                    }
                }
                .buttonStyle(.bordered)
                .disabled(router.state == .starting || router.state == .stopping || router.outproxyApplying)
                LabeledContent("Non-.i2p websites", value: router.activeOutproxyURL == nil ? "Blocked" : "Allowed")
                if let error = viewState.outproxyError ?? router.outproxyError {
                    Text(error).foregroundStyle(.red).font(.footnote)
                } else if viewState.didSaveOutproxy {
                    Label(router.state != .running
                          ? "Outproxy settings saved for the next connection"
                          : router.activeOutproxyURL == settings.activeOutproxyURL
                            ? "Outproxy settings applied" : "Applying outproxy settings…",
                          systemImage: router.state == .running && router.activeOutproxyURL != settings.activeOutproxyURL
                            ? "hourglass" : "checkmark.circle.fill")
                        .foregroundStyle(router.state == .running && router.activeOutproxyURL != settings.activeOutproxyURL
                                         ? Color.secondary : Color.green)
                        .font(.footnote)
                }
                Text("Choose an I2P HTTP outproxy you trust. It can see which public sites you visit and unencrypted HTTP traffic. HTTPS protects page contents. Public sites stay blocked until this setting is enabled.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Browser settings")
        .toolbar(.visible, for: .navigationBar)
        .onAppear {
            viewState.outproxyURL = settings.outproxyURL
            viewState.outproxyEnabled = settings.outproxyEnabled
        }
    }
}

@MainActor
private final class BrowserSettingsViewState: ObservableObject {
    @Published var didApplyDefault = false
    @Published var outproxyURL = ""
    @Published var outproxyEnabled = false
    @Published var outproxyError: String?
    @Published var didSaveOutproxy = false
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
