// ──────────────────────────────────────────────────────────────────
// PublishInspector.swift — OK response inspection with retry logic
// ──────────────────────────────────────────────────────────────────

import Foundation

// MARK: - OK Rejection Category

/// Categorized rejection reason from a relay OK(false) response.
public enum OKRejection: Sendable, Equatable {
    /// Event already stored — benign, no action needed.
    case duplicate(String)
    /// Relay blocked the event — do not retry.
    case blocked(String)
    /// Relay rate-limited — backoff then retry once.
    case rateLimited(String)
    /// Event is invalid (bad signature, schema, etc.) — do not retry.
    case invalid(String)
    /// Relay internal error — retry with exponential backoff.
    case error(String)
    /// Relay requires authentication — trigger NIP-42 AUTH, then retry.
    case authRequired(String)
    /// Unknown rejection prefix.
    case other(String)

    /// Parse an OK message string into a categorized rejection.
    public static func parse(_ message: String) -> OKRejection {
        if message.hasPrefix("duplicate:") { return .duplicate(message) }
        if message.hasPrefix("blocked:") { return .blocked(message) }
        if message.hasPrefix("rate-limited:") { return .rateLimited(message) }
        if message.hasPrefix("invalid:") { return .invalid(message) }
        if message.hasPrefix("error:") { return .error(message) }
        if message.hasPrefix("auth-required:") { return .authRequired(message) }
        return .other(message)
    }

    /// The raw message string.
    public var message: String {
        switch self {
        case .duplicate(let m), .blocked(let m), .rateLimited(let m),
             .invalid(let m), .error(let m), .authRequired(let m), .other(let m):
            return m
        }
    }

    /// Whether this rejection type permits a retry.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .error, .authRequired: return true
        case .duplicate, .blocked, .invalid, .other: return false
        }
    }
}

// MARK: - Publish Outcome

/// Final outcome of a smart publish operation.
public enum PublishOutcome: Sendable, Equatable {
    /// Relay accepted the event (OK true), or duplicate (benign).
    case accepted
    /// Relay rejected the event after all retry attempts exhausted.
    case rejected(OKRejection)
    /// No OK response received within the timeout window.
    case timeout
}

// MARK: - Publish Inspector

/// Publishes events with OK inspection, categorized rejection handling,
/// automatic retry for transient failures, and configurable timeout.
///
/// Wraps `RelayConnection.publish()` with:
/// - 15-second OK timeout (configurable)
/// - `duplicate:` treated as accepted (benign)
/// - `rate-limited:` → backoff then retry once
/// - `error:` → exponential backoff, up to 3 retries
/// - `auth-required:` → wait for NIP-42 auth, then retry once
/// - `blocked:` / `invalid:` → no retry
/// - Callback for audit logging of every publish outcome
public final class PublishInspector: @unchecked Sendable {

    private let connection: RelayConnection

    // MARK: - Configuration

    /// Timeout for waiting for OK response. Default: 15s.
    public var publishTimeout: TimeInterval = 15.0

    /// Backoff before retrying after rate-limit rejection. Default: 3s.
    public var rateLimitBackoff: TimeInterval = 3.0

    /// Maximum retry attempts for `error:` rejections. Default: 3.
    public var errorMaxRetries: Int = 3

    /// Base backoff for `error:` retries (doubles each attempt). Default: 1s.
    public var errorBaseBackoff: TimeInterval = 1.0

    /// How long to wait for NIP-42 auth to complete before giving up. Default: 15s.
    public var authWaitTimeout: TimeInterval = 15.0

    /// Called after every publish attempt resolves. Use for audit logging.
    /// Parameters: (event, outcome, attempt number starting at 1).
    public var onPublishResult: (@Sendable (RelayEvent, PublishOutcome, Int) -> Void)?

    // MARK: - Init

    public init(connection: RelayConnection) {
        self.connection = connection
    }

    // MARK: - Publish

