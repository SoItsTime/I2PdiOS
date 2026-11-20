import Network
import Foundation
import SwiftUI
import WebKit

@MainActor
final class I2PBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    private static let lastAddressKey = "lastI2PAddress"
    private static let outproxyStoreID = UUID(uuidString: "8D32C7F7-C24E-4452-A92C-CF70CE8427F3")!
    let id = UUID()
    var downloads: BrowserDownloads?
    var onCreateNewTab: ((WKWebViewConfiguration, URLRequest) -> WKWebView?)?
    var onNavigationChanged: (() -> Void)?
    @Published var address = ""
    @Published private(set) var pageTitle = "I2P Browser"
    @Published private(set) var errorMessage: String?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var pageProgress = 0.0

    @Published private(set) var webView: WKWebView
    private var observations: [NSKeyValueObservation] = []
    private var javaScriptEnabled = false
    private var activeOutproxyURL: String?
    private var pendingRestoreURL: URL?

    init(configuration: WKWebViewConfiguration? = nil, outproxyURL: String? = nil) {
        activeOutproxyURL = outproxyURL
        webView = configuration.map { WKWebView(frame: .zero, configuration: $0) }
            ?? Self.makeWebView(outproxyEnabled: outproxyURL != nil)
        super.init()
        configureWebView()
        if let saved = UserDefaults.standard.string(forKey: Self.lastAddressKey),
           let url = URL(string: saved), isI2PURL(url) {
            address = saved
        }
    }

    private static func makeWebView(outproxyEnabled: Bool) -> WKWebView {
        let store = outproxyEnabled
            ? WKWebsiteDataStore(forIdentifier: outproxyStoreID)
            : WKWebsiteDataStore.default()
        let endpoint = NWEndpoint.hostPort(
            host: .name("127.0.0.1", nil),
            port: NWEndpoint.Port(rawValue: outproxyEnabled ? 4444 : 4447)!
        )
        var proxy = outproxyEnabled
            ? ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
            : ProxyConfiguration(socksv5Proxy: endpoint)
        proxy.allowFailover = false
        store.proxyConfigurations = [proxy]

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func configureWebView() {
        // Set the Android identity before WebKit can issue its first request.
        if webView.customUserAgent == nil {
            webView.customUserAgent = BrowserSettingsStore.defaultUserAgent
        }
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
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] observed, _ in
                Task { @MainActor [weak self] in self?.updatePageProgress(for: observed) }
            }
        ]
    }

    func setOutproxyURL(_ url: String?, reloadPage: Bool = true) {
        guard activeOutproxyURL != url else { return }
        let enabled = url != nil
        let previousURL = webView.url
        let previousAddress = address
        let previousUserAgent = webView.customUserAgent
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        observations.removeAll()
        activeOutproxyURL = url
        webView = Self.makeWebView(outproxyEnabled: enabled)
        webView.customUserAgent = previousUserAgent
        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = javaScriptEnabled
        configureWebView()
        isLoading = false
        pageProgress = 0
        canGoBack = false
        canGoForward = false
        errorMessage = nil
        if let previousURL {
            address = previousURL.absoluteString
            pageTitle = previousURL.host ?? "New tab"
            if reloadPage && isAllowedURL(previousURL) {
                pendingRestoreURL = nil
                webView.load(URLRequest(url: previousURL))
            } else {
                pendingRestoreURL = previousURL
            }
        } else if let pendingRestoreURL {
            address = pendingRestoreURL.absoluteString
            pageTitle = pendingRestoreURL.host ?? "New tab"
        } else if let typedURL = URL(string: previousAddress), isAllowedURL(typedURL) {
            address = previousAddress
        } else {
            address = ""
            pageTitle = "New tab"
        }
    }

    func prepareAsNewTab() {
        address = ""
        pageTitle = "New tab"
        pendingRestoreURL = nil
    }

    func restoreURL(_ value: String) {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return }
        address = url.absoluteString
        pageTitle = host
        pendingRestoreURL = url
    }

    func activate() {
        guard let pendingRestoreURL, isAllowedURL(pendingRestoreURL) else { return }
        self.pendingRestoreURL = nil
        webView.load(URLRequest(url: pendingRestoreURL))
    }

    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        observations.removeAll()
        onCreateNewTab = nil
        onNavigationChanged = nil
    }

    func load(_ request: URLRequest) {
        if let url = request.url, url.scheme?.lowercased() == "magnet" {
            openMagnet(url.absoluteString)
            return
        }
        guard let url = request.url, isAllowedURL(url) else {
            errorMessage = "Enter a .i2p address, or enable an outproxy for public websites."
            return
        }
        address = url.absoluteString
        errorMessage = nil
        pendingRestoreURL = nil
        webView.load(request)
    }

    func openAddress() {
        let entered = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entered.isEmpty else { return }
        if entered.lowercased().hasPrefix("magnet:?") {
            openMagnet(entered)
            return
        }
        let candidate = entered.contains("://") ? entered : "http://\(entered)"
        guard let url = URL(string: candidate), isAllowedURL(url) else {
            errorMessage = "Enter a .i2p address, or enable a configured outproxy for public websites."
            return
        }
        load(URLRequest(url: url))
    }

    func openExample() {
        address = "http://i2pd.i2p/"
        openAddress()
    }

    private func openMagnet(_ value: String) {
        downloads?.addMagnet("magnet:?" + value.dropFirst("magnet:?".count))
        address = webView.url?.absoluteString ?? ""
        errorMessage = nil
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stopLoading() {
        webView.stopLoading()
        isLoading = false
        pageProgress = 0
    }
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
        if url.scheme?.lowercased() == "magnet" {
            openMagnet(url.absoluteString)
            decisionHandler(.cancel, preferences)
            return
        }
        if navigationAction.shouldPerformDownload,
           let scheme = url.scheme?.lowercased(), scheme == "blob" || scheme == "data",
           let sourceURL = navigationAction.sourceFrame.request.url,
           isAllowedURL(sourceURL) {
            decisionHandler(.download, preferences)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == false && url.absoluteString == "about:blank" {
            decisionHandler(.allow, preferences)
            return
        }
        guard isAllowedURL(url) else {
            if navigationAction.targetFrame?.isMainFrame != false {
                errorMessage = "Blocked this address. Public websites require an enabled outproxy."
            }
            decisionHandler(.cancel, preferences)
            return
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.isForMainFrame else {
            decisionHandler(.allow)
            return
        }
        let response = navigationResponse.response
        let filename = response.suggestedFilename?.lowercased() ?? ""
        let mime = response.mimeType?.lowercased() ?? ""
        let disposition = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        let isTorrent = filename.hasSuffix(".torrent") ||
            response.url?.pathExtension.lowercased() == "torrent" ||
            mime == "application/x-bittorrent" || mime == "application/x-torrent"
        let isAttachment = disposition.trimmingCharacters(in: .whitespaces).hasPrefix("attachment")
        decisionHandler(isTorrent || isAttachment || !navigationResponse.canShowMIMEType
                        ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        downloads?.register(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        downloads?.register(download)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // WebKit loads the request in the returned view. This preserves the
        // original navigation, including forms and WebKit's request context.
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url, isAllowedURL(url) else {
            return nil
        }
        return onCreateNewTab?(configuration, navigationAction.request)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        pageProgress = max(0.01, min(webView.estimatedProgress, 1))
        errorMessage = nil
        updateNavigation()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageProgress = 1
        isLoading = false
        updateDisplayedURL()
        updateDisplayedTitle()
        if let url = webView.url, isAllowedURL(url) {
            UserDefaults.standard.set(url.absoluteString, forKey: Self.lastAddressKey)
        }
        onNavigationChanged?()
        updateNavigation()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        let networkError = error as NSError
        if networkError.domain == NSURLErrorDomain && networkError.code == NSURLErrorCancelled {
            // WebKit cancels the previous request when a new page replaces it.
            // Leave the new navigation's loading and error state alone.
            if !webView.isLoading {
                isLoading = false
                pageProgress = 0
            }
            return
        }
        isLoading = false
        pageProgress = 0
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
            if !webView.isLoading {
                isLoading = false
                pageProgress = 0
            }
            return
        }
        isLoading = false
        pageProgress = 0
        errorMessage = error.localizedDescription
        updateNavigation()
    }

    private func updateNavigation() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    private func updatePageProgress(for observed: WKWebView) {
        guard observed === webView, isLoading else { return }
        pageProgress = min(max(observed.estimatedProgress, 0.01), 1)
    }

    private func updateDisplayedURL() {
        if let url = webView.url, isAllowedURL(url) {
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

    private func isAllowedURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        if isI2PURL(url) { return true }
        guard activeOutproxyURL != nil, host.contains("."),
              host != "localhost", !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"),
              IPv4Address(host) == nil, IPv6Address(host) == nil else { return false }
        return true
    }
}

@MainActor
final class BrowserTabsStore: ObservableObject {
    static let maximumTabs = 12
    let downloads = BrowserDownloads()
    private static let savedTabsKey = "browserTabAddresses"
    private static let selectedIndexKey = "browserSelectedTabIndex"
    @Published private(set) var tabs: [I2PBrowser]
    @Published private(set) var selectedID: UUID

    private var activeOutproxyURL: String?
    private var userAgent = BrowserSettingsStore.defaultUserAgent
    private var javaScriptEnabled = false

    init() {
        let saved = Array((UserDefaults.standard.stringArray(forKey: Self.savedTabsKey) ?? [])
            .prefix(Self.maximumTabs))
        let restoredTabs: [I2PBrowser]
        if saved.isEmpty {
            restoredTabs = [I2PBrowser()]
        } else {
            restoredTabs = saved.map { value in
                let tab = I2PBrowser()
                tab.prepareAsNewTab()
                tab.restoreURL(value)
                return tab
            }
        }
        tabs = restoredTabs
        let savedIndex = UserDefaults.standard.integer(forKey: Self.selectedIndexKey)
        selectedID = restoredTabs[min(max(savedIndex, 0), restoredTabs.count - 1)].id
        for tab in restoredTabs { attachCallbacks(to: tab) }
    }

    var selectedTab: I2PBrowser {
        tabs.first(where: { $0.id == selectedID }) ?? tabs[0]
    }

    func configure(outproxyURL: String?, userAgent: String,
                   javaScriptEnabled: Bool, forceReload: Bool = false) {
        activeOutproxyURL = outproxyURL
        self.userAgent = userAgent
        self.javaScriptEnabled = javaScriptEnabled
        for tab in tabs {
            tab.setOutproxyURL(outproxyURL, reloadPage: tab.id == selectedID)
            tab.applySettings(userAgent: userAgent, javaScriptEnabled: javaScriptEnabled,
                              forceReload: forceReload)
        }
    }

    func newTab(open request: URLRequest? = nil) {
        guard tabs.count < Self.maximumTabs else {
            if let request { selectedTab.load(request) }
            return
        }
        let tab = I2PBrowser()
        tab.setOutproxyURL(activeOutproxyURL)
        tab.applySettings(userAgent: userAgent, javaScriptEnabled: javaScriptEnabled)
        tab.prepareAsNewTab()
        attachCallbacks(to: tab)
        tabs.append(tab)
        selectedID = tab.id
        if let request { tab.load(request) }
        saveTabs()
    }

    func createNewTab(configuration: WKWebViewConfiguration,
                      request: URLRequest) -> WKWebView? {
        guard tabs.count < Self.maximumTabs else {
            // At the tab limit, open the link in the current tab.
            selectedTab.load(request)
            return nil
        }
        let tab = I2PBrowser(configuration: configuration, outproxyURL: activeOutproxyURL)
        tab.applySettings(userAgent: userAgent, javaScriptEnabled: javaScriptEnabled)
        tab.prepareAsNewTab()
        tab.address = request.url?.absoluteString ?? ""
        attachCallbacks(to: tab)
        tabs.append(tab)
        let newID = tab.id
        // Do not remove the source WKWebView while WebKit is still asking it
        // to create a window; the destination view is retained by tabs.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.tabs.contains(where: { $0.id == newID }) else { return }
            self.selectedID = newID
            self.saveTabs()
        }
        return tab.webView
    }

    func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
        saveTabs()
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let oldTab = tabs[index]
        if tabs.count == 1 {
            let replacement = I2PBrowser()
            replacement.setOutproxyURL(activeOutproxyURL)
            replacement.applySettings(userAgent: userAgent, javaScriptEnabled: javaScriptEnabled)
            replacement.prepareAsNewTab()
            attachCallbacks(to: replacement)
            tabs = [replacement]
            selectedID = replacement.id
        } else {
            tabs.remove(at: index)
            if selectedID == id { selectedID = tabs[min(index, tabs.count - 1)].id }
        }
        oldTab.close()
        saveTabs()
    }

    func activateSelectedTab() { selectedTab.activate() }

    func stopAllLoading() {
        for tab in tabs { tab.stopLoading() }
    }

    private func attachCallbacks(to tab: I2PBrowser) {
        tab.downloads = downloads
        tab.onCreateNewTab = { [weak self] configuration, request in
            self?.createNewTab(configuration: configuration, request: request)
        }
        tab.onNavigationChanged = { [weak self] in self?.saveTabs() }
    }

    private func saveTabs() {
        UserDefaults.standard.set(tabs.map { $0.webView.url?.absoluteString ?? $0.address },
                                  forKey: Self.savedTabsKey)
        UserDefaults.standard.set(tabs.firstIndex(where: { $0.id == selectedID }) ?? 0,
                                  forKey: Self.selectedIndexKey)
    }
}

private struct I2PWebView: UIViewRepresentable {
    let browser: I2PBrowser

    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

private struct BrowserTabChip: View {
    @ObservedObject var browser: I2PBrowser
    let selected: Bool
    let width: CGFloat
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: select) {
                Text(browser.pageTitle)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch to \(browser.pageTitle)")
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.caption2.bold())
                    .frame(width: 24, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(browser.pageTitle)")
        }
        .font(.caption)
        .frame(width: width)
        .padding(.leading, 10)
        .padding(.trailing, 3)
        .background(RoundedRectangle(cornerRadius: 9)
            .fill(selected ? Color(uiColor: .systemBackground) : Color(uiColor: .tertiarySystemFill)))
    }
}

