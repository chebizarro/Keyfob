// ──────────────────────────────────────────────────────────────────
// RelayPoolTests.swift — Tests for relay pool and config
// ──────────────────────────────────────────────────────────────────

import XCTest
@testable import KeyfobRelay

// MARK: - RelayConfig Tests

final class RelayConfigTests: XCTestCase {

    // MARK: - RelayConfigEntry

    func testEntryCanReadWrite() {
        let rw = RelayConfigEntry(url: URL(string: "wss://r.test")!, role: .readWrite)
        XCTAssertTrue(rw.canRead)
        XCTAssertTrue(rw.canWrite)

        let r = RelayConfigEntry(url: URL(string: "wss://r.test")!, role: .read)
        XCTAssertTrue(r.canRead)
        XCTAssertFalse(r.canWrite)

        let w = RelayConfigEntry(url: URL(string: "wss://r.test")!, role: .write)
        XCTAssertFalse(w.canRead)
        XCTAssertTrue(w.canWrite)
    }

    func testDisabledEntryCantReadOrWrite() {
        let entry = RelayConfigEntry(url: URL(string: "wss://r.test")!, role: .readWrite, isEnabled: false)
        XCTAssertFalse(entry.canRead)
        XCTAssertFalse(entry.canWrite)
    }

    // MARK: - RelayPoolConfig

    func testAddRelay() {
        var config = RelayPoolConfig()
        config.addRelay(url: URL(string: "wss://relay1.test")!)
        config.addRelay(url: URL(string: "wss://relay2.test")!, role: .read)
        XCTAssertEqual(config.relays.count, 2)
    }

    func testAddRelayNoDuplicates() {
        var config = RelayPoolConfig()
        let url = URL(string: "wss://relay.test")!
        config.addRelay(url: url)
        config.addRelay(url: url) // Duplicate
        XCTAssertEqual(config.relays.count, 1)
    }

    func testRemoveRelay() {
        var config = RelayPoolConfig()
        let url = URL(string: "wss://relay.test")!
        config.addRelay(url: url)
        XCTAssertTrue(config.removeRelay(url: url))
        XCTAssertEqual(config.relays.count, 0)
        XCTAssertFalse(config.removeRelay(url: url)) // Already removed
    }

    func testSetRole() {
        var config = RelayPoolConfig()
        let url = URL(string: "wss://relay.test")!
        config.addRelay(url: url, role: .readWrite)
        XCTAssertTrue(config.setRole(url: url, role: .read))
        XCTAssertEqual(config.relays.first?.role, .read)
    }

    func testSetEnabled() {
        var config = RelayPoolConfig()
        let url = URL(string: "wss://relay.test")!
        config.addRelay(url: url)
        XCTAssertTrue(config.setEnabled(url: url, enabled: false))
        XCTAssertFalse(config.relays.first!.isEnabled)
    }

    func testReadWriteFilters() {
        var config = RelayPoolConfig()
        config.addRelay(url: URL(string: "wss://read.test")!, role: .read)
        config.addRelay(url: URL(string: "wss://write.test")!, role: .write)
        config.addRelay(url: URL(string: "wss://rw.test")!, role: .readWrite)

        XCTAssertEqual(config.readRelays.count, 2) // read + readWrite
        XCTAssertEqual(config.writeRelays.count, 2) // write + readWrite
        XCTAssertEqual(config.enabledRelays.count, 3)
    }

    func testCodableRoundTrip() throws {
        var config = RelayPoolConfig()
        config.addRelay(url: URL(string: "wss://relay1.test")!, role: .readWrite)
        config.addRelay(url: URL(string: "wss://relay2.test")!, role: .read)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(RelayPoolConfig.self, from: data)
        XCTAssertEqual(config, decoded)
    }

    // MARK: - bunker:// URI

    func testParseBunkerURI() {
        let uri = "bunker://abc123def?relay=wss://relay1.test&relay=wss://relay2.test&secret=mysecret"
        guard let components = RelayPoolConfig.parseBunkerURI(uri) else {
            XCTFail("Should parse bunker URI"); return
        }
        XCTAssertEqual(components.signerPubkey, "abc123def")
        XCTAssertEqual(components.relayURLs.count, 2)
        XCTAssertEqual(components.relayURLs[0].absoluteString, "wss://relay1.test")
        XCTAssertEqual(components.relayURLs[1].absoluteString, "wss://relay2.test")
        XCTAssertEqual(components.secret, "mysecret")
    }

