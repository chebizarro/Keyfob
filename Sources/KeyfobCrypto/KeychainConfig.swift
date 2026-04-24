//
//  KeychainConfig.swift
//
//
//  Created for Keyfob – kf-3kr
//

import Foundation

/// Shared Keychain and app-group configuration for KeyfobCrypto.
///
/// Centralizes constants that both ``KeyManager`` (legacy single-key)
/// and ``KeychainIdentityStore`` (multi-identity) use, ensuring
/// consistent access group and service naming.
public enum KeychainConfig {

    /// Keychain service name for all Keyfob keys.
    public static let service = "keyfob"

    /// Keychain access group, resolved from Info.plist or falling back to a placeholder.
    ///
    /// Production builds MUST set `KEYFOB_KEYCHAIN_ACCESS_GROUP` in their Info.plist
    /// to the actual App Group identifier (e.g. `TEAMID.com.keyfob.shared`).
    public static let accessGroup: String = {
        if let override = Bundle.main.infoDictionary?["KEYFOB_KEYCHAIN_ACCESS_GROUP"] as? String, !override.isEmpty {
            return override
        }
        return "TEAMID.com.example.keyfob.shared"
    }()

    /// App group identifier for shared container (metadata file storage).
    ///
    /// Production builds MUST set `KEYFOB_APP_GROUP` in their Info.plist.
    public static let appGroup: String = {
        if let override = Bundle.main.infoDictionary?["KEYFOB_APP_GROUP"] as? String, !override.isEmpty {
            return override
        }
        return "group.com.example.keyfob"
    }()

    /// The Keychain account name used by ``KeyManager`` for the legacy single-key store.
    public static let legacyKeyAccount = "default.nsec"

    /// Returns the Keychain account name for a given identity UUID.
    ///
    /// Format: `identity.<UUID>` — coexists with the legacy `default.nsec` account.
    public static func keychainAccount(for identityID: UUID) -> String {
        "identity.\(identityID.uuidString)"
    }

    /// Darwin notification name posted when the active identity changes.
    ///
    /// Used for cross-process observation (e.g., app ↔ Safari Web Extension).
    public static let activeIdentityChangedNotification = "com.keyfob.identity.didChange"
}
