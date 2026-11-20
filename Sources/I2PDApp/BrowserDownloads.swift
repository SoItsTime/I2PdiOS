import Foundation
import SwiftUI
import WebKit

enum BrowserDownloadStatus: Equatable {
    case downloading
    case addingTorrent
    case finished
    case failed(String)
    case cancelled

    var isActive: Bool {
        self == .downloading || self == .addingTorrent
    }

    var label: String {
        switch self {
        case .downloading: "Downloading…"
        case .addingTorrent: "Adding to I2P torrents…"
        case .finished: "Finished"
        case .failed(let message): message
        case .cancelled: "Cancelled"
        }
    }
}

struct BrowserDownloadItem: Identifiable {
    let id: UUID
    var name: String
    var fraction: Double?
    var status: BrowserDownloadStatus
    var isTorrent: Bool
    var fileURL: URL?

    var detail: String {
        if status == .finished && isTorrent { return "Added to I2P torrents" }
        if status == .finished { return "Saved in Files → i2pd → Downloads" }
        return status.label
    }
}

@MainActor
final class BrowserDownloads: NSObject, ObservableObject, WKDownloadDelegate {
    @Published private(set) var items: [BrowserDownloadItem] = []

    private struct ActiveDownload {
        let id: UUID
        let download: WKDownload
        let progressTask: Task<Void, Never>
        var destination: URL?
        var isTorrent: Bool
    }

    private var active: [ObjectIdentifier: ActiveDownload] = [:]
    private var claimedPaths: Set<String> = []

    func addMagnet(_ value: String) {
        let id = UUID()
        items.append(BrowserDownloadItem(id: id, name: "Magnet link", fraction: nil,
                                         status: .addingTorrent, isTorrent: true, fileURL: nil))
        Task {
            let error: String? = await Task.detached(priority: .userInitiated) {
                var message = [CChar](repeating: 0, count: 512)
                let accepted = value.withCString {
                    i2pd_add_magnet($0, &message, Int32(message.count)) == 1
                }
                return accepted ? nil : String(cString: message)
            }.value
            update(id) { $0.status = error.map { .failed($0) } ?? .finished }
        }
    }