struct BrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject private var router: RouterStore
    @EnvironmentObject private var settings: BrowserSettingsStore
    @EnvironmentObject private var tabs: BrowserTabsStore

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if usesSidebar {
                    sidebar(width: min(220, max(155, geometry.size.width * 0.22)))
                    Divider()
                }
                VStack(spacing: 0) {
                    if !usesSidebar { tabStrip }
                    browserContent(showsBottomControls: !usesSidebar)
                    BrowserDownloadsTray(downloads: tabs.downloads)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            applySettings()
            if router.canBrowse { tabs.activateSelectedTab() }
        }
        .onChange(of: settings.userAgentRevision) { _, _ in applySettings(forceReload: true) }
        .onChange(of: settings.javaScriptEnabled) { _, _ in applySettings() }
        .onChange(of: router.activeOutproxyURL) { _, _ in
            applySettings()
            if router.canBrowse { tabs.activateSelectedTab() }
        }
        .onChange(of: tabs.selectedID) { _, _ in
            if router.canBrowse { tabs.activateSelectedTab() }
        }
        .onChange(of: router.canBrowse) { _, ready in
            if ready { tabs.activateSelectedTab() }
            else if router.state != .running { tabs.stopAllLoading() }
        }
        .onChange(of: router.state) { _, state in
            if state != .running { tabs.stopAllLoading() }
        }
    }

    private var usesSidebar: Bool {
        horizontalSizeClass == .regular || verticalSizeClass == .compact
    }

    @ViewBuilder
    private func browserContent(showsBottomControls: Bool) -> some View {
        if router.state == .running {
            BrowserTabPage(browser: tabs.selectedTab,
                           showsBottomControls: showsBottomControls)
                .id(tabs.selectedID)
        } else {
            VStack(spacing: 0) {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sidebar(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Label("i2pd", systemImage: "chevron.left")
                }
                .accessibilityLabel("Back to i2pd")
                Spacer(minLength: 0)
                Button { tabs.newTab() } label: {
                    Image(systemName: "plus")
                }
                .disabled(!router.canBrowse || tabs.tabs.count >= BrowserTabsStore.maximumTabs)
                .accessibilityLabel("New tab")
            }
            .font(.subheadline)
            .padding(10)
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(tabs.tabs, id: \.id) { tab in
                            BrowserTabChip(browser: tab, selected: tab.id == tabs.selectedID,
                                           width: width - 26,
                                           select: { tabs.selectTab(tab.id) },
                                           close: { tabs.closeTab(tab.id) })
                                .id(tab.id)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .onAppear { scrollProxy.scrollTo(tabs.selectedID, anchor: .center) }
                .onChange(of: tabs.selectedID) { _, id in
                    scrollProxy.scrollTo(id, anchor: .center)
                }
            }
            if router.canBrowse {
                Divider()
                BrowserNavigationControls(browser: tabs.selectedTab, vertical: true)
                    .id(tabs.selectedID)
            }
        }
        .frame(width: width)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var tabStrip: some View {
        ScrollViewReader { scrollProxy in
            HStack(spacing: 6) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 32, height: 36)
                }
                .accessibilityLabel("Back to i2pd")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 5) {
                        ForEach(tabs.tabs, id: \.id) { tab in
                            BrowserTabChip(browser: tab, selected: tab.id == tabs.selectedID,
                                           width: 132,
                                           select: { tabs.selectTab(tab.id) },
                                           close: { tabs.closeTab(tab.id) })
                                .id(tab.id)
                        }
                    }
                }
                Button { tabs.newTab() } label: {
                    Image(systemName: "plus")
                        .frame(width: 32, height: 36)
                }
                .disabled(!router.canBrowse || tabs.tabs.count >= BrowserTabsStore.maximumTabs)
                .accessibilityLabel("New tab")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .frame(height: 44)
            .background(Color(uiColor: .secondarySystemBackground))
            .onAppear { scrollProxy.scrollTo(tabs.selectedID, anchor: .center) }
            .onChange(of: tabs.selectedID) { _, id in
                scrollProxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private func applySettings(forceReload: Bool = false) {
        tabs.configure(outproxyURL: router.activeOutproxyURL,
                       userAgent: settings.effectiveUserAgent,
                       javaScriptEnabled: settings.javaScriptEnabled,
                       forceReload: forceReload)
    }
}

