import SwiftUI

@main
struct I2PDApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var router = RouterStore()
    @StateObject private var browserSettings = BrowserSettingsStore()
    @StateObject private var browserTabs = BrowserTabsStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(router)
                .environmentObject(browserSettings)
                .environmentObject(browserTabs)
                .onChange(of: scenePhase) { _, phase in
                    router.setAwayFromForeground(phase != .active)
                }
        }
    }
}