    func register(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        guard active[key] == nil else { return }
        let id = UUID()
        let proposedName = download.originalRequest?.url?.lastPathComponent ?? "Download"
        let name = Self.safeFilename(proposedName)
        let isTorrent = name.lowercased().hasSuffix(".torrent")
        items.append(BrowserDownloadItem(id: id, name: name, fraction: nil,
                                         status: .downloading, isTorrent: isTorrent, fileURL: nil))
        download.delegate = self
        let progressTask = Task { [weak self, weak download] in
            while !Task.isCancelled {
                guard let self, let download, self.active[key] != nil else { return }
                let progress = download.progress
                let value = progress.totalUnitCount > 0
                    ? min(max(progress.fractionCompleted, 0), 1) : nil
                self.update(id) { item in
                    if item.status == .downloading { item.fraction = value }
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        active[key] = ActiveDownload(id: id, download: download,
                                     progressTask: progressTask, destination: nil,
                                     isTorrent: isTorrent)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        register(download)
        let key = ObjectIdentifier(download)
        let name = Self.safeFilename(suggestedFilename)
        let isTorrent = Self.isTorrent(response: response, filename: name)
        do {
            let destination: URL
            if isTorrent {
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("i2pd-browser-torrents", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                destination = folder.appendingPathComponent("\(UUID().uuidString)-\(name)")
            } else {
                destination = try uniqueDownloadURL(filename: name)
            }
            active[key]?.destination = destination
            active[key]?.isTorrent = isTorrent
            update(active[key]!.id) { item in
                item.name = name
                item.isTorrent = isTorrent
            }
            completionHandler(destination)
        } catch {
            if let id = active[key]?.id { update(id) { $0.status = .failed(error.localizedDescription) } }
            finish(key)
            completionHandler(nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        guard let record = active[key], let destination = record.destination else { return }
        let originalName = items.first(where: { $0.id == record.id })?.name ?? "Download.torrent"
        finish(key)
        if items.first(where: { $0.id == record.id })?.status == .cancelled {
            try? FileManager.default.removeItem(at: destination)
            return
        }
        if !record.isTorrent {
            update(record.id) { item in
                item.fraction = 1
                item.fileURL = destination
                item.status = .finished
            }
            return
        }
        update(record.id) { $0.status = .addingTorrent }
        Task {
            let error: String? = await Task.detached(priority: .userInitiated) {
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
                    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
                    guard size > 0 && size <= 8 * 1024 * 1024 else {
                        return "Torrent file must be under 8 MB"
                    }
                    let data = try Data(contentsOf: destination)
                    var message = [CChar](repeating: 0, count: 512)
                    let accepted = data.withUnsafeBytes { bytes in
                        i2pd_add_torrent_file(bytes.bindMemory(to: UInt8.self).baseAddress,
                                              Int32(data.count), &message, Int32(message.count)) == 1
                    }
                    return accepted ? nil : String(cString: message)
                } catch { return error.localizedDescription }
            }.value
            if let error {
                do {
                    let saved = try uniqueDownloadURL(filename: originalName)
                    try FileManager.default.moveItem(at: destination, to: saved)
                    update(record.id) { item in
                        item.fileURL = saved
                        item.status = .failed("\(error). File saved in Downloads.")
                    }
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    update(record.id) { $0.status = .failed(error.localizedDescription) }
                }
            } else {
                try? FileManager.default.removeItem(at: destination)
                update(record.id) { item in
                    item.fraction = 1
                    item.status = .finished
                }
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        guard let record = active[key] else { return }
        finish(key)
        if let destination = record.destination { try? FileManager.default.removeItem(at: destination) }
        update(record.id) { item in
            if item.status != .cancelled { item.status = .failed(error.localizedDescription) }
        }
    }

    func cancel(_ id: UUID) {
        guard let record = active.values.first(where: { $0.id == id }) else { return }
        record.download.cancel(nil)
        update(id) { $0.status = .cancelled }
    }

    func dismiss(_ id: UUID) {
        if let record = active.values.first(where: { $0.id == id }) { cancel(record.id) }
        items.removeAll { $0.id == id }
    }

    private func finish(_ key: ObjectIdentifier) {
        if let record = active.removeValue(forKey: key) {
            record.progressTask.cancel()
            if let path = record.destination?.path { claimedPaths.remove(path) }
        }
    }

    private func update(_ id: UUID, _ change: (inout BrowserDownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func uniqueDownloadURL(filename: String) throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
        let folder = documents.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = Self.safeFilename(filename)
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var suffix = 2
        while claimedPaths.contains(candidate.path) || FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(stem) (\(suffix))" : "\(stem) (\(suffix)).\(ext)"
            candidate = folder.appendingPathComponent(next)
            suffix += 1
        }
        claimedPaths.insert(candidate.path)
        return candidate
    }

    private static func safeFilename(_ proposed: String) -> String {
        let cleaned = proposed.replacingOccurrences(of: "\\", with: "/")
            .components(separatedBy: "/").last ?? ""
        let printable = String(cleaned.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        return printable.isEmpty || printable == "." || printable == ".." ? "Download" : printable
    }

    private static func isTorrent(response: URLResponse, filename: String) -> Bool {
        let mime = response.mimeType?.lowercased() ?? ""
        return filename.lowercased().hasSuffix(".torrent") ||
            response.url?.pathExtension.lowercased() == "torrent" ||
            mime == "application/x-bittorrent" || mime == "application/x-torrent"
    }
}

struct BrowserDownloadsTray: View {
    @ObservedObject var downloads: BrowserDownloads
    @State private var showAll = false

    var body: some View {
        if let item = downloads.items.last {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: item.isTorrent ? "arrow.down.circle" : "doc")
                    Button { showAll = true } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).lineLimit(1).font(.subheadline)
                            Text(item.detail).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    if item.status == .downloading {
                        Button { downloads.cancel(item.id) } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .accessibilityLabel("Cancel download")
                    } else {
                        Button { downloads.dismiss(item.id) } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Dismiss download")
                    }
                }
                if item.status == .downloading {
                    if let fraction = item.fraction {
                        ProgressView(value: fraction, total: 1)
                    } else {
                        ProgressView()
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemBackground))
            .sheet(isPresented: $showAll) {
                NavigationStack {
                    List(Array(downloads.items.reversed())) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.name).font(.headline)
                            Text(entry.detail).font(.caption).foregroundStyle(.secondary)
                            if entry.status == .downloading {
                                if let fraction = entry.fraction {
                                    ProgressView(value: fraction, total: 1)
                                } else { ProgressView() }
                            }
                            HStack {
                                if let file = entry.fileURL { ShareLink("Share file", item: file) }
                                if entry.isTorrent && entry.status == .finished {
                                    NavigationLink("I2P torrents") { TorrentsView() }
                                }
                                Spacer()
                                if entry.status == .downloading {
                                    Button("Cancel", role: .destructive) { downloads.cancel(entry.id) }
                                } else {
                                    Button("Dismiss") { downloads.dismiss(entry.id) }
                                }
                            }
                            .font(.caption)
                        }
                        .padding(.vertical, 3)
                    }
                    .navigationTitle("Downloads")
                    .toolbar { Button("Done") { showAll = false } }
                }
            }
        }
    }
}
