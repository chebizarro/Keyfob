// ──────────────────────────────────────────────────────────────────
// ReconnectPolicy.swift — Exponential backoff with jitter for relay reconnect
// ──────────────────────────────────────────────────────────────────

import Foundation

/// Configurable reconnect policy with exponential backoff and jitter.
///
/// Backoff schedule: `baseDelay * multiplier^attempt`, capped at `maxDelay`,
/// with ±`jitterFraction` randomization. Resets after a connection stays
/// stable for `stableThreshold` seconds.
public struct ReconnectPolicy: Sendable, Equatable {

    /// Whether auto-reconnect is enabled.
    public var isEnabled: Bool

    /// Initial backoff delay in seconds.
    public var baseDelay: TimeInterval

    /// Maximum backoff delay in seconds.
    public var maxDelay: TimeInterval

    /// Multiplier applied per attempt.
    public var multiplier: Double

    /// Fraction of the delay used for random jitter (±).
    /// E.g., 0.25 means the actual delay varies by ±25%.
    public var jitterFraction: Double

    /// Seconds a connection must stay up before the backoff counter resets.
    public var stableThreshold: TimeInterval

    /// Current attempt counter (visible for testing; mutated by `nextDelay()`).
    public private(set) var attempt: Int

    // MARK: - Presets

    /// Default policy: 1s → 2s → 4s → 8s → 16s → 30s cap, ±25% jitter.
    public static let `default` = ReconnectPolicy()

    /// Reconnect disabled.
    public static let disabled = ReconnectPolicy(isEnabled: false)

    // MARK: - Init

    public init(
        isEnabled: Bool = true,
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 30.0,
        multiplier: Double = 2.0,
        jitterFraction: Double = 0.25,
        stableThreshold: TimeInterval = 30.0
    ) {
        self.isEnabled = isEnabled
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.multiplier = multiplier
        self.jitterFraction = jitterFraction
        self.stableThreshold = stableThreshold
        self.attempt = 0
    }

    // MARK: - API

    /// Calculate the next backoff delay (seconds) and increment the attempt counter.
    ///
    /// The raw delay is `baseDelay * multiplier^attempt` capped at `maxDelay`,
    /// then randomized by ±`jitterFraction`.
    public mutating func nextDelay() -> TimeInterval {
        let raw = min(baseDelay * pow(multiplier, Double(attempt)), maxDelay)
        let jitter = raw * jitterFraction * Double.random(in: -1...1)
        attempt += 1
        return max(0.01, raw + jitter)
    }

    /// Calculate the raw delay for the current attempt (no jitter, no increment).
    /// Useful for testing.
    public func rawDelay() -> TimeInterval {
        return min(baseDelay * pow(multiplier, Double(attempt)), maxDelay)
    }

    /// Reset the backoff counter. Call after a connection has been stable.
    public mutating func reset() {
        attempt = 0
    }

    /// Check whether the connection was stable long enough to reset backoff.
    /// - Parameter connectedSince: The time the connection was established.
    /// - Returns: `true` if the connection exceeded the stable threshold.
    public func isStable(connectedSince: Date) -> Bool {
        return Date().timeIntervalSince(connectedSince) >= stableThreshold
    }
}
