//
//  NostrDisplayFormatting.swift
//
//
//  Created for Keyfob – kf-ghe
//

import Foundation
import NostrSDK

// MARK: - Npub Display Formatting

/// Utilities for displaying Nostr public keys in user-friendly formats.
///
/// All formatting uses the SDK's native bech32 encoding (`PublicKey.npub`)
/// rather than any custom implementation.
public enum NpubDisplay {

    /// Format a public key hex as a truncated npub for display.
    ///
    /// Example: `npub1abc...xyz` (prefix + 8 chars ... suffix 4 chars by default)
    ///
    /// - Parameters:
    ///   - pubkeyHex: The 64-character hex public key.
    ///   - prefixCount: Characters to show after `npub1` (default: 8).
    ///   - suffixCount: Characters to show at the end (default: 4).
    /// - Returns: Truncated npub string, or the raw hex truncated if npub encoding fails.
    public static func truncated(
        _ pubkeyHex: String,
        prefixCount: Int = 8,
        suffixCount: Int = 4
    ) -> String {
        guard let pk = NostrSDK.PublicKey(hex: pubkeyHex) else {
            // Fallback: truncate the hex itself
            return truncateString(pubkeyHex, prefixCount: prefixCount, suffixCount: suffixCount)
        }
        return truncated(npub: pk.npub, prefixCount: prefixCount, suffixCount: suffixCount)
    }

    /// Format an npub string as truncated for display.
    ///
    /// - Parameters:
    ///   - npub: The full npub string (e.g. `npub1abcdef...`).
    ///   - prefixCount: Characters to show from the start (default: 8, added after `npub1`).
    ///   - suffixCount: Characters to show at the end (default: 4).
    /// - Returns: Truncated npub string.
    public static func truncated(
        npub: String,
        prefixCount: Int = 8,
        suffixCount: Int = 4
    ) -> String {
        // "npub1" is 5 chars. Show npub1 + prefixCount chars ... suffixCount chars
        let prefix = "npub1"
        guard npub.hasPrefix(prefix) else {
            return truncateString(npub, prefixCount: prefixCount, suffixCount: suffixCount)
        }

        let body = String(npub.dropFirst(prefix.count))
        let totalVisible = prefixCount + suffixCount
        guard body.count > totalVisible + 3 else {
            // Short enough to show fully
            return npub
        }

        let start = body.prefix(prefixCount)
        let end = body.suffix(suffixCount)
        return "\(prefix)\(start)…\(end)"
    }

    /// The full npub string for a given hex public key.
    ///
    /// - Parameter pubkeyHex: The 64-character hex public key.
    /// - Returns: The bech32-encoded npub, or `nil` if encoding fails.
    public static func npub(from pubkeyHex: String) -> String? {
        NostrSDK.PublicKey(hex: pubkeyHex)?.npub
    }

    /// Generic string truncation helper.
    private static func truncateString(_ s: String, prefixCount: Int, suffixCount: Int) -> String {
        let totalVisible = prefixCount + suffixCount
        guard s.count > totalVisible + 3 else { return s }
        let start = s.prefix(prefixCount)
        let end = s.suffix(suffixCount)
        return "\(start)…\(end)"
    }
}

// MARK: - Identity Display Extensions

extension Identity {
    /// Truncated npub string for user-facing display.
    ///
    /// Example: `npub1abc8ch…xy4z`
    public var truncatedNpub: String {
        NpubDisplay.truncated(pubkeyHex)
    }

    /// Full bech32-encoded npub string.
    public var npub: String? {
        NpubDisplay.npub(from: pubkeyHex)
    }

    /// A user-friendly display string: the label if set, otherwise the truncated npub.
    public var displayName: String {
        if let label = label, !label.isEmpty {
            return label
        }
        return truncatedNpub
    }
}

// MARK: - Keypair Display Extensions

extension Keypair {
    /// Truncated npub string for user-facing display.
    public var truncatedNpub: String {
        NpubDisplay.truncated(pubkeyHex)
    }
}

// MARK: - Clipboard Formatting

/// Clipboard-ready key formatting utilities.
public enum KeyClipboard {

    /// Copy-ready npub string (full bech32) for a public key hex.
    ///
    /// Returns the full npub for clipboard operations (not truncated).
    /// - Parameter pubkeyHex: The 64-character hex public key.
    /// - Returns: The full npub string, or the hex as fallback.
    public static func npubForCopy(_ pubkeyHex: String) -> String {
        NpubDisplay.npub(from: pubkeyHex) ?? pubkeyHex
    }

    /// Copy-ready nsec string for a private key.
    ///
    /// > Warning: This exposes the private key. Use only in explicit export flows
    /// > with appropriate user warnings.
    ///
    /// - Parameter privateKey: The SDK ``NostrSDK/PrivateKey``.
    /// - Returns: The bech32-encoded nsec string.
    public static func nsecForCopy(_ privateKey: NostrSDK.PrivateKey) -> String {
        privateKey.nsec
    }

    /// Copy-ready hex string for a public key.
    ///
    /// Some applications expect hex format rather than bech32.
    /// - Parameter pubkeyHex: The public key hex string.
    /// - Returns: The same hex string (passthrough for API consistency).
    public static func hexForCopy(_ pubkeyHex: String) -> String {
        pubkeyHex
    }
}
