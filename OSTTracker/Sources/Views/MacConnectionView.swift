#if os(iOS)
import SwiftUI
import UIKit

struct MacConnectionView: View {
    @State private var address = ""
    @State private var pairingCode = ""
    @State private var connecting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                CloudAccountSection()
                Section {
                    Text("Your iPhone keeps its data and works offline. On a fresh install, connecting can copy your existing Mac library once; after that, Supabase syncs changes between devices. The Mac connection is also used for song lookup and streaming.")
                }
                Section {
                    Button("Paste connection from Mac") {
                        do {
                            let details = try LANConnection.parsePairingText(UIPasteboard.general.string ?? "")
                            address = details.address.absoluteString
                            pairingCode = details.token
                            errorMessage = nil
                            Task { await connect(to: details.address, token: details.token) }
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(connecting)
                    Text("On your Mac, choose Copy connection in OSTTracker Settings. Universal Clipboard can bring it to this iPhone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Enter manually") {
                    TextField("Mac address", text: $address, prompt: Text("My-Mac.local:8765"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Pairing code", text: $pairingCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Button(connecting ? "Connecting…" : "Connect to Mac") {
                        Task { await connectManually() }
                    }
                    .disabled(connecting || address.isEmpty || pairingCode.isEmpty)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Connect OSTTracker")
        }
    }

    private func connectManually() async {
        do {
            let url = try LANConnection.parseAddress(address)
            await connect(to: url, token: pairingCode.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            errorMessage = "Couldn't connect: \(error.localizedDescription)"
        }
    }

    private func connect(to url: URL, token: String) async {
        connecting = true
        defer { connecting = false }
        errorMessage = nil
        do {
            let client = BackendClient(baseURL: url, token: token)
            try await client.checkHealth()
            try LANConnection.save(address: url, token: token)
            AppStore.shared.configurePlaybackBackend()
            await AppStore.shared.bootstrapPhoneFromMacIfFresh()
        } catch {
            errorMessage = "Couldn't connect: \(error.localizedDescription)"
        }
    }
}
#endif
