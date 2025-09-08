import SwiftUI
import KeyfobCrypto

struct ContentView: View {
    @State private var pubkey: String = ""
    @State private var status: String = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Key")) {
                    HStack {
                        Text("Pubkey (hex)")
                        Spacer()
                    }
                    Text(pubkey.isEmpty ? "Not generated" : pubkey)
                        .font(.footnote)
                        .textSelection(.enabled)
                    Button("Generate/Load Key") {
                        do {
                            let pair = try KeyManager.shared.generateIfNeeded(useICloud: true)
                            pubkey = pair.pubkeyHex
                            status = "Loaded"
                        } catch {
                            status = "Error: \(error.localizedDescription)"
                        }
                    }
                }
                Section(header: Text("Status")) {
                    Text(status)
                        .font(.footnote)
                }
                Section(footer: Text("Universal Links: ensure Associated Domains include applinks:keyfob.example.com and the hosted pages return to your app/web via the configured callback.").font(.footnote)) {
                    EmptyView()
                }
            }
            .navigationTitle("Keyfob")
        }
    }
}
