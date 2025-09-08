import SwiftUI
import KeyfobPolicy

struct AllowlistView: View {
    @State private var callers: [String] = PolicyEngine.shared.listAllowedCallers()
    @State private var newBundleID: String = ""
    @State private var status: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("allow.title", comment: "Allowlist title"))
                .font(.title2).bold()
            HStack {
                TextField(NSLocalizedString("allow.placeholder", comment: "Bundle id placeholder"), text: $newBundleID)
                    .textFieldStyle(.roundedBorder)
                Button(NSLocalizedString("allow.add", comment: "Add")) { add() }
                    .disabled(newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            List {
                ForEach(callers, id: \.self) { id in
                    HStack {
                        Text(id)
                        Spacer()
                        Button(role: .destructive) {
                            remove(id)
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Text(status).font(.footnote).foregroundColor(.secondary)
        }
        .padding()
        .frame(minWidth: 520, minHeight: 360)
    }

    private func refresh() { callers = PolicyEngine.shared.listAllowedCallers() }

    private func add() {
        let id = newBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        PolicyEngine.shared.allowCaller(id)
        status = String(format: NSLocalizedString("allow.added_fmt", comment: "Added fmt"), id)
        newBundleID = ""
        refresh()
    }

    private func remove(_ id: String) {
        PolicyEngine.shared.removeCaller(id)
        status = String(format: NSLocalizedString("allow.removed_fmt", comment: "Removed fmt"), id)
        refresh()
    }
}
