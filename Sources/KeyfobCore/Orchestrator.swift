import Foundation
import KeyfobCrypto
import KeyfobPolicy

public final class SignOrchestrator {
    public enum Mode { case perRequest, session }
    public init() {}

    public func prepareAndSign(event: NostrEvent, origin: String, mode: Mode) throws -> SignatureResponse {
        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            // Policy checks
            try PolicyEngine.shared.preflight(origin: origin)
            let json = try CanonicalJSON.serializeEvent(event)
            // Compute id via crypto (Signer will compute from JSON)
            // Consent & session handled by PolicyEngine; blocking call
            let consentMode: PolicyEngine.ConsentMode = (mode == .perRequest) ? .perRequest : .session
            try PolicyEngine.shared.requestConsent(origin: origin, eventPreview: json, mode: consentMode)
            let resp = try Signer().signEvent(eventJSON: json)
            PolicyEngine.shared.recordSuccess(origin: origin)

            // Record successful signing with end-to-end duration
            let durationMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            PolicyEngine.shared.auditLog.log(AuditEntry(
                origin: origin,
                action: .approved,
                eventKind: event.kind,
                detail: "sign completed, mode=\(mode)",
                durationMs: durationMs
            ))

            return resp
        } catch {
            // Record failed signing with end-to-end duration
            let durationMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            PolicyEngine.shared.auditLog.log(AuditEntry(
                origin: origin,
                action: .denied,
                eventKind: event.kind,
                detail: "sign failed: \(error.localizedDescription)",
                durationMs: durationMs
            ))
            throw error
        }
    }
}
