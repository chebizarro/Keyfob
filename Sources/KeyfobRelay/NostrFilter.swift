// ──────────────────────────────────────────────────────────────────
// NostrFilter.swift — Nostr REQ subscription filters
// ──────────────────────────────────────────────────────────────────

import Foundation

/// A Nostr subscription filter per NIP-01.
///
/// Encode to JSON for inclusion in a `["REQ", ...]` frame.
/// Only non-nil fields are included in the encoded output.
public struct NostrFilter: Codable, Equatable, Sendable {
    /// Event IDs to match.
    public var ids: [String]?
    /// Pubkeys of event authors.
    public var authors: [String]?
    /// Event kinds to match.
    public var kinds: [Int]?
    /// Referenced event IDs (`#e` tag).
    public var e: [String]?
    /// Referenced pubkeys (`#p` tag).
    public var p: [String]?
    /// Referenced hashtags (`#t` tag).
    public var t: [String]?
    /// Events created after this timestamp (inclusive).
    public var since: Int?
    /// Events created before this timestamp (inclusive).
    public var until: Int?
    /// Maximum number of events to return.
    public var limit: Int?

    public init(ids: [String]? = nil, authors: [String]? = nil, kinds: [Int]? = nil,
                e: [String]? = nil, p: [String]? = nil, t: [String]? = nil,
                since: Int? = nil, until: Int? = nil, limit: Int? = nil) {
        self.ids = ids
        self.authors = authors
        self.kinds = kinds
        self.e = e
        self.p = p
        self.t = t
        self.since = since
        self.until = until
        self.limit = limit
    }

    // Custom coding keys: NIP-01 uses "#e", "#p", "#t" for tag filters
    enum CodingKeys: String, CodingKey {
        case ids, authors, kinds
        case e = "#e"
        case p = "#p"
        case t = "#t"
        case since, until, limit
    }
}