    /// Publish an event with OK inspection, retry logic, and timeout.
    ///
    /// - Parameter event: A signed `RelayEvent` to publish.
    /// - Returns: The final `PublishOutcome` after any retries.
    public func publish(event: RelayEvent) async -> PublishOutcome {
        var attempt = 0

        while true {
            attempt += 1

            // Publish with timeout
            let okResult: OKResult
            do {
                okResult = try await publishWithTimeout(event: event)
            } catch {
                let outcome = PublishOutcome.timeout
                onPublishResult?(event, outcome, attempt)
                return outcome
            }

            // Accepted
            if okResult.accepted {
                let outcome = PublishOutcome.accepted
                onPublishResult?(event, outcome, attempt)
                return outcome
            }

            // Rejected — categorize
            let rejection = OKRejection.parse(okResult.message)

            // Duplicate is benign — treat as accepted
            if case .duplicate = rejection {
                let outcome = PublishOutcome.accepted
                onPublishResult?(event, outcome, attempt)
                return outcome
            }

            // Determine retry behavior
            switch rejection {
            case .rateLimited:
                guard attempt <= 1 else {
                    return finalize(event: event, rejection: rejection, attempt: attempt)
                }
                do {
                    try await Task.sleep(nanoseconds: UInt64(rateLimitBackoff * 1_000_000_000))
                } catch {
                    let outcome = PublishOutcome.timeout
                    onPublishResult?(event, outcome, attempt)
                    return outcome
                }
                continue

            case .error:
                guard attempt <= errorMaxRetries else {
                    return finalize(event: event, rejection: rejection, attempt: attempt)
                }
                let backoff = errorBaseBackoff * pow(2.0, Double(attempt - 1))
                do {
                    try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                } catch {
                    let outcome = PublishOutcome.timeout
                    onPublishResult?(event, outcome, attempt)
                    return outcome
                }
                continue

            case .authRequired:
                guard attempt <= 1 else {
                    return finalize(event: event, rejection: rejection, attempt: attempt)
                }
                let authed = await waitForAuth()
                if authed { continue }
                return finalize(event: event, rejection: rejection, attempt: attempt)

            case .blocked, .invalid, .other, .duplicate:
                return finalize(event: event, rejection: rejection, attempt: attempt)
            }

        }
    }

    // MARK: - Internals

    private func finalize(event: RelayEvent, rejection: OKRejection, attempt: Int) -> PublishOutcome {
        let outcome = PublishOutcome.rejected(rejection)
        onPublishResult?(event, outcome, attempt)
        return outcome
    }

    /// Wraps `RelayConnection.publish()` with a timeout.
    /// Uses a continuation-based race to avoid deadlock when the publish
    /// task's own continuation doesn't respond to Swift task cancellation.
    private func publishWithTimeout(event: RelayEvent) async throws -> OKResult {
        try await withCheckedThrowingContinuation { continuation in
            let once = _PublishOnce()

            // Publish task
            Task {
                do {
                    let result = try await self.connection.publish(event: event)
                    if once.claim() {
                        continuation.resume(returning: result)
                    }
                } catch {
                    if once.claim() {
                        continuation.resume(throwing: error)
                    }
                }
            }

            // Timeout task
            Task {
                try? await Task.sleep(nanoseconds: UInt64(self.publishTimeout * 1_000_000_000))
                if once.claim() {
                    continuation.resume(throwing: PublishTimeoutError())
                }
            }
        }
    }

    /// Wait for NIP-42 auth to reach `.authenticated` or `.failed`.
    private func waitForAuth() async -> Bool {
        let deadline = Date().addingTimeInterval(authWaitTimeout)
        while Date() < deadline {
            switch connection.authState {
            case .authenticated:
                return true
            case .failed:
                return false
            case .notRequired, .challenged, .authenticating:
                do {
                    try await Task.sleep(nanoseconds: 100_000_000) // 100ms poll
                } catch {
                    return false
                }
            }
        }
        return false
    }
}

// MARK: - Internal Helpers

private struct PublishTimeoutError: Error {}

/// Thread-safe one-shot gate: exactly one caller gets `true` from `claim()`.
private final class _PublishOnce: @unchecked Sendable {
    private var _claimed = false
    private let _lock = NSLock()

    func claim() -> Bool {
        _lock.lock()
        defer { _lock.unlock() }
        if _claimed { return false }
        _claimed = true
        return true
    }
}
