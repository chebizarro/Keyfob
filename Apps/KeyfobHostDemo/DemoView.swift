import SwiftUI
#if canImport(AppIntents)
import AppIntents
#endif
import KeyfobBridge

struct DemoView: View {
    @State private var eventJSON: String = "{\"kind\":1,\"pubkey\":\"\",\"created_at\":0,\"tags\":[],\"content\":\"hello from demo\"}"
    @State private var callbackResult: String = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Event JSON")) {
                    TextEditor(text: $eventJSON).frame(minHeight: 160)
                }
                Section(header: Text("Actions")) {
                    Button("Sign via keyfob:// URL scheme") { signViaURLScheme() }
                    if #available(iOS 16.0, *) {
                        Button("Sign via App Intent (Shortcuts)") { signViaAppIntent() }
                        Button("Sign via App Intent (Direct)") { signViaAppIntentDirect() }
                    }
                }
                Section(header: Text("Callback Result")) {
                    Text(callbackResult).font(.footnote)
                }
                if #available(iOS 16.0, *) {
                    Section(footer: Text("App Intent signing uses Shortcuts to invoke Keyfob's App Intent. Ensure the App Shortcut exists in the Shortcuts app.").font(.footnote)) {
                        EmptyView()
                    }
                }
            }
            .navigationTitle("Keyfob Demo")
        }
        .onOpenURL { url in
            guard url.scheme == "keyfobdemo" else { return }
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                let ok = q["ok"] == "1"
                if ok {
                    let id = q["id"] ?? ""
                    let sig = q["sig"] ?? ""
                    let pub = q["pubkey"] ?? ""
                    callbackResult = "OK\n id=\(id)\n sig=\(sig)\n pubkey=\(pub)"
                } else {
                    callbackResult = "ERR \(q["code"] ?? "") : \(q["msg"] ?? "")"
                }
            }
        }
    }

    private func signViaURLScheme() {
        guard let jsonData = eventJSON.data(using: .utf8) else { return }
        let b64 = jsonData
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let cb = "keyfobdemo://done"
        let origin = "com.example.demo"
        let urlStr = "keyfob://sign?payload=\(b64)&cb=\(cb)&origin=\(origin)"
        if let url = URL(string: urlStr) {
            UIApplication.shared.open(url)
        }
    }

    @available(iOS 16.0, *)
    private func signViaAppIntent() {
        // Attempt to run a Shortcut that calls Keyfob's App Intent
        // Users can create a Shortcut named "Sign Nostr Event" that passes the provided text to the App Intent input field
        let shortcutName = "Sign Nostr Event"
        let encodedName = shortcutName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? shortcutName
        let encodedText = eventJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? eventJSON
        let urlStr = "shortcuts://run-shortcut?name=\(encodedName)&input=text&text=\(encodedText)"
        if let url = URL(string: urlStr) {
            UIApplication.shared.open(url)
        }
    }

    @available(iOS 16.0, *)
    private func signViaAppIntentDirect() {
        let json = eventJSON
        Task {
            do {
                var intent = SignNostrEvent()
                intent.eventJSON = json
                let result = try await intent.perform()
                if let container = result as? IntentResultContainer<String, Never, Never, Never> {
                    let value = container.value
                    callbackResult = value
                } else {
                    callbackResult = "App Intent returned unexpected type."
                }
            } catch {
                callbackResult = "App Intent error: \(error.localizedDescription)"
            }
        }
    }
}