private struct BrowserTabPage: View {
    @ObservedObject var browser: I2PBrowser
    @EnvironmentObject private var router: RouterStore
    let showsBottomControls: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField(router.activeOutproxyURL == nil ? "i2pd.i2p" : "Website address", text: $browser.address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit { browser.openAddress() }
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
                Button { browser.openAddress() } label: {
                    Image(systemName: "arrow.right")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Go to address")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)

            if browser.isLoading {
                ProgressView(value: browser.pageProgress, total: 1)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(height: 3)
                    .accessibilityLabel("Page loading progress")
                    .accessibilityValue("\(Int(browser.pageProgress * 100)) percent")
            }
            if !router.canBrowse {
                Text(router.browserReadiness.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            }
            if let error = browser.errorMessage ?? router.outproxyError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }

            ZStack {
                I2PWebView(browser: browser)
                    .id(ObjectIdentifier(browser.webView))
                if browser.webView.url == nil && !browser.isLoading {
                    VStack(spacing: 12) {
                        Image(systemName: "globe")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Enter an I2P address")
                            .foregroundStyle(.secondary)
                        Button("Try i2pd.i2p") { browser.openExample() }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))

            if showsBottomControls {
                Divider()
                BrowserNavigationControls(browser: browser, vertical: false)
            }
        }
    }
}

private struct BrowserNavigationControls: View {
    @ObservedObject var browser: I2PBrowser
    @EnvironmentObject private var router: RouterStore
    @EnvironmentObject private var settings: BrowserSettingsStore
    let vertical: Bool

