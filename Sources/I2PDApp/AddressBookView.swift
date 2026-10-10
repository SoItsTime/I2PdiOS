import Combine
import Foundation
import SwiftUI
import UIKit

struct AddressBookEntry: Codable, Identifiable, Hashable {
    let name: String
    let destination: String

    var id: String { name }

    var destinationAddress: String {
        if destination.hasSuffix(".i2p") { return destination }
        return destination + (destination.count <= 52 ? ".b32.i2p" : ".b33.i2p")
    }
}

@MainActor
final class AddressBookModel: ObservableObject {
    @Published private(set) var entries: [AddressBookEntry] = []
    @Published private(set) var source = "Loading…"
    @Published private(set) var isLoading = false
    @Published var searchText = ""

    var filteredEntries: [AddressBookEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.destination.localizedCaseInsensitiveContains(query)
        }
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task.detached(priority: .utility) {
            let live = Self.loadLive()
            let saved = live?.isEmpty == false ? nil : Self.loadSaved()
            let result = (live?.isEmpty == false ? live! : (saved ?? live ?? []))
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let source = live?.isEmpty == false ? "Live i2pd address book"
                : saved != nil ? "Saved address book" : "No names loaded yet"
            await MainActor.run {
                self.entries = result
                self.source = source
                self.isLoading = false
            }
        }
    }

    nonisolated private static func loadLive() -> [AddressBookEntry]? {
        var buffer = [CChar](repeating: 0, count: 512 * 1024)
        for _ in 0..<4 {
            let result = buffer.withUnsafeMutableBufferPointer {
                i2pd_copy_address_book_json($0.baseAddress, Int32($0.count))
            }
            if result < 0 { return nil }
            if Int(result) >= buffer.count {
                buffer = [CChar](repeating: 0, count: Int(result))
                continue
            }
            let data = buffer.withUnsafeBytes { Data($0.prefix(Int(result))) }
            return try? JSONDecoder().decode([AddressBookEntry].self, from: data)
        }
        return nil
    }

    nonisolated private static func loadSaved() -> [AddressBookEntry]? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let index = support.appendingPathComponent("i2pd/addressbook/addresses.csv")
        guard let text = try? String(contentsOf: index, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let comma = line.firstIndex(of: ",") else { return nil }
            let name = String(line[..<comma]).trimmingCharacters(in: .whitespacesAndNewlines)
            let csvLine = String(line)
            let separator = csvLine.firstIndex(of: ",")!
            let destination = String(csvLine[csvLine.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !destination.isEmpty else { return nil }
            return AddressBookEntry(name: name, destination: destination)
        }
    }
}

struct AddressBookView: View {
    @ObservedObject var model: AddressBookModel
    private let refreshTimer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            Section {
                LabeledContent("Source", value: model.source)
                LabeledContent("Names", value: model.entries.count.formatted())
                if model.isLoading { ProgressView("Loading address book…") }
                Button("Refresh now", systemImage: "arrow.clockwise") { model.refresh() }
            }

            Section("Addresses") {
                if model.filteredEntries.isEmpty && !model.isLoading {
                    Text(model.searchText.isEmpty ? "No names have loaded yet." : "No matching names.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.filteredEntries) { entry in
                    NavigationLink {
                        AddressBookEntryView(entry: entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.name)
                            Text(entry.destinationAddress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .navigationTitle("Address book")
        .searchable(text: $model.searchText, prompt: "Search names or destinations")
        .onAppear { model.refresh() }
        .onReceive(refreshTimer) { _ in model.refresh() }
    }
}

private struct AddressBookEntryView: View {
    let entry: AddressBookEntry

    var body: some View {
        List {
            Section("Name") {
                Text(entry.name).textSelection(.enabled)
                Button("Copy name", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = entry.name
                }
            }
            Section("Destination") {
                Text(entry.destinationAddress)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                Button("Copy destination", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = entry.destinationAddress
                }
            }
        }
        .navigationTitle(entry.name)
    }
}
