//
//  PolicyPreset.swift
//
//
//  Created for Keyfob – kf-w5x
//

import Foundation

// MARK: - PolicyPreset

/// A named security preset that generates a set of ``PermissionRule`` instances.
///
/// Presets provide sensible defaults for common use cases. Users can select a
/// preset during onboarding or from settings, then customize individual rules.
///
/// ## Available Presets
///
/// - **basic**: Auto-approve common social operations (text notes, metadata,
///   contacts); prompt for DMs and custom kinds. Good for users who want
///   minimal friction with trusted clients.
///
/// - **standard**: Prompt for all signing; auto-approve NIP-44 encrypt/decrypt
///   for any client. Balances security with usability.
///
/// - **paranoid**: Prompt for every operation, no auto-approval. Maximum
///   security for users who want to verify every action.
public enum PolicyPreset: String, Codable, Sendable, CaseIterable {
    case basic
    case standard
    case paranoid

    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .basic: return "Basic"
        case .standard: return "Standard"
        case .paranoid: return "Paranoid"
        }
    }

    /// Short description of this preset's philosophy.
    public var description: String {
        switch self {
        case .basic:
            return "Auto-approve common social events (notes, metadata, contacts). Prompt for DMs and unusual kinds."
        case .standard:
            return "Prompt for all signing. Auto-approve encryption for any client."
        case .paranoid:
            return "Prompt for every operation. Maximum security."
        }
    }

    /// Generate permission rules for a given client.
    ///
    /// Rules are created as persistent and non-expiring. The caller can modify
    /// scope or expiry after generation.
    ///
    /// - Parameters:
    ///   - clientID: The client identifier these rules apply to.
    ///   - identityID: The identity these rules apply to, or `nil` for all identities.
    /// - Returns: The set of rules that implement this preset.
    public func rules(
        forClient clientID: String,
        identityID: UUID? = nil
    ) -> [PermissionRule] {
        switch self {
        case .basic:
            return Self.basicRules(clientID: clientID, identityID: identityID)
        case .standard:
            return Self.standardRules(clientID: clientID, identityID: identityID)
        case .paranoid:
            return Self.paranoidRules(clientID: clientID, identityID: identityID)
        }
    }

    /// Apply this preset's rules to a ``PermissionRuleStore``, replacing any
    /// existing rules for the given client.
    ///
    /// - Parameters:
    ///   - store: The rule store to update.
    ///   - clientID: The client to apply the preset to.
    ///   - identityID: The identity to scope rules to, or `nil` for all.
    public func apply(
        to store: PermissionRuleStore,
        forClient clientID: String,
        identityID: UUID? = nil
    ) throws {
        // Remove existing rules for this client first.
        try store.removeRules(forClient: clientID)

        // Add preset rules.
        let presetRules = rules(forClient: clientID, identityID: identityID)
        for rule in presetRules {
            try store.addRule(rule)
        }
    }
}

// MARK: - Preset Definitions

extension PolicyPreset {

    // Well-known Nostr event kinds for readable rule generation.
    private enum EventKinds {
        static let metadata = 0
        static let textNote = 1
        static let contacts = 3
        static let directMessage = 4
        static let repost = 6
        static let reaction = 7
        static let channelMessage = 42
    }

    // MARK: - Basic

    /// Basic preset: auto-approve common social events, prompt for everything else.
    ///
    /// Auto-approved signing: kind 0 (metadata), kind 1 (text note), kind 3 (contacts),
    /// kind 6 (repost), kind 7 (reaction).
    /// Prompted: kind 4 (DM), kind 42 (channel message), all other kinds.
    /// Encryption: auto-approve NIP-44 encrypt/decrypt, prompt NIP-04.
    private static func basicRules(clientID: String, identityID: UUID?) -> [PermissionRule] {
        var rules: [PermissionRule] = []

        // Auto-approve common social signing kinds.
        let autoApproveKinds = [
            EventKinds.metadata,
            EventKinds.textNote,
            EventKinds.contacts,
            EventKinds.repost,
            EventKinds.reaction,
        ]
        for kind in autoApproveKinds {
            rules.append(PermissionRule(
                clientID: clientID,
                identityID: identityID,
                operationKind: "sign",
                eventKind: kind,
                decision: .allow,
                scope: .persistent
            ))
        }

        // Prompt for DMs (sensitive).
        rules.append(PermissionRule(
            clientID: clientID,
            identityID: identityID,
            operationKind: "sign",
            eventKind: EventKinds.directMessage,
            decision: .prompt,
            scope: .persistent
        ))

        // Auto-approve NIP-44 encrypt/decrypt (modern, expected for DMs).
        rules.append(PermissionRule(
            clientID: clientID,
            identityID: identityID,
            operationKind: "nip44Encrypt",
            decision: .allow,
            scope: .persistent
        ))
        rules.append(PermissionRule(
            clientID: clientID,
            identityID: identityID,
            operationKind: "nip44Decrypt",
            decision: .allow,
            scope: .persistent
        ))

        // Prompt for legacy NIP-04 (deprecated, user should be aware).
        rules.append(PermissionRule(
            clientID: clientID,
            identityID: identityID,
            operationKind: "nip04Encrypt",
            decision: .prompt,
            scope: .persistent
        ))
        rules.append(PermissionRule(
            clientID: clientID,
            identityID: identityID,
            operationKind: "nip04Decrypt",
            decision: .prompt,
            scope: .persistent
        ))

        return rules
    }

    // MARK: - Standard

    /// Standard preset: prompt for all signing, auto-approve modern encryption.
    ///
    /// All signing: prompted (no event kind auto-approval).
    /// NIP-44: auto-approve encrypt/decrypt.
    /// NIP-04: prompted.
    private static func standardRules(clientID: String, identityID: UUID?) -> [PermissionRule] {
        var rules: [PermissionRule] = []

        // Wildcard sign rule: prompt for all event kinds.
        rules.append(PermissionRule(
            clientID: clientID,
            identityID: identityID,
            operationKind: "sign",
            decision: .prompt,
            scope: .persistent
        ))

        // Auto-approve NIP-44 encrypt/decrypt.
        rules.append(PermissionRule(
            clientID: clientID,
            identityID: identityID,
            operationKind: "nip44Encrypt",
            decision: .allow,
            scope: .persistent
        ))
        rules.append(PermissionRule(
            clientID: clientID,
            identityID: identityID,
            operationKind: "nip44Decrypt",
            decision: .allow,
            scope: .persistent
        ))

        // Prompt for legacy NIP-04.
        rules.append(PermissionRule(
            clientID: clientID,
            identityID: identityID,
            operationKind: "nip04Encrypt",
            decision: .prompt,
            scope: .persistent
        ))
        rules.append(PermissionRule(
            clientID: clientID,
            identityID: identityID,
            operationKind: "nip04Decrypt",
            decision: .prompt,
            scope: .persistent
        ))

        return rules
    }

    // MARK: - Paranoid

    /// Paranoid preset: prompt for everything. No auto-approvals.
    ///
    /// All operations (sign, NIP-44, NIP-04) require explicit consent.
    private static func paranoidRules(clientID: String, identityID: UUID?) -> [PermissionRule] {
        var rules: [PermissionRule] = []

        let allOps = ["sign", "nip44Encrypt", "nip44Decrypt", "nip04Encrypt", "nip04Decrypt"]
        for op in allOps {
            rules.append(PermissionRule(
                clientID: clientID,
                identityID: identityID,
                operationKind: op,
                decision: .prompt,
                scope: .persistent
            ))
        }

        return rules
    }
}
