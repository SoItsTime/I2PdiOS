import Foundation
import UIKit

struct SavedRouterData {
    let addressCount: Int?
    let hasRouterIdentity: Bool
    let hasNetworkDatabase: Bool
    let hasPeerProfiles: Bool
}

@MainActor
final class RouterStore: ObservableObject {
    // Match i2pd's documented maximum graceful-shutdown countdown.
    private static let gracefulShutdownSeconds: TimeInterval = 10 * 60

    enum State: Equatable {
        case stopped
        case starting
        case running
        case stopping
        case failed(String)
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var shutdownStartedAt: Date?
    @Published private(set) var shutdownDeadline: Date?
    @Published private(set) var shutdownConnectedPeers = 0
    @Published private(set) var shutdownTransitTunnels = 0
    @Published private(set) var coreStopQueued = false
    @Published private(set) var forceDisconnecting = false
    @Published var keepRunningInBackground: Bool {
        didSet {
            UserDefaults.standard.set(keepRunningInBackground, forKey: "keepRunningInBackground")
            syncBackgroundAudio()
        }
    }

    private let queue = DispatchQueue(label: "website.i2pd.ios.router", qos: .userInitiated)
    private let backgroundAudio = BackgroundRouterAudio()
    private let shutdownActivity = ShutdownLiveActivity()
    private var awayFromForeground = false
    private var shutdownMonitor: Task<Void, Never>?
    private var shutdownBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        keepRunningInBackground = UserDefaults.standard.bool(forKey: "keepRunningInBackground")
        Task { @MainActor [weak self] in
            self?.shutdownActivity.endActivitiesLeftByAnEarlierLaunch()
        }
    }

