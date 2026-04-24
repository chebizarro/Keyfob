//
//  ClientIdentityTests.swift
//
//
//  Created for Keyfob – kf-92b
//

import XCTest
@testable import KeyfobCore

// MARK: - ClientIdentity Model Tests

final class ClientIdentityModelTests: XCTestCase {

    func testInit_defaultDates() {
        let before = Date()
        let client = ClientIdentity(id: "com.example.app", channel: .urlScheme)
        let after = Date()

        XCTAssertEqual(client.id, "com.example.app")
        XCTAssertNil(client.displayName)
        XCTAssertEqual(client.channel, .urlScheme)
        XCTAssertGreaterThanOrEqual(client.firstSeen, before)
        XCTAssertLessThanOrEqual(client.firstSeen, after)
        XCTAssertGreaterThanOrEqual(client.lastSeen, before)
        XCTAssertLessThanOrEqual(client.lastSeen, after)
    }

    func testInit_withDisplayName() {
        let client = ClientIdentity(id: "example.com", displayName: "Example App", channel: .safariWebExtension)
        XCTAssertEqual(client.displayName, "Example App")
    }

    func testEffectiveDisplayName_withDisplayName() {
        let client = ClientIdentity(id: "com.example", displayName: "My App", channel: .xpc)
        XCTAssertEqual(client.effectiveDisplayName, "My App")
    }

    func testEffectiveDisplayName_withNilDisplayName() {
        let client = ClientIdentity(id: "com.example.nostr", channel: .appIntent)
        XCTAssertEqual(client.effectiveDisplayName, "com.example.nostr")
    }

    func testEffectiveDisplayName_withEmptyDisplayName() {
        let client = ClientIdentity(id: "com.test", displayName: "", channel: .universalLink)
        XCTAssertEqual(client.effectiveDisplayName, "com.test")
    }

    func testCodableRoundTrip() throws {
        let original = ClientIdentity(
            id: "com.test.app",
            displayName: "Test",
            firstSeen: Date(timeIntervalSince1970: 1000),
            lastSeen: Date(timeIntervalSince1970: 2000),
            channel: .nip46
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ClientIdentity.self, from: data)

        XCTAssertEqual(original, decoded)
    }

    func testEquatable_sameValuesAreEqual() {
        let date = Date(timeIntervalSince1970: 1000)
        let a = ClientIdentity(id: "x", displayName: "X", firstSeen: date, lastSeen: date, channel: .xpc)
        let b = ClientIdentity(id: "x", displayName: "X", firstSeen: date, lastSeen: date, channel: .xpc)
        XCTAssertEqual(a, b)
    }

    func testEquatable_differentIdsAreNotEqual() {
        let date = Date(timeIntervalSince1970: 1000)
        let a = ClientIdentity(id: "a", firstSeen: date, lastSeen: date, channel: .xpc)
        let b = ClientIdentity(id: "b", firstSeen: date, lastSeen: date, channel: .xpc)
        XCTAssertNotEqual(a, b)
    }

    func testIdentifiable_idProperty() {
        let client = ClientIdentity(id: "com.myapp", channel: .urlScheme)
        XCTAssertEqual(client.id, "com.myapp")
    }

    func testAllChannelValues_codable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for channel in Channel.allCases {
            let client = ClientIdentity(
                id: "test.\(channel.rawValue)",
                firstSeen: Date(timeIntervalSince1970: 0),
                lastSeen: Date(timeIntervalSince1970: 0),
                channel: channel
            )
            encoder.dateEncodingStrategy = .iso8601
            decoder.dateDecodingStrategy = .iso8601
            let data = try encoder.encode(client)
            let roundTripped = try decoder.decode(ClientIdentity.self, from: data)
            XCTAssertEqual(client, roundTripped)
        }
    }
}

// MARK: - ClientRegistryError Tests

final class ClientRegistryErrorTests: XCTestCase {

    func testClientNotFound_equatable() {
        XCTAssertEqual(
            ClientRegistryError.clientNotFound("x"),
            ClientRegistryError.clientNotFound("x")
        )
        XCTAssertNotEqual(
            ClientRegistryError.clientNotFound("x"),
            ClientRegistryError.clientNotFound("y")
        )
    }

    func testStorageUnavailable_equatable() {
        XCTAssertEqual(
            ClientRegistryError.storageUnavailable("a"),
            ClientRegistryError.storageUnavailable("a")
        )
    }

