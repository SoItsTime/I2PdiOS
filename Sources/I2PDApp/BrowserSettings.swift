import Combine
import Foundation

@MainActor
final class BrowserSettingsStore: ObservableObject {
    static let defaultUserAgent = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Mobile Safari/537.36"
    private static let userAgentKey = "browserUserAgent"
    private static let javaScriptKey = "browserJavaScriptEnabled"

    @Published var userAgent: String {
        didSet { UserDefaults.standard.set(userAgent, forKey: Self.userAgentKey) }
    }
    @Published private(set) var userAgentRevision = 0
    @Published var javaScriptEnabled: Bool {
        didSet { UserDefaults.standard.set(javaScriptEnabled, forKey: Self.javaScriptKey) }
    }

    init() {
        userAgent = UserDefaults.standard.string(forKey: Self.userAgentKey) ?? Self.defaultUserAgent
        javaScriptEnabled = UserDefaults.standard.bool(forKey: Self.javaScriptKey)
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
}
