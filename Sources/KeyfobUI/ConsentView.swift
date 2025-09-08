import SwiftUI
import KeyfobCore

public struct ConsentDecision {
    public let useSession: Bool
    public let ttl: TimeInterval
    public init(useSession: Bool, ttl: TimeInterval) {
        self.useSession = useSession
        self.ttl = ttl
    }
}

public struct ConsentView: View {
    let origin: String
    let event: NostrEvent
    let onApprove: (ConsentDecision) -> Void
    let onDeny: () -> Void

    @State private var useSession: Bool = false
    @State private var ttlMinutes: Int = 5

    public init(origin: String, event: NostrEvent, onApprove: @escaping (ConsentDecision) -> Void, onDeny: @escaping () -> Void) {
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
            Divider()
            Toggle("Create a temporary session (Mode B)", isOn: $useSession)
            HStack {
                Text("Session TTL (minutes)")
                Spacer()
                Stepper(value: $ttlMinutes, in: 1...120) { Text("\(ttlMinutes)") }
                    .frame(width: 120)
            }
            .disabled(!useSession)
            HStack {
                Button("Deny") { onDeny() }
                Spacer()
                Button("Approve") { onApprove(.init(useSession: useSession, ttl: TimeInterval(ttlMinutes * 60))) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .blur(radius: 0) // Placeholder: add blur-on-switcher if needed
    }
}