    func testDataCorrupt_equatable() {
        XCTAssertEqual(
            ClientRegistryError.dataCorrupt("bad"),
            ClientRegistryError.dataCorrupt("bad")
        )
    }

    func testDifferentCases_notEqual() {
        XCTAssertNotEqual(
            ClientRegistryError.clientNotFound("x") as ClientRegistryError,
            ClientRegistryError.storageUnavailable("x") as ClientRegistryError
        )
    }
}

// MARK: - FileClientRegistry Tests

final class FileClientRegistryTests: XCTestCase {

    private var tempDir: URL!
    private var registry: FileClientRegistry!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyfobTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        registry = try! FileClientRegistry(containerURL: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeContext(
        clientID: String = "com.example.app",
        channel: Channel = .urlScheme,
        displayName: String? = nil
    ) -> ClientContext {
        ClientContext(
            channel: channel,
            clientID: clientID,
            webOrigin: nil,
            bundleID: clientID,
            displayName: displayName,
            approvalPreference: .inheritPolicy
        )
    }

    // MARK: - registerOrUpdate

    func testRegisterOrUpdate_newClient() throws {
        let ctx = makeContext(clientID: "com.new.app", displayName: "New App")
        let client = try registry.registerOrUpdate(from: ctx)

        XCTAssertEqual(client.id, "com.new.app")
        XCTAssertEqual(client.displayName, "New App")
        XCTAssertEqual(client.channel, .urlScheme)
    }

    func testRegisterOrUpdate_existingClient_updatesLastSeen() throws {
        let ctx = makeContext(clientID: "com.test")
        let first = try registry.registerOrUpdate(from: ctx)

        // Small delay to ensure lastSeen differs.
        Thread.sleep(forTimeInterval: 0.01)

        let second = try registry.registerOrUpdate(from: ctx)

        XCTAssertEqual(first.id, second.id)
        // firstSeen may lose sub-millisecond precision through JSON roundtrip.
        XCTAssertEqual(
            first.firstSeen.timeIntervalSince1970,
            second.firstSeen.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(second.lastSeen, first.lastSeen)
    }

    func testRegisterOrUpdate_existingClient_updatesDisplayName() throws {
        let ctx1 = makeContext(clientID: "com.test", displayName: "Old Name")
        _ = try registry.registerOrUpdate(from: ctx1)

        let ctx2 = makeContext(clientID: "com.test", displayName: "New Name")
        let updated = try registry.registerOrUpdate(from: ctx2)

        XCTAssertEqual(updated.displayName, "New Name")
    }

    func testRegisterOrUpdate_existingClient_emptyNameDoesNotOverwrite() throws {
        let ctx1 = makeContext(clientID: "com.test", displayName: "Keep Me")
        _ = try registry.registerOrUpdate(from: ctx1)

        let ctx2 = makeContext(clientID: "com.test", displayName: "")
        let updated = try registry.registerOrUpdate(from: ctx2)

        XCTAssertEqual(updated.displayName, "Keep Me")
    }

    func testRegisterOrUpdate_existingClient_nilNameDoesNotOverwrite() throws {
        let ctx1 = makeContext(clientID: "com.test", displayName: "Existing")
        _ = try registry.registerOrUpdate(from: ctx1)

        let ctx2 = makeContext(clientID: "com.test", displayName: nil)
        let updated = try registry.registerOrUpdate(from: ctx2)

        XCTAssertEqual(updated.displayName, "Existing")
    }

    func testRegisterOrUpdate_multipleClients() throws {
        _ = try registry.registerOrUpdate(from: makeContext(clientID: "app.one"))
        _ = try registry.registerOrUpdate(from: makeContext(clientID: "app.two"))
        _ = try registry.registerOrUpdate(from: makeContext(clientID: "app.three"))

        let all = try registry.listClients()
        XCTAssertEqual(all.count, 3)
    }

    // MARK: - lookup

    func testLookup_existingClient() throws {
        _ = try registry.registerOrUpdate(from: makeContext(clientID: "com.found", displayName: "Found"))
        let client = try registry.lookup(id: "com.found")

        XCTAssertNotNil(client)
        XCTAssertEqual(client?.id, "com.found")
        XCTAssertEqual(client?.displayName, "Found")
    }

    func testLookup_nonexistentClient() throws {
        let client = try registry.lookup(id: "com.missing")
        XCTAssertNil(client)
    }

    // MARK: - listClients

    func testListClients_empty() throws {
        let all = try registry.listClients()
        XCTAssertEqual(all.count, 0)
    }

    func testListClients_sortedByLastSeenDescending() throws {
        _ = try registry.registerOrUpdate(from: makeContext(clientID: "oldest"))
        Thread.sleep(forTimeInterval: 0.01)
        _ = try registry.registerOrUpdate(from: makeContext(clientID: "middle"))
        Thread.sleep(forTimeInterval: 0.01)
        _ = try registry.registerOrUpdate(from: makeContext(clientID: "newest"))

        let all = try registry.listClients()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all[0].id, "newest")
        XCTAssertEqual(all[1].id, "middle")
        XCTAssertEqual(all[2].id, "oldest")
    }

    // MARK: - remove

    func testRemove_existingClient() throws {
        _ = try registry.registerOrUpdate(from: makeContext(clientID: "com.remove.me"))
        try registry.remove(id: "com.remove.me")

        let client = try registry.lookup(id: "com.remove.me")
        XCTAssertNil(client)
    }

    func testRemove_nonexistentClient_throws() {
        XCTAssertThrowsError(try registry.remove(id: "com.ghost")) { error in
            guard let registryError = error as? ClientRegistryError else {
                XCTFail("Expected ClientRegistryError, got \(error)")
                return
            }
            XCTAssertEqual(registryError, .clientNotFound("com.ghost"))
        }
    }

    func testRemove_onlyRemovesTargetClient() throws {
        _ = try registry.registerOrUpdate(from: makeContext(clientID: "keep"))
        _ = try registry.registerOrUpdate(from: makeContext(clientID: "remove"))

        try registry.remove(id: "remove")

        let all = try registry.listClients()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].id, "keep")
    }

    // MARK: - Persistence

    func testPersistence_survivesFreshLoad() throws {
        _ = try registry.registerOrUpdate(from: makeContext(clientID: "persistent", displayName: "Survives"))

        // Create a new instance pointing at the same directory.
        let freshRegistry = try FileClientRegistry(containerURL: tempDir)
        let client = try freshRegistry.lookup(id: "persistent")

        XCTAssertNotNil(client)
        XCTAssertEqual(client?.displayName, "Survives")
    }

    func testPersistence_removeSurvivesFreshLoad() throws {
        _ = try registry.registerOrUpdate(from: makeContext(clientID: "gone"))
        try registry.remove(id: "gone")

        let freshRegistry = try FileClientRegistry(containerURL: tempDir)
        let client = try freshRegistry.lookup(id: "gone")
        XCTAssertNil(client)
    }

    // MARK: - Channel diversity

    func testRegister_differentChannels() throws {
        let channels: [Channel] = [.universalLink, .urlScheme, .xpc, .appIntent,
                                    .actionExtension, .safariWebExtension, .safariAppExtension, .nip46]

        for (i, channel) in channels.enumerated() {
            let ctx = ClientContext(
                channel: channel,
                clientID: "client.\(i)",
                webOrigin: nil,
                bundleID: nil,
                displayName: nil,
                approvalPreference: .inheritPolicy
            )
            let client = try registry.registerOrUpdate(from: ctx)
            XCTAssertEqual(client.channel, channel)
        }

        let all = try registry.listClients()
        XCTAssertEqual(all.count, channels.count)
    }

    // MARK: - Edge cases

    func testRegister_emptyClientID() throws {
        let ctx = makeContext(clientID: "")
        let client = try registry.registerOrUpdate(from: ctx)
        XCTAssertEqual(client.id, "")

        let found = try registry.lookup(id: "")
        XCTAssertNotNil(found)
    }

    func testRegister_unicodeClientID() throws {
        let ctx = makeContext(clientID: "日本語.app", displayName: "日本語アプリ")
        let client = try registry.registerOrUpdate(from: ctx)
        XCTAssertEqual(client.id, "日本語.app")
        XCTAssertEqual(client.displayName, "日本語アプリ")

        // Verify round-trip through persistence.
        let fresh = try FileClientRegistry(containerURL: tempDir)
        let found = try fresh.lookup(id: "日本語.app")
        XCTAssertEqual(found?.displayName, "日本語アプリ")
    }
}
