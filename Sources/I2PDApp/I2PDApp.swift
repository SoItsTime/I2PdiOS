import SwiftUI

@main
struct I2PDApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var router = RouterStore()
    @StateObject private var browserSettings = BrowserSettingsStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(router)
                .environmentObject(browserSettings)
                .onChange(of: scenePhase) { _, phase in
                    router.setAwayFromForeground(phase != .active)
                }
        }
    }
}
