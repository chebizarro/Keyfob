//
//  PermissionRule.swift
//
//
//  Created for Keyfob – kf-sxf
//

import Foundation

// MARK: - PermissionRule

/// A permission rule governing whether a specific operation from a specific
/// client should be allowed, prompted, or denied.
///
/// Rules are matched with priority:
/// 1. Exact match: (clientID, identityID, operationKind, eventKind)
/// 2. Wildcard eventKind: (clientID, identityID, operationKind, nil eventKind)
/// 3. Wildcard identity: (clientID, nil identityID, operationKind, eventKind)
/// 4. Double wildcard: (clientID, nil identityID, operationKind, nil eventKind)
///
/// The ``operationKind`` is a `String` matching `SignerOperationKind.rawValue`
/// from KeyfobCore (e.g. `"sign"`, `"nip44Encrypt"`). This avoids a circular
/// dependency between KeyfobPolicy and KeyfobCore.
public struct PermissionRule: Codable, Equatable, Sendable, Identifiable {

    public let id: UUID

    /// The client this rule applies to (matches ``ClientIdentity/id``).
    public let clientID: String

    /// The identity this rule applies to, or `nil` for any identity.
    public let identityID: UUID?

    /// The operation kind this rule governs (e.g. `"sign"`, `"nip44Encrypt"`).
    ///
    /// Maps to `SignerOperationKind.rawValue` in KeyfobCore.
    public let operationKind: String

    /// For `.sign` operations, the specific Nostr event kind, or `nil` for any kind.
    public let eventKind: Int?

    /// What to do when this rule matches.
    public let decision: Decision

    /// Whether this rule persists across app launches.
    public let scope: Scope

    /// When this rule expires, or `nil` for no expiration.
    ///
    /// Session-scoped rules should set this to a reasonable TTL.
    /// Persistent rules may be nil (never expires) or have a far-future date.
    public let expiresAt: Date?

    /// When this rule was created.
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        clientID: String,
        identityID: UUID? = nil,
        operationKind: String,
        eventKind: Int? = nil,
        decision: Decision,
        scope: Scope,
        expiresAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.clientID = clientID
        self.identityID = identityID
        self.operationKind = operationKind
        self.eventKind = eventKind
        self.decision = decision
        self.scope = scope
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }

    /// Whether this rule has expired.
    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    /// The specificity of this rule for matching priority (higher = more specific).
    ///
    /// - Exact identity + exact eventKind: 4
    /// - Exact identity + wildcard eventKind: 3
    /// - Wildcard identity + exact eventKind: 2
    /// - Wildcard identity + wildcard eventKind: 1
    var specificity: Int {
        var score = 0
        if identityID != nil { score += 2 }
        if eventKind != nil { score += 1 }
        return score + 1 // base score of 1
    }
}

// MARK: - Decision

extension PermissionRule {
    /// The action to take when a rule matches.
    public enum Decision: String, Codable, Sendable, CaseIterable {
        /// Silently approve the operation.
        case allow
        /// Show the consent prompt to the user.
        case prompt
        /// Silently deny the operation.
        case deny
    }
}

// MARK: - Scope

extension PermissionRule {
    /// How long a rule persists.
    public enum Scope: String, Codable, Sendable, CaseIterable {
        /// Expires when the app/extension terminates (or at `expiresAt`).
        case session
        /// Persists across launches until explicitly removed or expired.
        case persistent
    }
}

// MARK: - Rule Matching

extension PermissionRule {

    /// Evaluate a set of rules and return the decision from the most specific match.
    ///
    /// Rules are filtered to those matching the given criteria, then sorted by
    /// ``specificity`` (descending). The first non-expired rule's decision wins.
    /// Returns `nil` if no rule matches (caller should fall through to default behavior).
    ///
    /// - Parameters:
    ///   - rules: The candidate rules to evaluate.
    ///   - clientID: The requesting client's identifier.
    ///   - identityID: The identity being used, or `nil` if unknown.
    ///   - operationKind: The operation kind string (e.g. `"sign"`).
    ///   - eventKind: The Nostr event kind for `.sign` operations, or `nil`.
    /// - Returns: The decision from the highest-priority matching rule, or `nil`.
    public static func evaluate(
        rules: [PermissionRule],
        clientID: String,
        identityID: UUID?,
        operationKind: String,
        eventKind: Int?
    ) -> Decision? {
        let now = Date()

        let matching = rules
            .filter { rule in
                // Must match client.
                guard rule.clientID == clientID else { return false }
                // Must match operation kind.
                guard rule.operationKind == operationKind else { return false }
                // Must not be expired.
                if let exp = rule.expiresAt, exp <= now { return false }
                // Identity: rule's identityID must be nil (wildcard) or match.
                if let ruleIdentity = rule.identityID, ruleIdentity != identityID {
                    return false
                }
                // EventKind: rule's eventKind must be nil (wildcard) or match.
                if let ruleEventKind = rule.eventKind, ruleEventKind != eventKind {
                    return false
                }
                return true
            }
            .sorted { $0.specificity > $1.specificity }

        return matching.first?.decision
    }
}
