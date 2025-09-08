import SwiftUI
import KeyfobCore

public struct ConsentView: View {
    let origin: String
    let event: NostrEvent
    let onApprove: () -> Void
    let onDeny: () -> Void

    public init(origin: String, event: NostrEvent, onApprove: @escaping () -> Void, onDeny: @escaping () -> Void) {
        self.origin = origin
        self.event = event
        self.onApprove = onApprove
        self.onDeny = onDeny
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Request from \(origin)").font(.headline)
            Text("Kind: \(event.kind)")
            Text("Content preview: \(event.content.prefix(120))")
            GroupBox(label: Text("Raw JSON")) {
                ScrollView { Text(try! CanonicalJSON.serializeEvent(event)).font(.footnote).textSelection(.enabled) }
                    .frame(maxHeight: 200)
            }
            HStack {
                Button("Deny") { onDeny() }
                Spacer()
                Button("Approve") { onApprove() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .blur(radius: 0) // Placeholder: add blur-on-switcher if needed
    }
}
