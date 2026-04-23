// ──────────────────────────────────────────────────────────────────
// RelayInfo.swift — NIP-11 relay information document
// ──────────────────────────────────────────────────────────────────

import Foundation

// MARK: - Relay Information Document (NIP-11)

/// Parsed NIP-11 relay information document.
///
/// All fields are optional since relays may expose any subset of the spec.
/// See https://github.com/nostr-protocol/nips/blob/master/11.md
public struct RelayInfo: Codable, Sendable, Equatable {

    /// Human-readable relay name.
    public var name: String?

    /// Relay description.
    public var description: String?

    /// Relay operator's pubkey (hex).
    public var pubkey: String?

    /// Relay operator contact (e.g. email or URL).
    public var contact: String?

    /// NIPs supported by this relay (e.g. [1, 11, 42, 46]).
    public var supported_nips: [Int]?

    /// Relay software identifier (e.g. "git+https://...").
    public var software: String?

    /// Relay software version.
    public var version: String?

    /// Relay limitations and policies.
    public var limitation: Limitation?

    /// Relay countries/regions.
    public var relay_countries: [String]?

    /// Language tags.
    public var language_tags: [String]?

    /// Tags accepted by this relay.
    public var tags: [String]?

    /// URL for posting events.
    public var posting_policy: String?

    // MARK: - Limitation

    /// NIP-11 limitation object describing relay constraints.
    public struct Limitation: Codable, Sendable, Equatable {

        /// Maximum message length in bytes.
        public var max_message_length: Int?

        /// Maximum number of subscriptions per connection.
        public var max_subscriptions: Int?

        /// Maximum number of filters per subscription.
        public var max_filters: Int?

        /// Maximum length of subscription ID.
        public var max_subid_length: Int?

        /// Minimum PoW difficulty required.
        public var min_pow_difficulty: Int?

        /// Whether AUTH (NIP-42) is required.
        public var auth_required: Bool?

        /// Whether payment is required.
        public var payment_required: Bool?

        /// Maximum event creation time delta (seconds into the future).
        public var created_at_upper_limit: Int?

        /// Minimum event creation time (absolute timestamp).
        public var created_at_lower_limit: Int?

        /// Maximum number of event tags.
        public var max_event_tags: Int?

        /// Maximum content length.
        public var max_content_length: Int?

        /// Maximum limit value in filters.
        public var max_limit: Int?

        public init(
            max_message_length: Int? = nil,
            max_subscriptions: Int? = nil,
            max_filters: Int? = nil,
            max_subid_length: Int? = nil,
            min_pow_difficulty: Int? = nil,
            auth_required: Bool? = nil,
            payment_required: Bool? = nil,
            created_at_upper_limit: Int? = nil,
            created_at_lower_limit: Int? = nil,
            max_event_tags: Int? = nil,
            max_content_length: Int? = nil,
            max_limit: Int? = nil
        ) {
            self.max_message_length = max_message_length
            self.max_subscriptions = max_subscriptions
            self.max_filters = max_filters
            self.max_subid_length = max_subid_length
            self.min_pow_difficulty = min_pow_difficulty
            self.auth_required = auth_required
            self.payment_required = payment_required
            self.created_at_upper_limit = created_at_upper_limit
            self.created_at_lower_limit = created_at_lower_limit
            self.max_event_tags = max_event_tags
            self.max_content_length = max_content_length
            self.max_limit = max_limit
        }
    }

    public init(
        name: String? = nil,
        description: String? = nil,
        pubkey: String? = nil,
        contact: String? = nil,
        supported_nips: [Int]? = nil,
        software: String? = nil,
        version: String? = nil,
        limitation: Limitation? = nil,
        relay_countries: [String]? = nil,
        language_tags: [String]? = nil,
        tags: [String]? = nil,
        posting_policy: String? = nil
    ) {
        self.name = name
        self.description = description
        self.pubkey = pubkey
        self.contact = contact
        self.supported_nips = supported_nips
        self.software = software
        self.version = version
        self.limitation = limitation
        self.relay_countries = relay_countries
        self.language_tags = language_tags
        self.tags = tags
        self.posting_policy = posting_policy
    }

    // MARK: - Convenience

    /// Whether this relay requires NIP-42 AUTH.
    public var requiresAuth: Bool {
        limitation?.auth_required == true
    }

    /// Whether this relay advertises support for a specific NIP.
    public func supportsNIP(_ nip: Int) -> Bool {
        supported_nips?.contains(nip) ?? false
    }
}

