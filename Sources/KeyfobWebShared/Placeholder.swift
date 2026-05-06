// ──────────────────────────────────────────────────────────────────
// KeyfobWebShared — Constants & types shared between Safari
// extension Swift handlers and their content-script counterparts.
// ──────────────────────────────────────────────────────────────────
//
// This module has **zero** dependencies so it can be imported by
// extension targets without pulling in the full Keyfob stack.
// ──────────────────────────────────────────────────────────────────

import Foundation

// MARK: - Protocol Constants

/// String constants used in the messaging protocol between the
/// content-script (JavaScript) and the native Safari extension handler (Swift).
///
/// Keep these in sync with `nostr-provider.ts` and the two content.js files.
public enum WebMessageName {
    // MARK: App Extension (SFSafariExtensionHandler)

    /// JS → Native: request the user's Nostr public key.
    public static let getPublicKey = "keyfob_getPublicKey"
    /// JS → Native: request a Nostr event signature.
    public static let signEvent    = "keyfob_signEvent"
    /// Native → JS: response envelope for both methods.
    public static let response     = "keyfob_response"

    // MARK: Web Extension (Universal-Link handoff)

    /// URL path segment for the public-key handoff.
    public static let pubkeyPath = "pubkey"
    /// URL path segment for the sign-event handoff.
    public static let signPath   = "sign"
}

/// Keys used inside the `userInfo` dictionaries exchanged over
/// `safari.extension.dispatchMessage` / `page.dispatchMessageToScript`.
public enum WebMessageKey {
    public static let reqId    = "reqId"
    public static let ok       = "ok"
    public static let pubkey   = "pubkey"
    public static let id       = "id"
    public static let sig      = "sig"
    public static let msg      = "msg"
    public static let eventJSON = "eventJSON"
    public static let origin   = "origin"
    public static let callback = "cb"
}

/// Numeric status codes sent in the `ok` field.
public enum WebStatus {
    /// The request succeeded.
    public static let success = 1
    /// The request failed.
    public static let failure = 0
}

// MARK: - Message Types

/// A response payload that can be serialized to the `userInfo`
/// dictionary expected by Safari extension messaging.
///
/// Usage (in the extension handler):
/// ```swift
/// let resp = WebResponse.pubkey("ab12cd...")
/// page.dispatchMessageToScript(withName: WebMessageName.response,
///                              userInfo: resp.userInfo(reqId: id))
/// ```
public struct WebResponse: Equatable {
    public let ok: Int
    public let pubkey: String?
    public let id: String?
    public let sig: String?
    public let msg: String?

    /// Successful public-key response.
    public static func pubkey(_ hex: String) -> WebResponse {
        WebResponse(ok: WebStatus.success, pubkey: hex, id: nil, sig: nil, msg: nil)
    }

    /// Successful signature response.
    public static func signed(id: String, sig: String, pubkey: String) -> WebResponse {
        WebResponse(ok: WebStatus.success, pubkey: pubkey, id: id, sig: sig, msg: nil)
    }

    /// Error response.
    public static func error(_ message: String) -> WebResponse {
        WebResponse(ok: WebStatus.failure, pubkey: nil, id: nil, sig: nil, msg: message)
    }

    /// Convert to the `[String: Any]` dictionary used by Safari messaging.
    public func userInfo(reqId: String = "") -> [String: Any] {
        var dict: [String: Any] = [
            WebMessageKey.ok: ok,
            WebMessageKey.reqId: reqId,
        ]
        if let pubkey = pubkey { dict[WebMessageKey.pubkey] = pubkey }
        if let id = id         { dict[WebMessageKey.id] = id }
        if let sig = sig       { dict[WebMessageKey.sig] = sig }
        if let msg = msg       { dict[WebMessageKey.msg] = msg }
        return dict
    }
}

// MARK: - NIP-07 Types (Swift mirrors of the JS interface)

/// Minimal representation of a Nostr event as received from a
/// web page via NIP-07's `signEvent()`.
///
/// This mirrors the JavaScript object shape:
/// ```js
/// { kind: 1, created_at: 1700000000, tags: [], content: "hello" }
/// ```
public struct NIP07UnsignedEvent: Codable, Equatable {
    public let kind: Int
    public let created_at: Int64
    public let tags: [[String]]
    public let content: String

    public init(kind: Int, created_at: Int64, tags: [[String]], content: String) {
        self.kind = kind
        self.created_at = created_at
        self.tags = tags
        self.content = content
    }
}

/// The signed-event object returned to the web page.
///
/// ```js
/// { id: "...", sig: "...", pubkey: "...", kind: 1, ... }
/// ```
public struct NIP07SignedEvent: Codable, Equatable {
    public let id: String
    public let pubkey: String
    public let sig: String
    public let kind: Int
    public let created_at: Int64
    public let tags: [[String]]
    public let content: String

    public init(unsigned: NIP07UnsignedEvent, id: String, sig: String, pubkey: String) {
        self.id = id
        self.pubkey = pubkey
        self.sig = sig
        self.kind = unsigned.kind
        self.created_at = unsigned.created_at
        self.tags = unsigned.tags
        self.content = unsigned.content
    }
}
