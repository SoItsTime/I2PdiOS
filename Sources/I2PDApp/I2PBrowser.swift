import Network
import Foundation
import SwiftUI
import WebKit

@MainActor
final class I2PBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    private static let lastAddressKey = "lastI2PAddress"
    @Published var address = ""
    @Published private(set) var pageTitle = "I2P Browser"
    @Published private(set) var errorMessage: String?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false

    let webView: WKWebView
    private var observations: [NSKeyValueObservation] = []
    private var javaScriptEnabled = false

    override init() {
        let store = WKWebsiteDataStore.default()
        let endpoint = NWEndpoint.hostPort(
            host: .name("127.0.0.1", nil),
            port: NWEndpoint.Port(rawValue: 4447)!
        )
        var proxy = ProxyConfiguration(socksv5Proxy: endpoint)
        proxy.allowFailover = false
        store.proxyConfigurations = [proxy]

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        // Set the Android identity before WebKit can issue its first request.
        webView.customUserAgent = BrowserSettingsStore.defaultUserAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.updateDisplayedURL() }
            },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.updateDisplayedTitle() }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.updateNavigation() }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.updateNavigation() }
            }
        ]
        if let saved = UserDefaults.standard.string(forKey: Self.lastAddressKey),
           let url = URL(string: saved), isI2PURL(url) {
            address = saved
        }
    }

    func openAddress() {
        let entered = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entered.isEmpty else { return }
        let candidate = entered.contains("://") ? entered : "http://\(entered)"
        guard let url = URL(string: candidate), isI2PURL(url) else {
            errorMessage = "Enter a .i2p address. This browser does not open public Internet sites."
            return
        }
        errorMessage = nil
        webView.load(URLRequest(url: url))
    }

    func openExample() {
        address = "http://i2pd.i2p/"
        openAddress()
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func applySettings(userAgent: String, javaScriptEnabled: Bool, forceReload: Bool = false) {
        let changed = webView.customUserAgent != userAgent || self.javaScriptEnabled != javaScriptEnabled
        webView.customUserAgent = userAgent
        self.javaScriptEnabled = javaScriptEnabled
        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = javaScriptEnabled
        if (changed || forceReload) && webView.url != nil { webView.reload() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.allowsContentJavaScript = javaScriptEnabled
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel, preferences)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == false && url.absoluteString == "about:blank" {
            decisionHandler(.allow, preferences)
            return
        }
        guard isI2PURL(url) else {
            if navigationAction.targetFrame?.isMainFrame != false {
                errorMessage = "Blocked a link outside I2P."
            }
            decisionHandler(.cancel, preferences)
            return
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // i2pd.i2p and many other sites use target="_blank". Keep those links
        // inside this browser instead of silently discarding the new window.
        if navigationAction.targetFrame == nil,
           let url = navigationAction.request.url, isI2PURL(url) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        errorMessage = nil
        updateNavigation()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        updateDisplayedURL()
        updateDisplayedTitle()
        if let url = webView.url, isI2PURL(url) {
            UserDefaults.standard.set(url.absoluteString, forKey: Self.lastAddressKey)
        }
        updateNavigation()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        let networkError = error as NSError
        if networkError.domain == NSURLErrorDomain && networkError.code == NSURLErrorCancelled {
            // WebKit cancels the previous request when a new page replaces it.
            // Leave the new navigation's loading and error state alone.
            return
        }
        isLoading = false
        if networkError.domain == NSURLErrorDomain && networkError.code == NSURLErrorBadURL {
            errorMessage = "I2P could not resolve or connect to this address. Try the example site, or use a .b32.i2p address while the address book updates."
        } else {
            errorMessage = "Could not load the site. I2P may still be connecting, or the site may be offline. \(error.localizedDescription)"
        }
        updateNavigation()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let networkError = error as NSError
        if networkError.domain == NSURLErrorDomain && networkError.code == NSURLErrorCancelled {
            return
        }
        isLoading = false
        errorMessage = error.localizedDescription
        updateNavigation()
    }

    private func updateNavigation() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    private func updateDisplayedURL() {
        if let url = webView.url, isI2PURL(url) {
            address = url.absoluteString
        }
        updateNavigation()
    }

    private func updateDisplayedTitle() {
        let title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty {
            pageTitle = title
        } else {
            pageTitle = webView.url?.host ?? "I2P Browser"
        }
    }

    private func isI2PURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return host.hasSuffix(".i2p") && host.count > 4
    }
}

private struct I2PWebView: UIViewRepresentable {
    let browser: I2PBrowser

    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserView: View {
    @EnvironmentObject private var router: RouterStore
    @EnvironmentObject private var settings: BrowserSettingsStore
    @StateObject private var browser = I2PBrowser()

    var body: some View {
        VStack(spacing: 0) {
            if router.canBrowse {
                HStack {
                    TextField("i2pd.i2p", text: $browser.address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .onSubmit { browser.openAddress() }
                    Button("Go") { browser.openAddress() }
                        .buttonStyle(.borderedProminent)
                }
                .padding()

                if browser.isLoading { ProgressView().frame(maxWidth: .infinity) }
                if let error = browser.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }

                if browser.webView.url == nil {
                    Button("Try i2pd.i2p") { browser.openExample() }
                        .font(.footnote)
                        .padding(.bottom, 8)
                }

                I2PWebView(browser: browser)
                    .background(Color(uiColor: .systemBackground))

                HStack(spacing: 24) {
                    Button { browser.goBack() } label: { Image(systemName: "chevron.left") }
                        .disabled(!browser.canGoBack)
                    Button { browser.goForward() } label: { Image(systemName: "chevron.right") }
                        .disabled(!browser.canGoForward)
                    Spacer()
                    Button { browser.reload() } label: { Image(systemName: "arrow.clockwise") }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            } else {
                Spacer()
                if router.state == .starting || router.state == .running {
                    ProgressView()
                } else {
                    Image(systemName: "network.slash")
                        .foregroundStyle(.secondary)
                }
                Text(router.browserReadiness.label)
                    .font(.headline)
                    .padding(.top, 12)
                Text("Browsing will be available when I2P is ready.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                Spacer()
            }
        }
        .navigationTitle(browser.pageTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    BrowserSettingsView()
                } label: {
                    Image(systemName: "gearshape")
                        .accessibilityLabel("Browser settings")
                }
            }
        }
        .onAppear { applySettings() }
        .onChange(of: settings.userAgentRevision) { _, _ in
            applySettings(forceReload: true)
        }
        .onChange(of: settings.javaScriptEnabled) { _, _ in
            applySettings()
        }
        .onChange(of: router.canBrowse) { _, ready in
            if !ready { browser.webView.stopLoading() }
        }
    }

    private func applySettings(forceReload: Bool = false) {
        browser.applySettings(userAgent: settings.effectiveUserAgent,
                              javaScriptEnabled: settings.javaScriptEnabled,
                              forceReload: forceReload)
    }
}