// MARK: - Relay Info Fetcher

/// Errors from NIP-11 relay information document fetching.
public enum RelayInfoError: Error, Equatable {
    /// The relay URL could not be converted to an HTTP(S) URL.
    case invalidURL(String)
    /// HTTP request failed or returned non-200 status.
    case httpError(Int)
    /// Response body could not be decoded as NIP-11 JSON.
    case decodingFailed(String)
    /// Request timed out.
    case timeout
}

/// Protocol abstracting HTTP data fetching for testability.
public protocol HTTPDataFetcher: Sendable {
    func fetchData(from request: URLRequest) async throws -> (Data, URLResponse)
}

/// Default fetcher using URLSession.
public struct URLSessionHTTPFetcher: HTTPDataFetcher {
    public init() {}
    public func fetchData(from request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

/// Fetches NIP-11 relay information documents with caching.
///
/// For a WebSocket URL like `wss://relay.example.com`, probes
/// `https://relay.example.com` with `Accept: application/nostr+json`.
/// Results are cached per relay URL with a configurable TTL.
public final class RelayInfoFetcher: @unchecked Sendable {

    /// Cache entry.
    private struct CacheEntry {
        let info: RelayInfo
        let fetchedAt: Date
    }

    private let lock = NSLock()
    private var cache: [URL: CacheEntry] = [:]
    private let fetcher: HTTPDataFetcher

    /// Time-to-live for cached entries. Default: 1 hour.
    public var cacheTTL: TimeInterval = 3600

    /// HTTP request timeout. Default: 10 seconds.
    public var requestTimeout: TimeInterval = 10.0

    public init(fetcher: HTTPDataFetcher = URLSessionHTTPFetcher()) {
        self.fetcher = fetcher
    }

    // MARK: - Fetch

    /// Fetch the NIP-11 relay information document for a WebSocket relay URL.
    ///
    /// Returns cached results if available and not expired.
    ///
    /// - Parameter relayURL: The relay's WebSocket URL (e.g. `wss://relay.example.com`).
    /// - Returns: The parsed `RelayInfo`, or throws on failure.
    public func fetch(relayURL: URL) async throws -> RelayInfo {
        // Check cache
        lock.lock()
        if let entry = cache[relayURL], Date().timeIntervalSince(entry.fetchedAt) < cacheTTL {
            lock.unlock()
            return entry.info
        }
        lock.unlock()

        // Convert ws(s):// → http(s)://
        let httpURL = try makeHTTPURL(from: relayURL)

        // Build request
        var request = URLRequest(url: httpURL)
        request.setValue("application/nostr+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = requestTimeout

        // Fetch
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetcher.fetchData(from: request)
        } catch let error as URLError where error.code == .timedOut {
            throw RelayInfoError.timeout
        } catch {
            throw RelayInfoError.httpError(0)
        }

        // Validate HTTP status
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw RelayInfoError.httpError(httpResponse.statusCode)
        }

        // Decode
        let info: RelayInfo
        do {
            let decoder = JSONDecoder()
            info = try decoder.decode(RelayInfo.self, from: data)
        } catch {
            throw RelayInfoError.decodingFailed(error.localizedDescription)
        }

        // Cache
        lock.lock()
        cache[relayURL] = CacheEntry(info: info, fetchedAt: Date())
        lock.unlock()

        return info
    }

    /// Fetch without throwing — returns nil on any failure.
    /// Use this when NIP-11 probing should not block connection.
    public func fetchOptional(relayURL: URL) async -> RelayInfo? {
        try? await fetch(relayURL: relayURL)
    }

    // MARK: - Cache Management

    /// Remove cached info for a specific relay URL.
    public func invalidate(relayURL: URL) {
        lock.lock()
        cache.removeValue(forKey: relayURL)
        lock.unlock()
    }

    /// Remove all cached entries.
    public func invalidateAll() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    /// Number of cached entries (for testing).
    public var cacheCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    // MARK: - URL Conversion

    /// Convert a WebSocket URL (ws:// or wss://) to its HTTP equivalent.
    internal func makeHTTPURL(from url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw RelayInfoError.invalidURL(url.absoluteString)
        }

        switch components.scheme {
        case "wss": components.scheme = "https"
        case "ws": components.scheme = "http"
        case "https", "http": break // Already HTTP
        default:
            throw RelayInfoError.invalidURL(url.absoluteString)
        }

        guard let httpURL = components.url else {
            throw RelayInfoError.invalidURL(url.absoluteString)
        }
        return httpURL
    }
}
