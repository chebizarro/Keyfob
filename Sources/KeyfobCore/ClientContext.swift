//
//  ClientContext.swift
//
//
//  Created for Keyfob – kf-rek
//

import Foundation

/// Identifies the IPC channel through which a request arrived.
///
/// Each channel has different trust characteristics and may map to
/// different default approval preferences in the policy engine.
public enum Channel: String, Codable, Sendable, CaseIterable {
    /// macOS/iOS universal link (keyfob:// URL scheme).
    case universalLink
    /// Custom URL scheme (nostrsigner:// — Apple NIP-55 equivalent).
    case urlScheme
    /// macOS XPC service connection.
    case xpc
    /// App Intent (Shortcuts, Siri).
    case appIntent
    /// Action Extension (share sheet).
    case actionExtension
    /// Safari Web Extension (NIP-07 provider).
    case safariWebExtension
    /// Safari App Extension (legacy).
    case safariAppExtension
    /// NIP-46 remote signing over relay.
    case nip46
}

/// How the client prefers consent to be handled.
///
/// This is a Core-layer abstraction that does not leak
/// ``KeyfobPolicy/PolicyEngine`` internals into the request model.
/// The pipeline implementation maps this to policy-layer primitives.
public enum ApprovalPreference: String, Codable, Sendable {
    /// Defer to the policy engine's stored rules for this client.
    case inheritPolicy
    /// Require explicit user approval for this single request.
    case perRequest
    /// Request session-level approval (user approves once for a window of time).
    case session
}

/// Context about the client making a crypto operation request.
///
/// Carried through the ``OperationPipeline`` alongside the ``SignerOperation``
/// and ``IdentitySelection``. Used for policy evaluation, consent UI, and
/// audit logging.
///
/// ## Usage
///
/// ```swift
/// let client = ClientContext(
///     channel: .safariWebExtension,
///     clientID: "example.com",
///     webOrigin: "https://example.com",
///     approvalPreference: .perRequest
/// )
/// ```
public struct ClientContext: Equatable, Sendable {

    /// The IPC channel this request arrived through.
    public let channel: Channel

    /// Canonical identifier for this client, used as the key for policy
    /// rules, session tracking, and audit log entries.
    ///
    /// For web callers, this is typically the origin domain.
    /// For native callers, this is typically the bundle ID.
    public let clientID: String

    /// The web origin (e.g. `"https://example.com"`), if the request came
    /// from a browser context. `nil` for native-only channels.
    public let webOrigin: String?

    /// The native app bundle ID, if the request came from a native context.
    /// `nil` for web-only channels.
    public let bundleID: String?

    /// Optional human-readable display name for consent UI
    /// (e.g. the app name or website title).
    public let displayName: String?

    /// How the client prefers consent to be handled.
    public let approvalPreference: ApprovalPreference

    public init(
        channel: Channel,
        clientID: String,
        webOrigin: String? = nil,
        bundleID: String? = nil,
        displayName: String? = nil,
        approvalPreference: ApprovalPreference = .inheritPolicy
    ) {
        self.channel = channel
        self.clientID = clientID
        self.webOrigin = webOrigin
        self.bundleID = bundleID
        self.displayName = displayName
        self.approvalPreference = approvalPreference
    }
}
