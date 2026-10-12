import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var router: RouterStore

    var body: some View {
        NavigationStack {
            Form {
                Section("Router") {
                    HStack {
                        Image(systemName: "network")
                            .foregroundStyle(router.canBrowse ? .green : .secondary)
                        Text(statusText)
                    }
                    if router.state == .starting ||
                        (router.state == .running && !router.canBrowse) {
                        ProgressView(router.browserReadiness.label)
                    }
                    if case let .failed(message) = router.state {
                        Text(message).foregroundStyle(.red).font(.footnote)
                    }
                    Button(actionTitle) {
                        if router.state == .running { router.stop() }
                        else if router.state == .stopping { router.forceDisconnect() }
                        else { router.start() }
                    }
                    .disabled(router.state == .starting ||
                              (router.state == .stopping && router.coreStopQueued))
                    if router.state == .stopping {
                        if let started = router.shutdownStartedAt,
                           let deadline = router.shutdownDeadline {
                            HStack {
                                Text("Time until disconnect")
                                Spacer()
                                Text(timerInterval: started...deadline,
                                     countsDown: true, showsHours: false)
                                    .monospacedDigit()
                            }
                        }
                        LabeledContent("Connected peers", value: router.shutdownConnectedPeers.formatted())
                        if router.shutdownTransitTunnels > 0 {
                            LabeledContent("Transit tunnels", value: router.shutdownTransitTunnels.formatted())
                        }
                        Text(router.forceDisconnecting
                             ? "Closing connections now…"
                             : "New transit tunnels are declined. Existing activity gets time to finish. Force disconnect closes connections now.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Browse") {
                    NavigationLink {
                        BrowserView()
                    } label: {
                        Label("Open I2P browser", systemImage: "globe")
                    }
                    .disabled(!router.canBrowse)
                    Text(router.canBrowse
                         ? "The browser connection is ready. Individual I2P sites may still take time to respond."
                         : "The browser opens after i2pd connects to peers and builds working tunnels.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Settings") {
                    NavigationLink {
                        BrowserSettingsView()
                    } label: {
                        Label("Browser settings", systemImage: "gearshape")
                    }
                }

                Section("Router menu") {
                    NavigationLink {
                        I2PDConsoleView()
                    } label: {
                        Label("i2pd web console", systemImage: "list.bullet.rectangle")
                    }
                    .disabled(router.state != .running)
                    NavigationLink {
                        RouterDiagnosticsView()
                    } label: {
                        Label("Live diagnostics", systemImage: "chart.bar.xaxis")
                    }
                    Text("Open the original i2pd menu, or use native live diagnostics for address book loading and saved data.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Background") {
                    Toggle("Try to keep router running", isOn: $router.keepRunningInBackground)
                    Text("Uses quiet audio while the app is away from the screen. iOS may still suspend or close the app, which stops I2P until you reopen it. Audio playback can be affected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Local access") {
                    LabeledContent("Web console", value: "127.0.0.1:7070")
                    LabeledContent("HTTP proxy", value: "127.0.0.1:4444")
                    LabeledContent("SOCKS proxy", value: "127.0.0.1:4447")
                    Text("Both proxies listen only on this iPhone. Router traffic is disabled when you stop the router.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("i2pd")
        }
    }

    private var statusText: String {
        switch router.state {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .running: router.canBrowse ? "Browser connection ready" : "Connecting to I2P…"
        case .stopping: "Disconnecting…"
        case .failed: "Could not start"
        }
    }

    private var actionTitle: String {
        if router.state == .running { return "Disconnect safely" }
        if router.state == .stopping {
            return router.coreStopQueued ? "Disconnecting…" : "Force disconnect"
        }
        return "Start router"
    }
}