    func testParseBunkerURINoSecret() {
        let uri = "bunker://abc123?relay=wss://relay.test"
        let components = RelayPoolConfig.parseBunkerURI(uri)
        XCTAssertNotNil(components)
        XCTAssertNil(components?.secret)
    }

    func testParseBunkerURIInvalidScheme() {
        XCTAssertNil(RelayPoolConfig.parseBunkerURI("https://abc123?relay=wss://r.test"))
    }

    func testParseBunkerURINoHost() {
        XCTAssertNil(RelayPoolConfig.parseBunkerURI("bunker://?relay=wss://r.test"))
    }

    func testFromBunkerURI() {
        let uri = "bunker://pubkey123?relay=wss://relay1.test&relay=wss://relay2.test&secret=tok"
        guard let (config, components) = RelayPoolConfig.fromBunkerURI(uri) else {
            XCTFail("Should create config from bunker URI"); return
        }
        XCTAssertEqual(config.relays.count, 2)
        XCTAssertTrue(config.relays.allSatisfy { $0.role == .readWrite })
        XCTAssertEqual(components.signerPubkey, "pubkey123")
        XCTAssertEqual(components.secret, "tok")
    }
}

// MARK: - Mock Container

/// Reference-type container for mock transports so the factory
/// closure and the test share the same dictionary.
private final class MockContainer: @unchecked Sendable {
    private let lock = NSLock()
    private var _mocks: [URL: MockWebSocketTransport] = [:]

    subscript(url: URL) -> MockWebSocketTransport? {
        lock.lock()
        defer { lock.unlock() }
        return _mocks[url]
    }

    func set(_ mock: MockWebSocketTransport, for url: URL) {
        lock.lock()
        _mocks[url] = mock
        lock.unlock()
    }
}

// MARK: - RelayPool Tests

final class RelayPoolTests: XCTestCase {

    private func makePool(
        urls: [(URL, RelayRole)] = []
    ) -> (RelayPool, MockContainer) {
        let mocks = MockContainer()

        var config = RelayPoolConfig()
        for (url, role) in urls {
            config.addRelay(url: url, role: role)
        }

        let pool = RelayPool(config: config) { url in
            let mock = MockWebSocketTransport()
            mocks.set(mock, for: url)
            return mock
        }

        return (pool, mocks)
    }

    private let readURL = URL(string: "wss://read.test")!
    private let writeURL = URL(string: "wss://write.test")!
    private let rwURL = URL(string: "wss://rw.test")!

    // MARK: - Connection Management

    func testConnectAllCreatesConnections() {
        let (pool, _) = makePool(urls: [
            (readURL, .read),
            (writeURL, .write),
        ])
        pool.connectAll()
        defer { pool.disconnectAll() }

        let statuses = pool.relayStatuses
        XCTAssertEqual(statuses.count, 2)
        XCTAssertTrue(statuses.allSatisfy { $0.connectionState == .connected })
    }

    func testDisconnectAll() {
        let (pool, _) = makePool(urls: [(rwURL, .readWrite)])
        pool.connectAll()
        pool.disconnectAll()

        XCTAssertEqual(pool.connection(for: rwURL)?.state, .disconnected)
    }

    func testAddRelayAtRuntime() {
        let (pool, _) = makePool()
        pool.addRelay(url: rwURL, role: .readWrite)
        defer { pool.disconnectAll() }

        XCTAssertEqual(pool.currentConfig.relays.count, 1)
        XCTAssertNotNil(pool.connection(for: rwURL))
    }

    func testRemoveRelayAtRuntime() {
        let (pool, _) = makePool(urls: [(rwURL, .readWrite)])
        pool.connectAll()
        pool.removeRelay(url: rwURL)

        XCTAssertEqual(pool.currentConfig.relays.count, 0)
        XCTAssertNil(pool.connection(for: rwURL))
    }

    // MARK: - Subscribe (Read Relays)

    func testSubscribeOnlyOnReadRelays() {
        let (pool, _) = makePool(urls: [
            (readURL, .read),
            (writeURL, .write),
            (rwURL, .readWrite),
        ])
        pool.connectAll()
        defer { pool.disconnectAll() }

        let handle = pool.subscribe(
            filters: [NostrFilter(kinds: [24133])],
            callbacks: SubscriptionCallbacks()
        )

        // Should subscribe on read + readWrite, not write-only
        XCTAssertEqual(handle.subHandles.count, 2)
        XCTAssertNotNil(handle.subHandles[readURL.absoluteString])
        XCTAssertNotNil(handle.subHandles[rwURL.absoluteString])
        XCTAssertNil(handle.subHandles[writeURL.absoluteString])
    }

