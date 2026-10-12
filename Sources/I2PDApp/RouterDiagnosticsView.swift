import Combine
import SwiftUI

@MainActor
private final class RouterDiagnosticsModel: ObservableObject {
    @Published var snapshot: I2PDStatusSnapshot?
    @Published var savedData: SavedRouterData?

    func refresh() {
        var value = I2PDStatusSnapshot()
        snapshot = i2pd_get_status(&value) == 1 ? value : nil
    }

    func refreshSavedData(from router: RouterStore) {
        savedData = router.savedDataSnapshot()
    }
}

struct RouterDiagnosticsView: View {
    @EnvironmentObject private var router: RouterStore
    @StateObject private var model = RouterDiagnosticsModel()
    @StateObject private var addressBook = AddressBookModel()

    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private let savedDataTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    private let addressBookTimer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    private var snapshot: I2PDStatusSnapshot? { model.snapshot }
    private var savedData: SavedRouterData? { model.savedData }

    var body: some View {
        List {
            Section("Overview") {
                LabeledContent("Router", value: routerState)
                if let snapshot {
                    LabeledContent("Connection", value: router.browserReadiness.label)
                    LabeledContent("Network status", value: networkStatus(snapshot.network_status,
                        testing: snapshot.network_testing, error: snapshot.network_error))
                    if snapshot.supports_v6 != 0 {
                        LabeledContent("Network status v6", value: networkStatus(snapshot.network_status_v6,
                            testing: snapshot.network_testing_v6, error: snapshot.network_error_v6))
                    }
                    LabeledContent("Uptime", value: uptime(snapshot.uptime_seconds))
                } else if router.state == .starting {
                    ProgressView("Starting i2pd and loading network data…")
                } else {
                    Text("Start the router to see live diagnostics.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Address book") {
                LabeledContent("Known names", value: (snapshot.map { Int($0.known_addresses) }
                    ?? addressBook.entries.count).formatted())
                LabeledContent("Showing", value: addressBook.source)
                if let snapshot {
                    if snapshot.addressbook_syncing != 0 {
                        ProgressView("Downloading address book updates…")
                    } else if snapshot.known_addresses == 0 {
                        ProgressView("Loading I2P names…")
                    } else if snapshot.last_addressbook_sync_epoch == 0 {
                        Text("Bootstrap names loaded. Subscription updates are pending.")
                            .foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Last subscription update", value: lastSync(snapshot.last_addressbook_sync_epoch))
                    }
                    if snapshot.addressbook_failures > 0 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Subscription attempts failed: \(snapshot.addressbook_failures). i2pd will retry.")
                            let reason = text(of: snapshot.addressbook_last_error)
                            if !reason.isEmpty {
                                Text(reason)
                                    .font(.footnote)
                                    .textSelection(.enabled)
                            }
                        }
                        .foregroundStyle(.orange)
                    }
                }
                NavigationLink {
                    AddressBookView(model: addressBook)
                } label: {
                    Label("Browse all names", systemImage: "text.book.closed")
                }
                if addressBook.isLoading { ProgressView("Reading names…") }
                ForEach(Array(addressBook.entries.prefix(5))) { entry in
                    Text(entry.name)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let snapshot {
                Section("Router identity") {
                    LabeledContent("i2pd version", value: text(of: snapshot.i2pd_version))
                    LabeledContent("Capabilities", value: text(of: snapshot.router_caps))
                    if !text(of: snapshot.router_family).isEmpty {
                        LabeledContent("Family", value: text(of: snapshot.router_family))
                    }
                    Text(text(of: snapshot.router_identity))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("Router identity (Base64)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Network database") {
                    LabeledContent("Routers known", value: snapshot.known_routers.formatted())
                    LabeledContent("Floodfills known", value: snapshot.known_floodfills.formatted())
                    LabeledContent("Floodfill on this iPhone", value: snapshot.is_floodfill != 0 ? "On" : "Off (i2pd default)")
                    LabeledContent("LeaseSets known", value: snapshot.known_lease_sets.formatted())
                    if snapshot.known_floodfills == 0 {
                        ProgressView("Discovering floodfill routers…")
                    }
                    Text("Floodfill stores network directory entries for other routers. It is normally off and is not needed for browsing or transit routing. The count above shows other floodfill routers this app knows about.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Tunnels") {
                    LabeledContent("Inbound", value: snapshot.inbound_tunnels.formatted())
                    LabeledContent("Outbound", value: snapshot.outbound_tunnels.formatted())
                    LabeledContent("Creation success", value: "\(snapshot.tunnel_success_percent)%")
                    LabeledContent("Total creation success", value: "\(snapshot.total_tunnel_success_percent)%")
                    LabeledContent("Transit", value: snapshot.transit_tunnels.formatted())
                    LabeledContent("Transit requests", value: snapshot.accepts_transit_tunnels != 0 ? "Allowed" : "Declined")
                    LabeledContent("Advertised contact route", value: snapshot.transit_contact_route != 0 ? "Available" : "Not available")
                    LabeledContent("Transit bandwidth limit", value: "\(snapshot.transit_bandwidth_limit_kib) KiB/s")
                    LabeledContent("Transit tunnel limit", value: snapshot.max_transit_tunnels.formatted())
                    LabeledContent("Tunnel queue", value: snapshot.tunnel_queue_size.formatted())
                    LabeledContent("Build message queue", value: snapshot.tunnel_build_queue_size.formatted())
                    if snapshot.inbound_tunnels == 0 || snapshot.outbound_tunnels == 0 {
                        ProgressView("Building tunnels…")
                    }
                    if snapshot.transit_contact_route == 0 {
                        Text("This router has no advertised contact route yet, so other routers cannot choose it for transit.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    Text("A transit count above zero means this router is relaying for others. A zero count means none are active yet; selection may take longer than a minute, and mobile networks can still block incoming connections.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Transports") {
                    LabeledContent("Connected peers", value: snapshot.connected_peers.formatted())
                    if snapshot.connected_peers == 0 {
                        ProgressView("Connecting to peers…")
                    }
                    LabeledContent("Received", value: byteCount(snapshot.received_bytes))
                    LabeledContent("Sent", value: byteCount(snapshot.sent_bytes))
                    LabeledContent("Download rate", value: "\(byteCount(UInt64(snapshot.receive_bytes_per_second)))/s")
                    LabeledContent("Upload rate", value: "\(byteCount(UInt64(snapshot.send_bytes_per_second)))/s")
                    LabeledContent("Transit traffic", value: byteCount(snapshot.transit_bytes))
                    LabeledContent("Transit rate", value: "\(byteCount(UInt64(snapshot.transit_bytes_per_second)))/s")
                }

                Section("Local services") {
                    LabeledContent("HTTP proxy", value: snapshot.http_proxy_ready != 0 ? "127.0.0.1:4444" : "Starting…")
                    LabeledContent("SOCKS proxy", value: snapshot.socks_proxy_ready != 0 ? "127.0.0.1:4447" : "Starting…")
                    LabeledContent("Browser tunnels", value: snapshot.socks_destination_ready != 0 ? "Ready" : "Building…")
                    if !text(of: snapshot.http_proxy_destination).isEmpty {
                        Text("HTTP destination: \(text(of: snapshot.http_proxy_destination))")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    if !text(of: snapshot.socks_proxy_destination).isEmpty {
                        Text("SOCKS destination: \(text(of: snapshot.socks_proxy_destination))")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    LabeledContent("BOB · SAM · I2CP · I2PControl", value: "Disabled")
                }
            }

            if router.state == .running {
                Section("Detailed console pages") {
                    NavigationLink("Local destinations") { I2PDConsoleView(page: "local_destinations") }
                    NavigationLink("LeaseSets") { I2PDConsoleView(page: "leasesets") }
                    NavigationLink("Tunnel paths") { I2PDConsoleView(page: "tunnels") }
                    NavigationLink("Transit tunnels") { I2PDConsoleView(page: "transit_tunnels") }
                    NavigationLink("Transport sessions") { I2PDConsoleView(page: "transports") }
                    NavigationLink("I2P tunnels") { I2PDConsoleView(page: "i2p_tunnels") }
                    NavigationLink("SAM sessions") { I2PDConsoleView(page: "sam_sessions") }
                    NavigationLink("Router commands") { I2PDConsoleView(page: "commands") }
                }
            }

            Section("Saved on this iPhone") {
                LabeledContent("Address book", value: savedData?.addressCount.map { "\($0.formatted()) names" } ?? "Waiting for first save")
                LabeledContent("Router identity", value: savedData?.hasRouterIdentity == true ? "Saved" : "Not yet saved")
                LabeledContent("Network database", value: savedData?.hasNetworkDatabase == true ? "Saved" : "Not yet saved")
                LabeledContent("Peer profiles", value: savedData?.hasPeerProfiles == true ? "Saved" : "Not yet saved")
                Text("The full address book is in addressbook/addresses.csv. hosts.txt contains only the initial bootstrap names. Live tunnels and traffic counters are rebuilt each time the router starts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Router diagnostics")
        .onAppear {
            model.refresh()
            model.refreshSavedData(from: router)
            addressBook.refresh()
        }
        .onReceive(refreshTimer) { _ in model.refresh() }
        .onReceive(savedDataTimer) { _ in model.refreshSavedData(from: router) }
        .onReceive(addressBookTimer) { _ in addressBook.refresh() }
    }

    private var routerState: String {
        switch router.state {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .stopping: "Stopping"
        case .failed: "Failed"
        }
    }

    private func networkStatus(_ status: Int32, testing: Int32, error: Int32) -> String {
        let label: String = switch status {
        case 0: "OK"
        case 1: "Firewalled"
        case 2: "Unknown"
        case 3: "Proxy"
        case 4: "Mesh"
        case 5: "Stan"
        default: "Unknown"
        }
        let errorLabel: String = switch error {
        case 1: "Clock skew"
        case 2: "Offline"
        case 3: "Symmetric NAT"
        case 4: "Full cone NAT"
        case 5: "No descriptors"
        default: ""
        }
        return label + (testing != 0 ? " (testing)" : "")
            + (errorLabel.isEmpty ? "" : " · \(errorLabel)")
    }

    private func text<T>(of value: T) -> String {
        withUnsafeBytes(of: value) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    private func uptime(_ seconds: UInt32) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remaining = seconds % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m \(remaining)s"
    }

    private func lastSync(_ epoch: UInt64) -> String {
        Date(timeIntervalSince1970: TimeInterval(epoch))
            .formatted(date: .abbreviated, time: .shortened)
    }

    private func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .binary)
    }
}
