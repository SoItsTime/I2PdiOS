import Combine
import SwiftUI
import WebKit

@MainActor
private final class I2PDConsoleModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    let webView: WKWebView
    private let consoleURL: URL
    private var javaScriptEnabled = false
    private var userAgent = BrowserSettingsStore.defaultUserAgent

    init(page: String? = nil) {
        let allowedPages: Set<String> = [
            "commands", "local_destinations", "leasesets", "tunnels",
            "transit_tunnels", "transports", "i2p_tunnels", "sam_sessions"
        ]
        if let page, allowedPages.contains(page) {
            consoleURL = URL(string: "http://127.0.0.1:7070/?page=\(page)")!
        } else {
            consoleURL = URL(string: "http://127.0.0.1:7070/")!
        }
        let configuration = WKWebViewConfiguration()
        // The I2P browser's persistent store has a SOCKS proxy. The local
        // console uses its own store so requests go directly to loopback.
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.customUserAgent = userAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        reload()
    }

    func reload() { webView.load(URLRequest(url: consoleURL)) }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func applyJavaScript(_ enabled: Bool) {
        guard javaScriptEnabled != enabled else { return }
        javaScriptEnabled = enabled
        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = enabled
        if webView.url != nil { webView.reload() }
    }

    func applyUserAgent(_ value: String) {
        guard userAgent != value else { return }
        userAgent = value
        webView.customUserAgent = value
        if webView.url != nil { webView.reload() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.allowsContentJavaScript = javaScriptEnabled
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel, preferences)
            return
        }
        if url.absoluteString == "about:blank" || isConsoleURL(url) {
            decisionHandler(.allow, preferences)
        } else {
            errorMessage = "The web console only opens its local pages. Use the I2P browser for .i2p sites."
            decisionHandler(.cancel, preferences)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil,
           let url = navigationAction.request.url, isConsoleURL(url) {
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
        updateNavigation()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        showFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showFailure(error)
    }

    private func showFailure(_ error: Error) {
        let networkError = error as NSError
        if networkError.domain == NSURLErrorDomain && networkError.code == NSURLErrorCancelled {
            return
        }
        isLoading = false
        errorMessage = "Could not load the i2pd console. \(error.localizedDescription)"
        updateNavigation()
    }

    private func updateNavigation() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    private func isConsoleURL(_ url: URL) -> Bool {
        url.scheme == "http" && url.host == "127.0.0.1" && url.port == 7070
    }
}

private struct I2PDConsoleWebView: UIViewRepresentable {
    let model: I2PDConsoleModel

    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct I2PDConsoleView: View {
    @EnvironmentObject private var settings: BrowserSettingsStore
    @StateObject private var model: I2PDConsoleModel

    init(page: String? = nil) {
        _model = StateObject(wrappedValue: I2PDConsoleModel(page: page))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            I2PDConsoleWebView(model: model)
        }
        .navigationTitle("i2pd web console")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Back", systemImage: "chevron.left") { model.goBack() }
                    .disabled(!model.canGoBack)
                Button("Forward", systemImage: "chevron.right") { model.goForward() }
                    .disabled(!model.canGoForward)
                Spacer()
                Button("Reload", systemImage: "arrow.clockwise") { model.reload() }
            }
        }
        .onAppear {
            model.applyJavaScript(settings.javaScriptEnabled)
            model.applyUserAgent(settings.effectiveUserAgent)
        }
        .onChange(of: settings.javaScriptEnabled) { _, enabled in
            model.applyJavaScript(enabled)
        }
        .onChange(of: settings.userAgentRevision) { _, _ in
            model.applyUserAgent(settings.effectiveUserAgent)
        }
    }
}