    func start() {
        guard state == .stopped || isFailed else { return }
        state = .starting

        do {
            let directory = try prepareDataDirectory()
            queue.async { [weak self] in
                var error = [CChar](repeating: 0, count: 1024)
                let succeeded = directory.path.withCString {
                    i2pd_start_router($0, &error, Int32(error.count)) == 1
                }
                let message = String(cString: error)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.state = succeeded ? .running : .failed(message.isEmpty ? "Router could not start" : message)
                    self.syncBackgroundAudio()
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        guard state == .running else { return }
        state = .stopping
        coreStopQueued = false
        forceDisconnecting = false
        let started = Date()
        shutdownStartedAt = started
        var snapshot = I2PDStatusSnapshot()
        if i2pd_get_status(&snapshot) == 1 {
            shutdownConnectedPeers = Int(snapshot.connected_peers)
            shutdownTransitTunnels = Int(snapshot.transit_tunnels)
        } else {
            shutdownConnectedPeers = 0
            shutdownTransitTunnels = 0
        }
        shutdownDeadline = started.addingTimeInterval(Self.gracefulShutdownSeconds)
        if let deadline = shutdownDeadline {
            shutdownActivity.start(at: started, deadline: deadline,
                                   peers: shutdownConnectedPeers,
                                   transitTunnels: shutdownTransitTunnels)
        }
        beginShutdownBackgroundTask()
        syncBackgroundAudio()
        queue.async { [weak self] in
            let begun = i2pd_begin_graceful_shutdown() == 1
            Task { @MainActor [weak self] in
                guard let self, self.state == .stopping, !self.coreStopQueued else { return }
                if begun { self.monitorGracefulShutdown() }
                else { self.finishStop(force: false) }
            }
        }
    }

    func forceDisconnect() {
        guard state == .stopping else { return }
        finishStop(force: true)
    }

    private func monitorGracefulShutdown() {
        shutdownMonitor?.cancel()
        shutdownMonitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.state == .stopping, !self.coreStopQueued else { return }
                self.refreshShutdownStatus()
                if let deadline = self.shutdownDeadline, Date() >= deadline {
                    self.finishStop(force: false)
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func refreshShutdownStatus() {
        var snapshot = I2PDStatusSnapshot()
        guard i2pd_get_status(&snapshot) == 1 else { return }
        let peers = Int(snapshot.connected_peers)
        let transit = Int(snapshot.transit_tunnels)
        let changed = peers != shutdownConnectedPeers || transit != shutdownTransitTunnels
        shutdownConnectedPeers = peers
        shutdownTransitTunnels = transit
        if changed, let deadline = shutdownDeadline {
            shutdownActivity.update(deadline: deadline, peers: peers, transitTunnels: transit)
        }
    }

    private func finishStop(force: Bool) {
        guard state == .stopping, !coreStopQueued else { return }
        coreStopQueued = true
        forceDisconnecting = force
        shutdownMonitor?.cancel()
        shutdownMonitor = nil
        queue.async { [weak self] in
            i2pd_stop_router()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.shutdownActivity.end()
                self.endShutdownBackgroundTask()
                self.state = .stopped
                self.shutdownStartedAt = nil
                self.shutdownDeadline = nil
                self.shutdownConnectedPeers = 0
                self.shutdownTransitTunnels = 0
                self.coreStopQueued = false
                self.forceDisconnecting = false
                self.syncBackgroundAudio()
            }
        }
    }

    private func beginShutdownBackgroundTask() {
        guard shutdownBackgroundTask == .invalid else { return }
        shutdownBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Disconnect i2pd") { [weak self] in
            Task { @MainActor [weak self] in self?.forceDisconnect() }
        }
    }

    private func endShutdownBackgroundTask() {
        guard shutdownBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(shutdownBackgroundTask)
        shutdownBackgroundTask = .invalid
    }

    func setAwayFromForeground(_ away: Bool) {
        awayFromForeground = away
        syncBackgroundAudio()
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func syncBackgroundAudio() {
        if awayFromForeground && keepRunningInBackground &&
            (state == .running || state == .stopping) {
            backgroundAudio.start()
        } else {
            backgroundAudio.stop()
        }
    }

    func savedDataSnapshot() -> SavedRouterData? {
        let files = FileManager.default
        guard let support = try? files.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }
        let directory = support.appendingPathComponent("i2pd", isDirectory: true)
        let index = directory.appendingPathComponent("addressbook/addresses.csv")
        let addressCount: Int?
        if let data = try? Data(contentsOf: index) {
            let lines = data.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
            addressCount = data.isEmpty ? 0 : lines + (data.last == 10 ? 0 : 1)
        } else {
            addressCount = nil
        }

        func hasFile(in folder: String) -> Bool {
            let url = directory.appendingPathComponent(folder, isDirectory: true)
            guard let entries = files.enumerator(at: url, includingPropertiesForKeys: nil) else {
                return false
            }
            for case let entry as URL in entries where !entry.hasDirectoryPath {
                return true
            }
            return false
        }

        return SavedRouterData(
            addressCount: addressCount,
            hasRouterIdentity: files.fileExists(atPath: directory.appendingPathComponent("router.keys").path),
            hasNetworkDatabase: hasFile(in: "netDb"),
            hasPeerProfiles: hasFile(in: "peerProfiles")
        )
    }

    private func prepareDataDirectory() throws -> URL {
        let files = FileManager.default
        let support = try files.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("i2pd", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)

        // Reseed certificates ship with the pinned i2pd source. Keep any user data intact.
        if let bundled = Bundle.main.url(forResource: "certificates", withExtension: nil) {
            let installed = directory.appendingPathComponent("certificates", isDirectory: true)
            if !files.fileExists(atPath: installed.path) {
                try files.copyItem(at: bundled, to: installed)
            }
        } else {
            throw NSError(domain: "I2PdiOS", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Bundled reseed certificates are missing"])
        }

        // i2pd starts with an empty address book. Its first subscription fetch can
        // take several minutes or fail while tunnels are still being established.
        // Seed a small set of names so the browser has known destinations on launch.
        let hosts = directory.appendingPathComponent("hosts.txt")
        guard let bundledHosts = Bundle.main.url(forResource: "hosts", withExtension: "txt") else {
            throw NSError(domain: "I2PdiOS", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Bundled I2P hosts are missing"])
        }
        if !files.fileExists(atPath: hosts.path) {
            try files.copyItem(at: bundledHosts, to: hosts)
        } else {
            // App updates can add bootstrap names. Preserve existing mappings,
            // including any names the user or a subscription already added.
            let current = try String(contentsOf: hosts, encoding: .utf8)
            let bundled = try String(contentsOf: bundledHosts, encoding: .utf8)
            let present = Set(current.split(separator: "\n").compactMap { line -> Substring? in
                guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { return nil }
                return line[..<equals]
            })
            let missing = bundled.split(separator: "\n").filter { line in
                guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { return false }
                return !present.contains(line[..<equals])
            }
            if !missing.isEmpty {
                let addition = (current.hasSuffix("\n") ? "" : "\n")
                    + missing.joined(separator: "\n") + "\n"
                let handle = try FileHandle(forWritingTo: hosts)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(addition.utf8))
            }
        }
        return directory
    }
}
