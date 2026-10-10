import ActivityKit
import Foundation

@MainActor
final class ShutdownLiveActivity {
    private var activity: Activity<ShutdownActivityAttributes>?

    func start(at startedAt: Date, deadline: Date, peers: Int, transitTunnels: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = ShutdownActivityAttributes(startedAt: startedAt)
        let state = ShutdownActivityAttributes.ContentState(
            deadline: deadline,
            connectedPeers: peers,
            transitTunnels: transitTunnels
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: deadline),
                pushType: nil
            )
        } catch {
            NSLog("Could not show disconnect Live Activity: %@", error.localizedDescription)
        }
    }

    func update(deadline: Date, peers: Int, transitTunnels: Int) {
        guard let activity else { return }
        let state = ShutdownActivityAttributes.ContentState(
            deadline: deadline,
            connectedPeers: peers,
            transitTunnels: transitTunnels
        )
        Task {
            await activity.update(ActivityContent(state: state, staleDate: deadline))
        }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    func endActivitiesLeftByAnEarlierLaunch() {
        Task {
            for activity in Activity<ShutdownActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
