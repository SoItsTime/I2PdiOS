import SwiftUI
import UniformTypeIdentifiers

struct ReseedSettingsView: View {
    @EnvironmentObject private var router: RouterStore
    @State private var draft = ""
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var importingCertificate = false
    @State private var certificates: [String] = []

    var body: some View {
        Form {
            Section("Reseed source") {
                TextField("https://reseed.example.org/", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Save custom URL") {
                    if router.saveCustomReseedURL(draft) {
                        draft = router.customReseedURL
                        errorMessage = nil
                        message = router.state == .running
                            ? "Saved. It will be used after the next router start, if reseeding is needed."
                            : "Saved for the next router start."
                    } else {
                        message = nil
                        errorMessage = "Enter an HTTPS reseed server URL or a direct .su3 URL."
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Use i2pd's built-in reseed servers") {
                    _ = router.saveCustomReseedURL("")
                    draft = ""
                    errorMessage = nil
                    message = "Built-in servers will be used after the next router start."
                }
                if router.state == .running {
                    LabeledContent("Current source",
                                   value: router.activeReseedURL ?? "i2pd's built-in list")
                }
                if let message {
                    Text(message).foregroundStyle(.green).font(.footnote)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.footnote)
                }
                Text("For a server URL, i2pd requests i2pseeds.su3 from that path. A direct HTTPS .su3 URL is also accepted. The custom URL replaces the built-in list until you clear it. i2pd only reseeds when its network database needs it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Reseed signing certificates") {
                Button("Import a PEM .crt certificate") {
                    importingCertificate = true
                }
                ForEach(certificates, id: \.self) { filename in
                    HStack {
                        Text(filename).font(.footnote).lineLimit(2)
                        Spacer()
                        Button("Remove", role: .destructive) {
                            do {
                                try router.removeImportedReseedCertificate(filename)
                                certificates = router.importedReseedCertificates()
                                message = "Certificate removed. Restart the router to apply."
                            } catch { errorMessage = error.localizedDescription }
                        }
                    }
                }
                Text("SU3 signature verification remains enabled. Import the reseed server's public signing certificate if its signer is not already trusted. Certificate changes take effect on the next router start.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("Reseeding contacts the HTTPS server directly during bootstrap. That server can see your IP address. Torrent traffic uses I2P after the router connects.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Reseed settings")
        .fileImporter(isPresented: $importingCertificate,
                      allowedContentTypes: [UTType(filenameExtension: "crt") ?? .data]) { result in
            do {
                let filename = try router.installReseedCertificate(from: result.get())
                certificates = router.importedReseedCertificates()
                errorMessage = nil
                message = "Imported \(filename). Restart the router to use it."
            } catch { errorMessage = error.localizedDescription }
        }
        .onAppear {
            draft = router.customReseedURL
            certificates = router.importedReseedCertificates()
        }
    }
}
