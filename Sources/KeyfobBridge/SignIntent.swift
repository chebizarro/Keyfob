import Foundation
#if canImport(AppIntents)
import AppIntents
import KeyfobCore
import KeyfobCrypto

@available(iOS 16.0, macOS 13.0, *)
public struct SignNostrEvent: AppIntent {
    public static var title: LocalizedStringResource = "Sign Nostr Event"

    @Parameter(title: "Event JSON")
    public var eventJSON: String

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // Parse event
        let data = eventJSON.data(using: .utf8) ?? Data()
        let evt = try JSONDecoder().decode(NostrEvent.self, from: data)
        let resp = try SignOrchestrator().prepareAndSign(event: evt, origin: "app.intent", mode: .perRequest)
        let json = String(data: try JSONEncoder().encode(resp), encoding: .utf8) ?? "{}"
        return .result(value: json)
    }
}
#endif
