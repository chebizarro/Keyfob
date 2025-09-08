import SwiftUI

struct OnboardingView: View {
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(NSLocalizedString("onboard.title", comment: "Enable extension title"))
                        .font(.title2).bold()
                    Group {
                        Text(NSLocalizedString("onboard.step1", comment: "Step 1"))
                        Text(NSLocalizedString("onboard.step2", comment: "Step 2"))
                        Text(NSLocalizedString("onboard.step3", comment: "Step 3"))
                        Text(NSLocalizedString("onboard.step4", comment: "Step 4"))
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
                            Text(NSLocalizedString("onboard.open_settings", comment: "Open Settings"))
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Divider().padding(.vertical, 8)

                    Text(NSLocalizedString("onboard.troubleshooting", comment: "Troubleshooting"))
                        .font(.headline)
                    Text(NSLocalizedString("onboard.troubleshooting_text", comment: "Troubleshooting text"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding()
            }
            .navigationTitle(NSLocalizedString("onboard.nav_title", comment: "Nav title"))
        }
    }
}