    var body: some View {
        Group {
            if vertical {
                VStack(alignment: .leading, spacing: 4) {
                    backButton.frame(maxWidth: .infinity, alignment: .leading)
                    forwardButton.frame(maxWidth: .infinity, alignment: .leading)
                    reloadButton.frame(maxWidth: .infinity, alignment: .leading)
                    siteMenu.frame(maxWidth: .infinity, alignment: .leading)
                    settingsLink.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
            } else {
                HStack(spacing: 12) {
                    backButton.labelStyle(.iconOnly)
                    forwardButton.labelStyle(.iconOnly)
                    reloadButton.labelStyle(.iconOnly)
                    Spacer(minLength: 0)
                    siteMenu
                    settingsLink.labelStyle(.iconOnly)
                }
                .padding(.horizontal, 10)
            }
        }
        .buttonStyle(.plain)
    }

    private var backButton: some View {
        Button { browser.goBack() } label: {
            Label("Back", systemImage: "chevron.left")
                .frame(minWidth: 36, minHeight: 40, alignment: .leading)
        }
        .disabled(!browser.canGoBack)
    }

    private var forwardButton: some View {
        Button { browser.goForward() } label: {
            Label("Forward", systemImage: "chevron.right")
                .frame(minWidth: 36, minHeight: 40, alignment: .leading)
        }
        .disabled(!browser.canGoForward)
    }

    private var reloadButton: some View {
        Button { browser.reload() } label: {
            Label("Reload", systemImage: "arrow.clockwise")
                .frame(minWidth: 36, minHeight: 40, alignment: .leading)
        }
    }

    private var siteMenu: some View {
        Menu {
            Button(settings.outproxyEnabled ? "Block non-.i2p websites" : "Allow non-.i2p websites",
                   systemImage: settings.outproxyEnabled ? "lock.fill" : "globe") {
                if settings.setAllowPublicWebsites(!settings.outproxyEnabled) {
                    router.applyOutproxy(settings.activeOutproxyURL)
                }
            }
            .disabled(router.outproxyApplying ||
                      BrowserSettingsStore.normalizedOutproxyURL(settings.outproxyURL) == nil)
            if let outproxy = router.activeOutproxyURL {
                Text("Using \(outproxy)")
            } else {
                Text("I2P sites only. Configure an outproxy in settings.")
            }
        } label: {
            Label(router.activeOutproxyURL == nil ? "I2P only" : "Outproxy", systemImage: "network")
                .font(.caption)
                .frame(minHeight: 40)
        }
        .accessibilityLabel("Website access")
    }

    private var settingsLink: some View {
        NavigationLink {
            BrowserSettingsView()
        } label: {
            Label("Settings", systemImage: "gearshape")
                .frame(minWidth: 36, minHeight: 40, alignment: .leading)
        }
        .accessibilityLabel("Browser settings")
    }
}
