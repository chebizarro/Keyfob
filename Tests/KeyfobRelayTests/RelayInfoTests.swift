// ──────────────────────────────────────────────────────────────────
// RelayInfoTests.swift — Tests for NIP-11 relay information document
// ──────────────────────────────────────────────────────────────────

import XCTest
@testable import KeyfobRelay

// MARK: - Mock HTTP Fetcher

/// Mock HTTP data fetcher for testing RelayInfoFetcher.
final class MockHTTPFetcher: HTTPDataFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var _responses: [URL: (Data, URLResponse)] = [:]
    private var _errors: [URL: Error] = [:]
    var fetchCount = 0

    func setResponse(for url: URL, data: Data, statusCode: Int = 200) {
        let response = HTTPURLResponse(
            url: url, statusCode: statusCode,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        lock.lock()
        _responses[url] = (data, response)
        lock.unlock()
    }

    func setError(for url: URL, error: Error) {
        lock.lock()
        _errors[url] = error
        lock.unlock()
    }

    func fetchData(from request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock()
        fetchCount += 1
        let url = request.url!
        if let error = _errors[url] {
            lock.unlock()
            throw error
        }
        if let response = _responses[url] {
            lock.unlock()
            return response
        }
        lock.unlock()
        throw URLError(.fileDoesNotExist)
    }
}

// MARK: - RelayInfo Model Tests

final class RelayInfoTests: XCTestCase {

    // MARK: - Decoding

    func testDecodeFullDocument() throws {
        let json = """
        {
            "name": "Test Relay",
            "description": "A test relay for unit testing",
            "pubkey": "abc123",
            "contact": "admin@relay.test",
            "supported_nips": [1, 11, 42, 46],
            "software": "git+https://example.com/relay",
            "version": "1.0.0",
            "limitation": {
                "max_message_length": 524288,
                "max_subscriptions": 20,
                "max_filters": 10,
                "max_subid_length": 100,
                "min_pow_difficulty": 0,
                "auth_required": true,
                "payment_required": false,
                "created_at_upper_limit": 300,
                "max_event_tags": 100,
                "max_content_length": 8196,
                "max_limit": 5000
            },
            "relay_countries": ["US", "CA"],
            "language_tags": ["en"],
            "posting_policy": "https://relay.test/policy"
        }
        """
        let data = json.data(using: .utf8)!
        let info = try JSONDecoder().decode(RelayInfo.self, from: data)

        XCTAssertEqual(info.name, "Test Relay")
        XCTAssertEqual(info.description, "A test relay for unit testing")
        XCTAssertEqual(info.pubkey, "abc123")
        XCTAssertEqual(info.contact, "admin@relay.test")
        XCTAssertEqual(info.supported_nips, [1, 11, 42, 46])
        XCTAssertEqual(info.software, "git+https://example.com/relay")
        XCTAssertEqual(info.version, "1.0.0")
        XCTAssertEqual(info.limitation?.max_message_length, 524288)
        XCTAssertEqual(info.limitation?.max_subscriptions, 20)
        XCTAssertEqual(info.limitation?.max_filters, 10)
        XCTAssertEqual(info.limitation?.max_subid_length, 100)
        XCTAssertEqual(info.limitation?.auth_required, true)
        XCTAssertEqual(info.limitation?.payment_required, false)
        XCTAssertEqual(info.limitation?.created_at_upper_limit, 300)
        XCTAssertEqual(info.limitation?.max_event_tags, 100)
        XCTAssertEqual(info.limitation?.max_content_length, 8196)
        XCTAssertEqual(info.limitation?.max_limit, 5000)
        XCTAssertEqual(info.relay_countries, ["US", "CA"])
        XCTAssertEqual(info.language_tags, ["en"])
        XCTAssertEqual(info.posting_policy, "https://relay.test/policy")
    }

    func testDecodeMinimalDocument() throws {
        let json = "{}"
        let data = json.data(using: .utf8)!
        let info = try JSONDecoder().decode(RelayInfo.self, from: data)

        XCTAssertNil(info.name)
        XCTAssertNil(info.supported_nips)
        XCTAssertNil(info.limitation)
    }

    func testDecodePartialDocument() throws {
        let json = """
        {
            "name": "Minimal Relay",
            "supported_nips": [1, 11]
        }
        """
        let data = json.data(using: .utf8)!
        let info = try JSONDecoder().decode(RelayInfo.self, from: data)

        XCTAssertEqual(info.name, "Minimal Relay")
        XCTAssertEqual(info.supported_nips, [1, 11])
        XCTAssertNil(info.limitation)
        XCTAssertNil(info.pubkey)
    }

