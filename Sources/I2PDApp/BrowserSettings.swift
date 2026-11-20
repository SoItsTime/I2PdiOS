import Combine
import Foundation

@MainActor
final class BrowserSettingsStore: ObservableObject {
    static let defaultUserAgent = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Mobile Safari/537.36"
    private static let userAgentKey = "browserUserAgent"
    private static let javaScriptKey = "browserJavaScriptEnabled"
    private static let outproxyURLKey = "browserOutproxyURL"
    private static let outproxyEnabledKey = "browserOutproxyEnabled"

    @Published var userAgent: String {
        didSet { UserDefaults.standard.set(userAgent, forKey: Self.userAgentKey) }
    }
    @Published private(set) var userAgentRevision = 0
    @Published var javaScriptEnabled: Bool {
        didSet { UserDefaults.standard.set(javaScriptEnabled, forKey: Self.javaScriptKey) }
    }
    @Published private(set) var outproxyURL: String
    @Published private(set) var outproxyEnabled: Bool

    init() {
        userAgent = UserDefaults.standard.string(forKey: Self.userAgentKey) ?? Self.defaultUserAgent
        javaScriptEnabled = UserDefaults.standard.bool(forKey: Self.javaScriptKey)
        outproxyURL = UserDefaults.standard.string(forKey: Self.outproxyURLKey) ?? ""
        outproxyEnabled = UserDefaults.standard.bool(forKey: Self.outproxyEnabledKey)
    }

    var effectiveUserAgent: String {
        let oneLine = userAgent
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.isEmpty ? Self.defaultUserAgent : oneLine
    }

    var usesDefaultUserAgent: Bool {
        effectiveUserAgent == Self.defaultUserAgent
    }

    func useDefaultUserAgent() {
        saveUserAgent(Self.defaultUserAgent)
    }

    func saveUserAgent(_ value: String) {
        let oneLine = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        userAgent = oneLine.isEmpty ? Self.defaultUserAgent : oneLine
        userAgentRevision += 1
    }

    var activeOutproxyURL: String? {
        guard outproxyEnabled else { return nil }
        return Self.normalizedOutproxyURL(outproxyURL)
    }

    func saveOutproxy(url: String, enabled: Bool) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if enabled {
            guard let normalized = Self.normalizedOutproxyURL(trimmed) else { return false }
            outproxyURL = normalized
        } else if trimmed.isEmpty {
            outproxyURL = ""
        } else if let normalized = Self.normalizedOutproxyURL(trimmed) {
            outproxyURL = normalized
        }
        outproxyEnabled = enabled
        UserDefaults.standard.set(outproxyURL, forKey: Self.outproxyURLKey)
        UserDefaults.standard.set(enabled, forKey: Self.outproxyEnabledKey)
        return true
    }

    func setAllowPublicWebsites(_ allowed: Bool) -> Bool {
        saveOutproxy(url: outproxyURL, enabled: allowed)
    }

    static func normalizedOutproxyURL(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 512, value.hasPrefix("http://") else { return nil }
        var authority = String(value.dropFirst(7))
        if authority.hasSuffix("/") { authority.removeLast() }
        guard !authority.isEmpty,
              !authority.contains(where: { "/?#@\\ \t\r\n".contains($0) }) else { return nil }
        let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        let host = parts[0].lowercased()
        guard host.count > 4, host.hasSuffix(".i2p"), !host.hasPrefix("."),
              !host.contains(".."),
              host.range(of: "^[a-z0-9.-]+$", options: .regularExpression) != nil else { return nil }
        if parts.count == 2 {
            let portText = String(parts[1])
            guard portText.count <= 5, !portText.isEmpty,
                  portText.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let port = Int(portText), (1...65535).contains(port) else { return nil }
            return "http://\(host):\(port)"
        }
        return "http://\(host)"
    }
}
