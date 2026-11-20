import Foundation
import SwiftUI
import UniformTypeIdentifiers

private struct I2PDTorrent: Decodable, Identifiable {
    let id: Int
    let name: String
    let status: Int
    let totalBytes: UInt64
    let leftBytes: UInt64
    let downloadRate: UInt64
    let uploadRate: UInt64
    let error: String

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(totalBytes - min(totalBytes, leftBytes)) / Double(totalBytes)
    }

    var statusText: String {
        switch status {
        case 0: "Paused"
        case 1, 2: "Checking files"
        case 3: "Queued to download"
        case 4: "Downloading"
        case 5: "Queued to seed"
        case 6: "Seeding"
        default: "Connecting"
        }
    }
}

struct TorrentsView: View {
    @EnvironmentObject private var router: RouterStore
    @State private var torrents: [I2PDTorrent] = []
    @State private var magnet = ""
    @State private var isImporting = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var pendingRemoval: I2PDTorrent?

    private var running: Bool { router.state == .running }

    var body: some View {
        Form {
            Section("Add") {
                TextField("magnet:?xt=urn:btih:…", text: $magnet, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(2...4)
                Button("Add magnet") { addMagnet() }
                    .disabled(!running || isWorking || magnet.isEmpty)
                Button("Import .torrent file") { isImporting = true }
                    .disabled(!running || isWorking)
                Text("Only I2P peers and I2P trackers can be reached. Public BitTorrent swarms will not connect through this tunnel.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Transfers") {
                if !running {
                    Text("Start the router to load and manage torrents.")
                        .foregroundStyle(.secondary)
                } else if torrents.isEmpty {
                    Text("No torrents yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(torrents) { torrent in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(torrent.name.isEmpty ? "Fetching metadata…" : torrent.name)
                            .font(.headline).lineLimit(2)
                        ProgressView(value: torrent.fraction)
                        Text("\(torrent.statusText) · \(Int(torrent.fraction * 100))%")
                            .font(.subheadline)
                        if torrent.downloadRate > 0 || torrent.uploadRate > 0 {
                            Text("↓ \(torrent.downloadRate.formatted(.byteCount(style: .file)))/s  ↑ \(torrent.uploadRate.formatted(.byteCount(style: .file)))/s")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if torrent.totalBytes > 0 {
                            Text("\(torrent.totalBytes.formatted(.byteCount(style: .file))) total")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !torrent.error.isEmpty {
                            Text(torrent.error).font(.caption).foregroundStyle(.red)
                        }
                        HStack {
                            Button(torrent.status == 0 ? "Resume" : "Pause") {
                                performAction(id: torrent.id, action: torrent.status == 0 ? 1 : 0)
                            }
                            .buttonStyle(.bordered)
                            Button("Remove", role: .destructive) { pendingRemoval = torrent }
                                .buttonStyle(.bordered)
                        }
                        .disabled(isWorking)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Downloaded files") {
                Text("Open Files → On My iPhone → i2pd → Torrents. Files and the torrent identity remain after the router stops or the app updates.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("I2P torrents")
        .fileImporter(isPresented: $isImporting,
                      allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data]) { result in
            importTorrent(result)
        }
        .confirmationDialog("Remove \(pendingRemoval?.name ?? "torrent")?",
                            isPresented: Binding(get: { pendingRemoval != nil },
                                                 set: { if !$0 { pendingRemoval = nil } })) {
            if let torrent = pendingRemoval {
                Button("Remove, keep files") { performAction(id: torrent.id, action: 2); pendingRemoval = nil }
                Button("Remove and delete files", role: .destructive) {
                    performAction(id: torrent.id, action: 3); pendingRemoval = nil
                }
            }
        }
        .alert("Torrent error", isPresented: Binding(get: { errorMessage != nil },
                                                    set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task(id: running) {
            while !Task.isCancelled && running {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
            if !running { torrents = [] }
        }
    }

    private func refresh() async {
        let data: Data? = await Task.detached(priority: .utility) {
            let size = i2pd_copy_torrents_json(nil, 0)
            guard size >= 0 && size < 4_000_000 else { return nil }
            var bytes = [CChar](repeating: 0, count: Int(size))
            let copied = i2pd_copy_torrents_json(&bytes, size)
            guard copied == size else { return nil }
            return Data(bytes.map { UInt8(bitPattern: $0) })
        }.value
        if let data, let decoded = try? JSONDecoder().decode([I2PDTorrent].self, from: data) {
            torrents = decoded
        }
    }

    private func addMagnet() {
        isWorking = true
        let value = magnet.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let message: String? = await Task.detached(priority: .userInitiated) {
                var error = [CChar](repeating: 0, count: 512)
                return value.withCString { pointer in
                    i2pd_add_magnet(pointer, &error, Int32(error.count)) == 1 ? nil : String(cString: error)
                }
            }.value
            isWorking = false
            if let message { errorMessage = message }
            else { magnet = ""; await refresh() }
        }
    }

    private func importTorrent(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard data.count <= 8 * 1024 * 1024 else {
                throw CocoaError(.fileReadTooLarge)
            }
            isWorking = true
            Task {
                let message: String? = await Task.detached(priority: .userInitiated) {
                    var error = [CChar](repeating: 0, count: 512)
                    let succeeded = data.withUnsafeBytes { bytes in
                        i2pd_add_torrent_file(bytes.bindMemory(to: UInt8.self).baseAddress,
                                              Int32(data.count), &error, Int32(error.count))
                    }
                    return succeeded == 1 ? nil : String(cString: error)
                }.value
                isWorking = false
                if let message { errorMessage = message }
                else { await refresh() }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func performAction(id: Int, action: Int32) {
        isWorking = true
        Task {
            let message: String? = await Task.detached(priority: .userInitiated) {
                var error = [CChar](repeating: 0, count: 512)
                let succeeded = i2pd_torrent_action(Int32(id), action, &error, Int32(error.count))
                return succeeded == 1 ? nil : String(cString: error)
            }.value
            isWorking = false
            if let message { errorMessage = message }
            else { await refresh() }
        }
    }
}