    func testDecodeIgnoresUnknownFields() throws {
        let json = """
        {
            "name": "Relay",
            "custom_field": "should be ignored",
            "supported_nips": [1]
        }
        """
        let data = json.data(using: .utf8)!
        // Should not throw even with unknown keys
        let info = try JSONDecoder().decode(RelayInfo.self, from: data)
        XCTAssertEqual(info.name, "Relay")
    }

    func testEncodeRoundTrip() throws {
        let info = RelayInfo(
            name: "Round Trip Relay",
            supported_nips: [1, 11, 42],
            limitation: RelayInfo.Limitation(
                max_subscriptions: 10,
                auth_required: false
            )
        )
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(RelayInfo.self, from: data)

        XCTAssertEqual(info, decoded)
    }

    // MARK: - Convenience Methods

    func testRequiresAuth() {
        let info1 = RelayInfo(limitation: RelayInfo.Limitation(auth_required: true))
        XCTAssertTrue(info1.requiresAuth)

        let info2 = RelayInfo(limitation: RelayInfo.Limitation(auth_required: false))
        XCTAssertFalse(info2.requiresAuth)

        let info3 = RelayInfo() // No limitation at all
        XCTAssertFalse(info3.requiresAuth)

        let info4 = RelayInfo(limitation: RelayInfo.Limitation()) // No auth_required
        XCTAssertFalse(info4.requiresAuth)
    }

    func testSupportsNIP() {
        let info = RelayInfo(supported_nips: [1, 11, 42, 46])
        XCTAssertTrue(info.supportsNIP(1))
        XCTAssertTrue(info.supportsNIP(46))
        XCTAssertFalse(info.supportsNIP(99))

        let empty = RelayInfo()
        XCTAssertFalse(empty.supportsNIP(1)) // nil supported_nips → false
    }
}

// MARK: - URL Conversion Tests

final class RelayInfoURLTests: XCTestCase {

    private var fetcher: RelayInfoFetcher!

    override func setUp() {
        super.setUp()
        fetcher = RelayInfoFetcher(fetcher: MockHTTPFetcher())
    }

    func testWSSToHTTPS() throws {
        let url = URL(string: "wss://relay.example.com")!
        let httpURL = try fetcher.makeHTTPURL(from: url)
        XCTAssertEqual(httpURL.absoluteString, "https://relay.example.com")
    }

    func testWSToHTTP() throws {
        let url = URL(string: "ws://localhost:8080")!
        let httpURL = try fetcher.makeHTTPURL(from: url)
        XCTAssertEqual(httpURL.absoluteString, "http://localhost:8080")
    }

    func testWSSWithPath() throws {
        let url = URL(string: "wss://relay.example.com/nostr")!
        let httpURL = try fetcher.makeHTTPURL(from: url)
        XCTAssertEqual(httpURL.absoluteString, "https://relay.example.com/nostr")
    }

    func testHTTPSPassthrough() throws {
        let url = URL(string: "https://relay.example.com")!
        let httpURL = try fetcher.makeHTTPURL(from: url)
        XCTAssertEqual(httpURL.absoluteString, "https://relay.example.com")
    }

    func testInvalidSchemeThrows() {
        let url = URL(string: "ftp://relay.example.com")!
        XCTAssertThrowsError(try fetcher.makeHTTPURL(from: url)) { error in
            if case RelayInfoError.invalidURL = error {
                // Expected
            } else {
                XCTFail("Expected .invalidURL, got \(error)")
            }
        }
    }
}

// MARK: - Fetcher Tests

final class RelayInfoFetcherTests: XCTestCase {

    private var mockHTTP: MockHTTPFetcher!
    private var fetcher: RelayInfoFetcher!
    private let relayURL = URL(string: "wss://relay.test")!
    private let httpURL = URL(string: "https://relay.test")!

    override func setUp() {
        super.setUp()
        mockHTTP = MockHTTPFetcher()
        fetcher = RelayInfoFetcher(fetcher: mockHTTP)
    }

    private func setMockResponse(_ json: String, statusCode: Int = 200) {
        let data = json.data(using: .utf8)!
        mockHTTP.setResponse(for: httpURL, data: data, statusCode: statusCode)
    }

    // MARK: - Fetch Success

    func testFetchBasicDocument() async throws {
        setMockResponse("""
        {
            "name": "Test Relay",
            "supported_nips": [1, 11, 42]
        }
        """)

        let info = try await fetcher.fetch(relayURL: relayURL)
        XCTAssertEqual(info.name, "Test Relay")
        XCTAssertEqual(info.supported_nips, [1, 11, 42])
    }

    func testFetchEmptyDocument() async throws {
        setMockResponse("{}")

        let info = try await fetcher.fetch(relayURL: relayURL)
        XCTAssertNil(info.name)
        XCTAssertNil(info.supported_nips)
    }