    func testCloseSubscription() {
        let (pool, _) = makePool(urls: [(rwURL, .readWrite)])
        pool.connectAll()
        defer { pool.disconnectAll() }

        let handle = pool.subscribe(
            filters: [NostrFilter(kinds: [1])],
            callbacks: SubscriptionCallbacks()
        )
        XCTAssertEqual(handle.subHandles.count, 1)

        pool.closeSubscription(handle)
    }

    // MARK: - Publish (Write Relays)

    func testPublishToWriteRelays() async {
        let (pool, mocks) = makePool(urls: [
            (writeURL, .write),
            (rwURL, .readWrite),
        ])
        pool.connectAll()
        defer { pool.disconnectAll() }

        let event = RelayEvent(
            id: "pool-pub-1", pubkey: "pk", created_at: 100,
            kind: 1, tags: [], content: "test", sig: "sig"
        )

        // Enqueue OK responses on both write relays before publish
        // (concurrent publish means both start ~simultaneously,
        //  receiveLoop picks up enqueued messages when ready)
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            mocks[writeURL]?.enqueue(#"["OK","pool-pub-1",true,""]"#)
            mocks[rwURL]?.enqueue(#"["OK","pool-pub-1",true,""]"#)
        }

        let result = await pool.publish(event: event)
        if case .accepted(let count) = result {
            XCTAssertEqual(count, 2)
        } else {
            XCTFail("Expected .accepted, got \(result)")
        }
    }

    func testPublishSkipsReadOnlyRelays() async {
        let (pool, mocks) = makePool(urls: [
            (readURL, .read),
            (writeURL, .write),
        ])
        pool.connectAll()
        defer { pool.disconnectAll() }

        let event = RelayEvent(
            id: "pool-pub-2", pubkey: "pk", created_at: 100,
            kind: 1, tags: [], content: "test", sig: "sig"
        )

        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            mocks[writeURL]?.enqueue(#"["OK","pool-pub-2",true,""]"#)
        }

        let result = await pool.publish(event: event)
        if case .accepted(let count) = result {
            XCTAssertEqual(count, 1)
        } else {
            XCTFail("Expected .accepted, got \(result)")
        }
    }

    func testPublishNoWriteRelaysReturnsNoWriteRelays() async {
        let (pool, _) = makePool(urls: [(readURL, .read)])
        pool.connectAll()
        defer { pool.disconnectAll() }

        let event = RelayEvent(
            id: "pool-pub-3", pubkey: "pk", created_at: 100,
            kind: 1, tags: [], content: "test", sig: "sig"
        )

        let result = await pool.publish(event: event)
        XCTAssertEqual(result, .noWriteRelays)
    }

    // MARK: - Circuit Breaker

    func testCircuitBreakerStartsClosed() {
        let (pool, _) = makePool(urls: [(writeURL, .write)])
        pool.connectAll()
        defer { pool.disconnectAll() }

        XCTAssertFalse(pool.isCircuitOpen(for: writeURL))
    }

    func testCircuitBreakerReset() {
        let (pool, _) = makePool(urls: [(writeURL, .write)])
        pool.connectAll()
        defer { pool.disconnectAll() }

        pool.resetCircuit(for: writeURL)
        XCTAssertFalse(pool.isCircuitOpen(for: writeURL))
    }

    // MARK: - Relay Status

    func testRelayStatuses() {
        let (pool, _) = makePool(urls: [
            (readURL, .read),
            (writeURL, .write),
        ])
        pool.connectAll()
        defer { pool.disconnectAll() }

        let statuses = pool.relayStatuses
        XCTAssertEqual(statuses.count, 2)

        let readStatus = statuses.first { $0.url == readURL }
        XCTAssertEqual(readStatus?.role, .read)
        XCTAssertEqual(readStatus?.connectionState, .connected)
        XCTAssertFalse(readStatus?.circuitOpen ?? true)
    }

    // MARK: - Auth Signer Propagation

    func testAuthSignerPropagatedToConnections() {
        let (pool, _) = makePool(urls: [(rwURL, .readWrite)])
        pool.connectAll()
        defer { pool.disconnectAll() }

        let signer = MockAuthSigner()
        pool.authSigner = signer

        XCTAssertNotNil(pool.connection(for: rwURL)?.authSigner)
    }
}
