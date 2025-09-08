import SwiftUI

struct OnboardingView: View {
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Enable the Keyfob Safari Web Extension")
                        .font(.title2).bold()
                    Group {
                        Text("1. Build & install this app on your iPhone/iPad.")
                        Text("2. Open Settings → Safari → Extensions.")
                        Text("3. Enable ‘Keyfob NIP-07’. Grant permissions when asked.")
                        Text("4. Visit a Nostr-enabled site in Safari and it will detect window.nostr.")
                    }
                    .font(.body)
                    .padding(.leading, 4)

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "gear")
                            Text("Open Settings")
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Divider().padding(.vertical, 8)

                    Text("Troubleshooting")
                        .font(.headline)
                    Text("• Ensure Associated Domains includes applinks:keyfob.example.com (replace with your domain).\n• Universal Links must route to the Keyfob app and callback page must postMessage back to the opener.\n• See Web/demo/callback.html for a reference callback page.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding()
            }
            .navigationTitle("Keyfob Extension")
        }
    }
}
