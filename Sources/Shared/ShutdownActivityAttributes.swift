import ActivityKit
import Foundation

struct ShutdownActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var deadline: Date
        var connectedPeers: Int
        var transitTunnels: Int
    }

    var startedAt: Date
}
