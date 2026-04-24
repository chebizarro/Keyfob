import Foundation

// MARK: - Audit Entry

/// A single audit log entry recording a policy decision.
public struct AuditEntry: Codable, Equatable, Sendable {
    /// The action/outcome recorded by the policy engine.
    public enum Action: String, Codable, Sendable {
        case approved
        case denied
        case sessionAutoApproved
        case rateLimited
        case noProvider
        /// Rule-based auto-approve (no user prompt).
        case ruleAutoApproved
        /// Rule-based auto-deny (no user prompt).
        case ruleAutoDenied
    }

    /// ISO-8601 timestamp of when the event occurred.
    public let timestamp: Date
    /// The requesting origin (client ID, domain, or bundle ID).
    public let origin: String
    /// The policy decision.
    public let action: Action
    /// Nostr event kind, if available (for sign operations).
    public let eventKind: Int?
    /// Optional human-readable detail (e.g. denial reason, consent mode).
    public let detail: String?
    /// Wall-clock duration of the operation in milliseconds, if measured.
    /// Typically recorded on approved/denied entries to capture end-to-end
    /// signing latency including consent UI time.
    public let durationMs: Int?

    /// The type of cryptographic operation performed.
    ///
    /// Maps to `SignerOperationKind.rawValue` (e.g. `"sign"`, `"nip44Encrypt"`,
    /// `"nip44Decrypt"`, `"nip04Encrypt"`, `"nip04Decrypt"`).
    /// `nil` for legacy entries that predate this field.
    public let operationType: String?

    /// The counterparty public key hex for encrypt/decrypt operations.
    ///
    /// Identifies who the user was encrypting to or decrypting from.
    /// `nil` for sign operations or legacy entries.
    public let counterpartyPubkey: String?

    /// The public key hex of the identity used for this operation.
    ///
    /// `nil` for legacy entries or rate-limited requests (where no identity was resolved).
    public let identityUsed: String?

    public init(
        timestamp: Date = Date(),
        origin: String,
        action: Action,
        eventKind: Int? = nil,
        detail: String? = nil,
        durationMs: Int? = nil,
        operationType: String? = nil,
        counterpartyPubkey: String? = nil,
        identityUsed: String? = nil
    ) {
        self.timestamp = timestamp
        self.origin = origin
        self.action = action
        self.eventKind = eventKind
        self.detail = detail
        self.durationMs = durationMs
        self.operationType = operationType
        self.counterpartyPubkey = counterpartyPubkey
        self.identityUsed = identityUsed
    }
}

// MARK: - Audit Log

/// Append-only audit log stored as JSON Lines in the App Group container.
///
/// Thread-safe. Each line in the backing file is a self-contained JSON object,
/// making appends safe even if the process is interrupted mid-write.
///
/// Usage:
/// ```swift
/// let log = AuditLog(containerURL: myGroupURL)
/// log.log(AuditEntry(origin: "example.com", action: .approved))
/// let recent = log.entries(limit: 50)
/// ```
public final class AuditLog {

    /// Default maximum entries before the log is auto-trimmed on next append.
    /// Keeps the file from growing unbounded on long-running installations.
    public static let defaultMaxEntries = 10_000

    // MARK: - Private State

    private let queue = DispatchQueue(label: "com.keyfob.audit-log", qos: .utility)
    private let fileURL: URL
    private let maxEntries: Int

    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [] // single-line, no pretty print
        return enc
    }()

    private let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    // MARK: - Init

    /// Create an audit log backed by a file in the given directory.
    ///
    /// - Parameters:
    ///   - containerURL: Directory URL (typically the App Group container).
    ///                   Pass `nil` to create a disabled (no-op) log.
    ///   - filename: Log filename (default: `audit_log.jsonl`).
    ///   - maxEntries: Maximum entries before auto-trim (default: 10 000).
    public init(containerURL: URL?, filename: String = "audit_log.jsonl", maxEntries: Int = AuditLog.defaultMaxEntries) {
        if let dir = containerURL {
            self.fileURL = dir.appendingPathComponent(filename)
        } else {
            // Fallback: tmp directory so calls don't crash, but data is ephemeral
            self.fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        }
        self.maxEntries = maxEntries

        // Ensure parent directory exists
        let dir = self.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Append an entry to the audit log.
    public func log(_ entry: AuditEntry) {
        queue.sync {
            _append(entry)
        }
    }

    /// Read the most recent entries.
    ///
    /// - Parameter limit: Maximum number of entries to return (default: 100).
    ///                    Entries are returned in chronological order (oldest first).
    /// - Returns: Array of audit entries, up to `limit` most recent.
    public func entries(limit: Int = 100) -> [AuditEntry] {
        queue.sync {
            _readAll().suffix(limit).map { $0 }
        }
    }

    /// Total number of entries in the log.
    public var entryCount: Int {
        queue.sync {
            _readAll().count
        }
    }

    /// Remove all entries. Intended for user-initiated privacy clearing or tests.
    public func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Read entries filtered by origin.
    public func entries(forOrigin origin: String, limit: Int = 100) -> [AuditEntry] {
        queue.sync {
            _readAll()
                .filter { $0.origin == origin }
                .suffix(limit)
                .map { $0 }
        }
    }

    /// Read entries filtered by action.
    public func entries(withAction action: AuditEntry.Action, limit: Int = 100) -> [AuditEntry] {
        queue.sync {
            _readAll()
                .filter { $0.action == action }
                .suffix(limit)
                .map { $0 }
        }
    }

    /// Read entries filtered by operation type (e.g. `"sign"`, `"nip44Encrypt"`).
    public func entries(forOperationType operationType: String, limit: Int = 100) -> [AuditEntry] {
        queue.sync {
            _readAll()
                .filter { $0.operationType == operationType }
                .suffix(limit)
                .map { $0 }
        }
    }

    /// Read entries filtered by counterparty public key.
    public func entries(forCounterparty pubkeyHex: String, limit: Int = 100) -> [AuditEntry] {
        queue.sync {
            _readAll()
                .filter { $0.counterpartyPubkey == pubkeyHex }
                .suffix(limit)
                .map { $0 }
        }
    }

    // MARK: - Internal (called under queue.sync)

    private func _append(_ entry: AuditEntry) {
        guard let jsonData = try? encoder.encode(entry),
              var line = String(data: jsonData, encoding: .utf8) else {
            return
        }
        line += "\n"

        if FileManager.default.fileExists(atPath: fileURL.path) {
            // Append to existing file
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
        } else {
            // Create new file
            try? line.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        }

        // Auto-trim if over capacity
        _trimIfNeeded()
    }

    private func _readAll() -> [AuditEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        return lines.compactMap { line in
            guard let lineData = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(AuditEntry.self, from: lineData)
        }
    }

    private func _trimIfNeeded() {
        let all = _readAll()
        guard all.count > maxEntries else { return }
        // Keep the most recent entries (drop oldest)
        let kept = Array(all.suffix(maxEntries / 2))
        _rewrite(kept)
    }

    private func _rewrite(_ entries: [AuditEntry]) {
        let lines = entries.compactMap { entry -> String? in
            guard let data = try? encoder.encode(entry) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let content = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try? content.data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }
}