    // MARK: - Caching

    func testCachedResponseReturnedWithinTTL() async throws {
        setMockResponse(#"{"name": "Cached"}"#)
        fetcher.cacheTTL = 3600

        let first = try await fetcher.fetch(relayURL: relayURL)
        XCTAssertEqual(first.name, "Cached")
        XCTAssertEqual(mockHTTP.fetchCount, 1)

        let second = try await fetcher.fetch(relayURL: relayURL)
        XCTAssertEqual(second.name, "Cached")
        XCTAssertEqual(mockHTTP.fetchCount, 1) // Still 1 — served from cache
    }

    func testCacheExpiredRefetches() async throws {
        setMockResponse(#"{"name": "First"}"#)
        fetcher.cacheTTL = 0.0 // Immediate expiry

        let first = try await fetcher.fetch(relayURL: relayURL)
        XCTAssertEqual(first.name, "First")
        XCTAssertEqual(mockHTTP.fetchCount, 1)

        setMockResponse(#"{"name": "Second"}"#)

        let second = try await fetcher.fetch(relayURL: relayURL)
        XCTAssertEqual(second.name, "Second")
        XCTAssertEqual(mockHTTP.fetchCount, 2) // Re-fetched
    }

    func testInvalidateRemovesCache() async throws {
        setMockResponse(#"{"name": "Cached"}"#)

        _ = try await fetcher.fetch(relayURL: relayURL)
        XCTAssertEqual(fetcher.cacheCount, 1)

        fetcher.invalidate(relayURL: relayURL)
        XCTAssertEqual(fetcher.cacheCount, 0)
    }

    func testInvalidateAllClearsCache() async throws {
        setMockResponse(#"{"name": "Relay1"}"#)
        _ = try await fetcher.fetch(relayURL: relayURL)

        let relay2 = URL(string: "wss://relay2.test")!
        let http2 = URL(string: "https://relay2.test")!
        mockHTTP.setResponse(for: http2, data: #"{"name":"Relay2"}"#.data(using: .utf8)!, statusCode: 200)
        _ = try await fetcher.fetch(relayURL: relay2)

        XCTAssertEqual(fetcher.cacheCount, 2)

        fetcher.invalidateAll()
        XCTAssertEqual(fetcher.cacheCount, 0)
    }

    // MARK: - Error Handling

    func testHTTPErrorThrows() async {
        setMockResponse("Not Found", statusCode: 404)

        do {
            _ = try await fetcher.fetch(relayURL: relayURL)
            XCTFail("Should have thrown")
        } catch let error as RelayInfoError {
            XCTAssertEqual(error, .httpError(404))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMalformedJSONThrows() async {
        setMockResponse("this is not json")

        do {
            _ = try await fetcher.fetch(relayURL: relayURL)
            XCTFail("Should have thrown")
        } catch let error as RelayInfoError {
            if case .decodingFailed = error {
                // Expected
            } else {
                XCTFail("Expected .decodingFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTimeoutThrows() async {
        mockHTTP.setError(for: httpURL, error: URLError(.timedOut))

        do {
            _ = try await fetcher.fetch(relayURL: relayURL)
            XCTFail("Should have thrown")
        } catch let error as RelayInfoError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNetworkErrorThrowsHTTPError() async {
        mockHTTP.setError(for: httpURL, error: URLError(.notConnectedToInternet))

        do {
            _ = try await fetcher.fetch(relayURL: relayURL)
            XCTFail("Should have thrown")
        } catch let error as RelayInfoError {
            XCTAssertEqual(error, .httpError(0))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - fetchOptional

    func testFetchOptionalReturnsNilOnError() async {
        mockHTTP.setError(for: httpURL, error: URLError(.notConnectedToInternet))

        let info = await fetcher.fetchOptional(relayURL: relayURL)
        XCTAssertNil(info)
    }

    func testFetchOptionalReturnsInfoOnSuccess() async {
        setMockResponse(#"{"name": "Works"}"#)

        let info = await fetcher.fetchOptional(relayURL: relayURL)
        XCTAssertEqual(info?.name, "Works")
    }

    // MARK: - Error Equatable

    func testRelayInfoErrorEquatable() {
        XCTAssertEqual(RelayInfoError.timeout, RelayInfoError.timeout)
        XCTAssertEqual(RelayInfoError.httpError(404), RelayInfoError.httpError(404))
        XCTAssertNotEqual(RelayInfoError.httpError(404), RelayInfoError.httpError(500))
        XCTAssertEqual(
            RelayInfoError.invalidURL("bad"),
            RelayInfoError.invalidURL("bad")
        )
        XCTAssertEqual(
            RelayInfoError.decodingFailed("oops"),
            RelayInfoError.decodingFailed("oops")
        )
    }
}
