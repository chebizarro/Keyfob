import SwiftUI
import KeyfobCrypto

struct ContentView: View {
    @State private var pubkey: String = ""
    @State private var status: String = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(NSLocalizedString("content.key_section", comment: "Key section header"))) {
                    HStack {
                        Text(NSLocalizedString("content.pubkey_label", comment: "Pubkey label"))
                        Spacer()
                    }
                    Text(pubkey.isEmpty ? NSLocalizedString("content.not_generated", comment: "Not generated") : pubkey)
                        .font(.footnote)
                        .textSelection(.enabled)
                    Button(NSLocalizedString("content.generate_btn", comment: "Generate/Load Key")) {
                        do {
                            let pair = try KeyManager.shared.generateIfNeeded(useICloud: true)
                            pubkey = pair.pubkeyHex
                            status = NSLocalizedString("content.loaded", comment: "Loaded")
                        } catch {
                            status = String(format: NSLocalizedString("content.error_fmt", comment: "Error fmt"), error.localizedDescription)
                        }
                    }
                }
                Section(header: Text(NSLocalizedString("content.status_section", comment: "Status section"))) {
                    Text(status)
                        .font(.footnote)
                }
                Section(footer: Text(NSLocalizedString("content.footer_ul", comment: "UL footer")).font(.footnote)) {
                    EmptyView()
                }
            }
            .navigationTitle(NSLocalizedString("content.nav_title", comment: "Nav title"))
        }
    }
}
