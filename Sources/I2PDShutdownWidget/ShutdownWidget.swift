import ActivityKit
import SwiftUI
import WidgetKit

@main
struct I2PDShutdownWidgetBundle: WidgetBundle {
    var body: some Widget {
        ShutdownWidget()
    }
}

private struct ShutdownWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ShutdownActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "network.slash")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading) {
                    Text("Disconnecting i2pd")
                        .font(.headline)
                    Text("Connected peers: \(context.state.connectedPeers)")
                        .font(.caption)
                }
                Spacer(minLength: 4)
                Text(timerInterval: context.attributes.startedAt...context.state.deadline,
                     countsDown: true, showsHours: false)
                    .monospacedDigit()
            }
            .padding()
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    HStack(spacing: 6) {
                        Image(systemName: "network.slash")
                        Text("i2pd")
                        Spacer(minLength: 4)
                        Text(timerInterval: context.attributes.startedAt...context.state.deadline,
                             countsDown: true, showsHours: false)
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                }
            } compactLeading: {
                Image(systemName: "network.slash")
                    .font(.system(size: 12, weight: .medium))
            } compactTrailing: {
                Text(timerInterval: context.attributes.startedAt...context.state.deadline,
                     countsDown: true, showsHours: false)
                    .monospacedDigit()
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: 36)
            } minimal: {
                Image(systemName: "network.slash")
                    .font(.system(size: 12, weight: .medium))
            }
        }
    }
}
