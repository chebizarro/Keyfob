import Foundation
import LocalAuthentication

public final class PolicyEngine {
    public static let shared = PolicyEngine()
    private init() {}

    // App Group container identifier
    private let appGroup = "group.com.yourorg.keyfob"

    public enum ConsentMode: String, Codable { case perRequest, session }

    // MARK: - Models
    public enum OriginStatus: String, Codable { case unknown, allowed, denied }
    public struct OriginRecord: Codable {
        public var status: OriginStatus
        public var allowUntil: Date?
        public var lastUsed: Date?
        public var defaultMode: ConsentMode = .perRequest
        public init(status: OriginStatus = .unknown, allowUntil: Date? = nil, lastUsed: Date? = nil, defaultMode: ConsentMode = .perRequest) {
            self.status = status
            self.allowUntil = allowUntil
            self.lastUsed = lastUsed
            self.defaultMode = defaultMode
        }
    }

    // MARK: - Origin Registry
    private var origins: [String: OriginRecord] = [:]
    private let originsFile = "origin_registry.json"

    // MARK: - Caller Allowlist (for XPC/macOS)
    private var allowedCallers: Set<String> = []
    private let callersFile = "caller_allowlist.json"

    // MARK: - Session Manager
    private struct SessionKey: Hashable { let origin: String; let pubkey: String }
    private var sessions: [SessionKey: Date] = [:] // expiry per session
    private var defaultSessionTTL: TimeInterval = 5 * 60 // 5 minutes

    // MARK: - Rate Limiter (token bucket per origin)
    private struct Bucket { var tokens: Double; var lastRefill: Date }
    private var buckets: [String: Bucket] = [:]
    private let capacity: Double = 10
    private let refillPerSecond: Double = 1

    // MARK: - Consent Provider
    public protocol ConsentProvider: AnyObject {
        func requestConsent(origin: String, eventPreview: String, mode: ConsentMode) throws
    }
    public weak var consentProvider: ConsentProvider?

    public func preflight(origin: String) throws {
        // Rate limit
        try checkRateLimit(for: origin)
        // Load origins lazily
        if origins.isEmpty { loadOrigins() }
    }

    public func requestConsent(origin: String, eventPreview: String, mode: ConsentMode) throws {
        // Determine if session covers this request
        if let rec = origins[origin], rec.status == .allowed, let until = rec.allowUntil, until > Date(), mode == .session {
            // Session auto-approve; biometric check at session start only (apps should enforce)
            return
        }
        // Consult provider if available; otherwise require biometry as minimal gating
        if let provider = consentProvider {
            try provider.requestConsent(origin: origin, eventPreview: eventPreview, mode: mode)
        } else {
            let ctx = LAContext()
            var error: NSError?
            guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
                throw error ?? NSError(domain: "Policy", code: -1)
            }
        }
    }

    public func recordSuccess(origin: String) {
        // Update lastUsed and persist
        var rec = origins[origin] ?? OriginRecord()
        rec.lastUsed = Date()
        origins[origin] = rec
        saveOrigins()
    }

    // MARK: - Public helpers
    public func allow(origin: String, duration: TimeInterval, defaultMode: ConsentMode = .session) {
        var rec = origins[origin] ?? OriginRecord()
        rec.status = .allowed
        rec.allowUntil = Date().addingTimeInterval(duration)
        rec.defaultMode = defaultMode
        origins[origin] = rec
        saveOrigins()
    }

    public func deny(origin: String) {
        origins[origin] = OriginRecord(status: .denied, allowUntil: nil, lastUsed: Date())
        saveOrigins()
    }

    // MARK: - Caller Allowlist (XPC)
    public func isCallerAllowed(_ bundleID: String) -> Bool {
        if allowedCallers.isEmpty { loadCallers() }
        return allowedCallers.contains(bundleID)
    }

    public func allowCaller(_ bundleID: String) {
        if allowedCallers.isEmpty { loadCallers() }
        allowedCallers.insert(bundleID)
        saveCallers()
    }

    public func removeCaller(_ bundleID: String) {
        if allowedCallers.isEmpty { loadCallers() }
        allowedCallers.remove(bundleID)
        saveCallers()
    }

    public func listAllowedCallers() -> [String] {
        if allowedCallers.isEmpty { loadCallers() }
        return Array(allowedCallers).sorted()
    }

    public func startSession(origin: String, pubkey: String, ttl: TimeInterval? = nil) {
        sessions[SessionKey(origin: origin, pubkey: pubkey)] = Date().addingTimeInterval(ttl ?? defaultSessionTTL)
    }

    public func hasValidSession(origin: String, pubkey: String) -> Bool {
        let key = SessionKey(origin: origin, pubkey: pubkey)
        if let exp = sessions[key] {
            if exp > Date() { return true }
            sessions.removeValue(forKey: key)
        }
        return false
    }

    // MARK: - Internal
    private func checkRateLimit(for origin: String) throws {
        let now = Date()
        var b = buckets[origin] ?? Bucket(tokens: capacity, lastRefill: now)
        let elapsed = now.timeIntervalSince(b.lastRefill)
        b.tokens = min(capacity, b.tokens + elapsed * refillPerSecond)
        b.lastRefill = now
        if b.tokens < 1.0 {
            buckets[origin] = b
            throw NSError(domain: "Policy", code: 429, userInfo: [NSLocalizedDescriptionKey: "rate-limited"])
        }
        b.tokens -= 1.0
        buckets[origin] = b
    }

    private func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    private func loadOrigins() {
        guard let url = containerURL()?.appendingPathComponent(originsFile) else { return }
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([String: OriginRecord].self, from: data) {
            origins = decoded
        }
    }

    private func saveOrigins() {
        guard let url = containerURL()?.appendingPathComponent(originsFile) else { return }
        if let data = try? JSONEncoder().encode(origins) {
            try? data.write(to: url)
        }
    }

    private func loadCallers() {
        guard let url = containerURL()?.appendingPathComponent(callersFile) else { return }
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([String].self, from: data) {
            allowedCallers = Set(decoded)
        }
    }

    private func saveCallers() {
        guard let url = containerURL()?.appendingPathComponent(callersFile) else { return }
        let arr = Array(allowedCallers).sorted()
        if let data = try? JSONEncoder().encode(arr) {
            try? data.write(to: url)
        }
    }
}
