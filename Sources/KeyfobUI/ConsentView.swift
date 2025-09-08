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
    let onError: ((String) -> Void)?

    @State private var useSession: Bool = false
    @State private var ttlMinutes: Int = 5
    @State private var serializedEvent: String? = nil
    @State private var serializeFailed: Bool = false

    public init(origin: String, event: NostrEvent, onApprove: @escaping (ConsentDecision) -> Void, onDeny: @escaping () -> Void, onError: ((String) -> Void)? = nil) {
        self.origin = origin
        self.event = event
        self.onApprove = onApprove
        self.onDeny = onDeny
        self.onError = onError
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(format: L("consent.title"), origin)).font(.headline)
            Text(String(format: L("consent.kind"), event.kind))
            VStack(alignment: .leading, spacing: 4) {
                Text(L("consent.content_preview")).font(.subheadline)
                Text(event.content)
                    .font(.footnote)
                    .lineLimit(5)
                    .textSelection(.enabled)
            }
            GroupBox(label: Text(L("consent.raw_json"))) {
                ScrollView {
                    if let s = serializedEvent {
                        Text(s).font(.footnote).textSelection(.enabled)
                    } else if serializeFailed {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("consent.serialize_error")).foregroundColor(.red)
                            Text(L("consent.serialize_error_hint")).font(.footnote)
                        }
                    } else {
                        ProgressView().progressViewStyle(.circular)
                    }
                }
                .frame(maxHeight: 200)
            }
            Divider()
            Toggle(L("consent.mode_b_toggle"), isOn: $useSession)
            HStack {
                Text(L("consent.session_ttl"))
                Spacer()
                Stepper(value: $ttlMinutes, in: 1...120) { Text("\(ttlMinutes)") }
                    .frame(width: 120)
            }
            .disabled(!useSession)
            HStack {
                Button(L("consent.deny")) { onDeny() }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(Text(L("consent.deny")))
                Spacer()
                Button(L("consent.approve")) { onApprove(.init(useSession: useSession, ttl: TimeInterval(ttlMinutes * 60))) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(Text(L("consent.approve")))
            }
        }
        .padding()
        .blur(radius: 0) // Placeholder: add blur-on-switcher if needed
        .onAppear {
            // Precompute serialized event for display without crashing UI on failure
            if let s = try? CanonicalJSON.serializeEvent(event) {
                serializedEvent = s
            } else {
                serializeFailed = true
                onError?(L("consent.serialize_error"))
            }
        }
    }
}

// MARK: - Localization helper for SPM resources
private func L(_ key: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: .module, value: key, comment: "")
}
