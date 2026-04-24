import Foundation
import LocalAuthentication

public final class PolicyEngine {
    public static let shared = PolicyEngine()

    private init() {
        let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PolicyEngine.resolvedAppGroup
        )
        self.auditLog = AuditLog(containerURL: containerURL)
    }

    /// Test-only initializer that accepts a custom audit log.
    internal init(auditLog: AuditLog) {
        self.auditLog = auditLog
    }

    private static let resolvedAppGroup: String = {
        if let override = Bundle.main.infoDictionary?["KEYFOB_APP_GROUP"] as? String, !override.isEmpty {
            return override
        }
        return "group.com.example.keyfob"
    }()

    /// Serial queue protecting all mutable state.
    private let queue = DispatchQueue(label: "com.keyfob.policy-engine", qos: .userInitiated)

    // MARK: - Audit Log
    /// Append-only audit log recording all policy decisions.
    public let auditLog: AuditLog

    // MARK: - Permission Rules
    /// Rule store for per-client/per-kind permission rules.
    ///
    /// Set during initialization or injected for testing. When set,
    /// ``evaluatePermission(clientID:identityID:operationKind:eventKind:)``
    /// consults these rules before falling through to the consent prompt.
    public var ruleStore: PermissionRuleStore?

    // App Group container identifier — delegates to the static resolver.
    private var appGroup: String { Self.resolvedAppGroup }

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
        do {
            try queue.sync {
                // Rate limit
                try checkRateLimit(for: origin)
                // Load origins lazily
                if origins.isEmpty { loadOrigins() }
            }
        } catch {
            auditLog.log(AuditEntry(origin: origin, action: .rateLimited, detail: error.localizedDescription))
            throw error
        }
    }

    public func requestConsent(origin: String, eventPreview: String, mode: ConsentMode) throws {
        // Check session coverage under lock
        let sessionCovers: Bool = queue.sync {
            if let rec = origins[origin], rec.status == .allowed, let until = rec.allowUntil, until > Date(), mode == .session {
                return true
            }
            return false
        }
        if sessionCovers {
            auditLog.log(AuditEntry(origin: origin, action: .sessionAutoApproved, detail: "mode=\(mode.rawValue)"))
            return
        }

        // A real consent provider is required. Without one, we must not silently approve.
        guard let provider = consentProvider else {
            auditLog.log(AuditEntry(origin: origin, action: .noProvider))
            throw NSError(domain: "Policy", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "No consent provider configured. Cannot approve signing requests."])
        }

        do {
            try provider.requestConsent(origin: origin, eventPreview: eventPreview, mode: mode)
            auditLog.log(AuditEntry(origin: origin, action: .approved, detail: "mode=\(mode.rawValue)"))
        } catch {
            auditLog.log(AuditEntry(origin: origin, action: .denied, detail: error.localizedDescription))
            throw error
        }
    }

    // MARK: - Permission Rule Evaluation

    /// Evaluate permission rules for a request before showing a consent prompt.
    ///
    /// If a matching rule yields `.allow`, the operation proceeds without prompting.
    /// If it yields `.deny`, the operation is rejected without prompting.
    /// If it yields `.prompt` or no rule matches, returns `nil` (caller should
    /// fall through to the consent prompt).
    ///
    /// - Parameters:
    ///   - clientID: The requesting client's identifier.
    ///   - identityID: The identity UUID being used, or `nil`.
    ///   - operationKind: The operation kind string (e.g. `"sign"`).
    ///   - eventKind: The Nostr event kind for sign operations, or `nil`.
    /// - Returns: `.allow` or `.deny` for a definitive rule, `nil` for no match or `.prompt`.
    /// - Throws: If the rule store encounters a storage error.
    public func evaluatePermission(
        clientID: String,
        identityID: UUID? = nil,
        operationKind: String,
        eventKind: Int? = nil
    ) throws -> PermissionRule.Decision? {
        guard let store = ruleStore else { return nil }
        let decision = try store.evaluate(
            clientID: clientID,
            identityID: identityID,
            operationKind: operationKind,
            eventKind: eventKind
        )
        switch decision {
        case .allow:
            auditLog.log(AuditEntry(
                origin: clientID,
                action: .approved,
                eventKind: eventKind,
                detail: "rule:allow op=\(operationKind)"
            ))
            return .allow
        case .deny:
            auditLog.log(AuditEntry(
                origin: clientID,
                action: .denied,
                eventKind: eventKind,
                detail: "rule:deny op=\(operationKind)"
            ))
            return .deny
        case .prompt:
            return nil // Fall through to consent prompt.
        case nil:
            return nil // No matching rule.
        }
    }

    public func recordSuccess(origin: String) {
        queue.sync {
            var rec = origins[origin] ?? OriginRecord()
            rec.lastUsed = Date()
            origins[origin] = rec
            saveOrigins()
        }
    }

    // MARK: - Public helpers
    public func allow(origin: String, duration: TimeInterval, defaultMode: ConsentMode = .session) {
        queue.sync {
            var rec = origins[origin] ?? OriginRecord()
            rec.status = .allowed
            rec.allowUntil = Date().addingTimeInterval(duration)
            rec.defaultMode = defaultMode
            origins[origin] = rec
            saveOrigins()
        }
    }

    public func deny(origin: String) {
        queue.sync {
            origins[origin] = OriginRecord(status: .denied, allowUntil: nil, lastUsed: Date())
            saveOrigins()
        }
    }

    // MARK: - Caller Allowlist (XPC)
    public func isCallerAllowed(_ bundleID: String) -> Bool {
        queue.sync {
            if allowedCallers.isEmpty { loadCallers() }
            return allowedCallers.contains(bundleID)
        }
    }

    public func allowCaller(_ bundleID: String) {
        queue.sync {
            if allowedCallers.isEmpty { loadCallers() }
            allowedCallers.insert(bundleID)
            saveCallers()
        }
    }

    public func removeCaller(_ bundleID: String) {
        queue.sync {
            if allowedCallers.isEmpty { loadCallers() }
            allowedCallers.remove(bundleID)
            saveCallers()
        }
    }

    public func listAllowedCallers() -> [String] {
        queue.sync {
            if allowedCallers.isEmpty { loadCallers() }
            return Array(allowedCallers).sorted()
        }
    }

    public func startSession(origin: String, pubkey: String, ttl: TimeInterval? = nil) {
        queue.sync {
            sessions[SessionKey(origin: origin, pubkey: pubkey)] = Date().addingTimeInterval(ttl ?? defaultSessionTTL)
        }
    }

    public func hasValidSession(origin: String, pubkey: String) -> Bool {
        queue.sync {
            let key = SessionKey(origin: origin, pubkey: pubkey)
            if let exp = sessions[key] {
                if exp > Date() { return true }
                sessions.removeValue(forKey: key)
            }
            return false
        }
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
