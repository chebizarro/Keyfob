//
//  OrchestratorPipelineTests.swift
//
//
//  Created for Keyfob – kf-85t
//

import XCTest
@testable import KeyfobCore
@testable import KeyfobCrypto
import KeyfobPolicy
import NostrSDK

// MARK: - Mock IdentityStore

/// In-memory IdentityStore for testing the pipeline without Keychain access.
private final class PipelineMockStore: IdentityStore, @unchecked Sendable {

    private var identities: [UUID: (identity: Identity, keypair: NostrSDK.Keypair)] = [:]
    private var activeID: UUID?

    func createIdentity(label: String?, makeActive: Bool) throws -> Identity {
        guard let keypair = NostrSDK.Keypair() else {
            throw IdentityStoreError.invalidPrivateKey
        }
        let id = UUID()
        let identity = Identity(
            id: id,
            pubkeyHex: keypair.publicKey.hex,
            label: label,
            createdAt: Date(),
            source: .generated,
            isActive: makeActive
        )
        identities[id] = (identity, keypair)
        if makeActive { activeID = id }
        return identity
    }

    func importIdentity(privateKeyHex: String, source: IdentitySource, label: String?, makeActive: Bool) throws -> Identity {
        guard let pk = NostrSDK.PrivateKey(hex: privateKeyHex),
              let keypair = NostrSDK.Keypair(privateKey: pk) else {
            throw IdentityStoreError.invalidPrivateKey
        }
        let id = UUID()
        let identity = Identity(
            id: id,
            pubkeyHex: keypair.publicKey.hex,
            label: label,
            createdAt: Date(),
            source: source,
            isActive: makeActive
        )
        identities[id] = (identity, keypair)
        if makeActive { activeID = id }
        return identity
    }

    func listIdentities() throws -> [Identity] {
        identities.values.map { $0.identity }
    }

    func activeIdentity() throws -> Identity? {
        guard let id = activeID else { return nil }
        return identities[id]?.identity
    }

    func setActiveIdentity(_ id: UUID?) throws {
        if let id = id {
            guard identities[id] != nil else {
                throw IdentityStoreError.identityNotFound(id)
            }
        }
        activeID = id
    }

    func updateLabel(for id: UUID, label: String?) throws {
        guard identities[id] != nil else {
            throw IdentityStoreError.identityNotFound(id)
        }
        identities[id]!.identity.label = label
    }

    func deleteIdentity(_ id: UUID) throws {
        identities.removeValue(forKey: id)
        if activeID == id { activeID = nil }
    }

    func loadSDKKeypair(for identityID: UUID) throws -> NostrSDK.Keypair {
        guard let entry = identities[identityID] else {
            throw IdentityStoreError.identityNotFound(identityID)
        }
        return entry.keypair
    }

    func observeActiveIdentity() -> AsyncStream<Identity?> {
        AsyncStream { continuation in
            if let id = activeID {
                continuation.yield(identities[id]?.identity)
            }
            continuation.finish()
        }
    }
}

// MARK: - Mock Consent Provider

/// Auto-approve or auto-deny consent for pipeline tests.
private final class MockConsentProvider: PolicyEngine.ConsentProvider {
    var shouldApprove = true
    var callCount = 0

    func requestConsent(origin: String, eventPreview: String, mode: PolicyEngine.ConsentMode) throws {
        callCount += 1
        if !shouldApprove {
            throw NSError(
                domain: "MockConsent", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "User denied"]
            )
        }
    }
}

// MARK: - Sign Operation Tests

final class PipelineSignTests: XCTestCase {

    private var store: PipelineMockStore!
    private var consent: MockConsentProvider!
    private var orchestrator: SignOrchestrator!

    override func setUp() {
        super.setUp()
        store = PipelineMockStore()
        consent = MockConsentProvider()
        PolicyEngine.shared.consentProvider = consent
        orchestrator = SignOrchestrator(identityStore: store)
    }

    override func tearDown() {
        PolicyEngine.shared.consentProvider = nil
        super.tearDown()
    }

    private func testClient(_ id: String = "com.test.sign.\(UUID().uuidString)") -> ClientContext {
        ClientContext(channel: .xpc, clientID: id)
    }

    func testSignOperation_happyPath() throws {
        let identity = try store.createIdentity(label: "Test", makeActive: true)
        let event = NostrEvent(
            kind: 1, pubkey: identity.pubkeyHex,
            created_at: 1000, tags: [], content: "hello"
        )

        let output = try orchestrator.execute(
            operation: .sign(event), identity: .active, client: testClient()
        )

        guard case .signature(let resp) = output else {
            XCTFail("Expected .signature output"); return
        }
        XCTAssertFalse(resp.id.isEmpty, "Event id should be computed")
        XCTAssertFalse(resp.sig.isEmpty, "Signature should be produced")
        XCTAssertEqual(resp.pubkey, identity.pubkeyHex)
    }

    func testSignOperation_emptyEventPubkey_allowed() throws {
        let identity = try store.createIdentity(label: "Test", makeActive: true)
        let event = NostrEvent(
            kind: 1, pubkey: "", created_at: 1000, tags: [], content: "hello"
        )

        let output = try orchestrator.execute(
            operation: .sign(event), identity: .active, client: testClient()
        )

        guard case .signature(let resp) = output else {
            XCTFail("Expected .signature output"); return
        }
        // Signer fills in the pubkey from the keypair
        XCTAssertEqual(resp.pubkey, identity.pubkeyHex)
    }

    func testSignOperation_eventPubkeyMismatch_throws() throws {
        _ = try store.createIdentity(label: "Test", makeActive: true)
        let wrongPK = String(repeating: "a", count: 64)
        let event = NostrEvent(
            kind: 1, pubkey: wrongPK, created_at: 1000, tags: [], content: "hello"
        )

        XCTAssertThrowsError(try orchestrator.execute(
            operation: .sign(event), identity: .active, client: testClient()
        )) { error in
            guard let pipelineError = error as? OperationPipelineError,
                  case .eventPubkeyMismatch = pipelineError else {
                XCTFail("Expected eventPubkeyMismatch, got \(error)"); return
            }
        }
    }

    func testSignOperation_withTags() throws {
        let identity = try store.createIdentity(label: "Test", makeActive: true)
        let event = NostrEvent(
            kind: 1, pubkey: identity.pubkeyHex,
            created_at: 2000, tags: [["e", "abc"], ["p", "def"]], content: "tagged"
        )

        let output = try orchestrator.execute(
            operation: .sign(event), identity: .active, client: testClient()
        )

        guard case .signature(let resp) = output else {
            XCTFail("Expected .signature output"); return
        }
        XCTAssertFalse(resp.id.isEmpty)
        XCTAssertEqual(resp.pubkey, identity.pubkeyHex)
    }

    func testSignOperation_deterministicId() throws {
        let identity = try store.createIdentity(label: "Test", makeActive: true)
        let event = NostrEvent(
            kind: 1, pubkey: identity.pubkeyHex,
            created_at: 1000, tags: [], content: "hello"
        )
        let client = testClient()

        let out1 = try orchestrator.execute(
            operation: .sign(event), identity: .active, client: client
        )
        let out2 = try orchestrator.execute(
            operation: .sign(event), identity: .active, client: client
        )

        guard case .signature(let r1) = out1, case .signature(let r2) = out2 else {
            XCTFail("Expected .signature output"); return
        }
        // Same event + same key → same NIP-01 event id (deterministic SHA-256 hash)
        XCTAssertEqual(r1.id, r2.id)
        // Schnorr signatures may use random aux nonces, so sigs can differ.
        // Just verify both are valid 128-char hex strings.
        XCTAssertEqual(r1.sig.count, 128)
        XCTAssertEqual(r2.sig.count, 128)
        XCTAssertTrue(r1.sig.allSatisfy { $0.isHexDigit })
        XCTAssertTrue(r2.sig.allSatisfy { $0.isHexDigit })
    }
}

// MARK: - NIP-44 Operation Tests

final class PipelineNIP44Tests: XCTestCase {

    private var store: PipelineMockStore!
    private var consent: MockConsentProvider!
    private var orchestrator: SignOrchestrator!

    override func setUp() {
        super.setUp()
        store = PipelineMockStore()
        consent = MockConsentProvider()
        PolicyEngine.shared.consentProvider = consent
        orchestrator = SignOrchestrator(identityStore: store)
    }

    override func tearDown() {
        PolicyEngine.shared.consentProvider = nil
        super.tearDown()
    }

    private func testClient() -> ClientContext {
        ClientContext(channel: .xpc, clientID: "com.test.nip44.\(UUID().uuidString)")
    }

    func testNip44Encrypt_happyPath() throws {
        _ = try store.createIdentity(label: "Test", makeActive: true)
        guard let peer = NostrSDK.Keypair() else { XCTFail("Keypair gen failed"); return }

        let output = try orchestrator.execute(
            operation: .nip44Encrypt(peerPubkeyHex: peer.publicKey.hex, plaintext: "secret"),
            identity: .active, client: testClient()
        )

        guard case .ciphertext(let ct) = output else {
            XCTFail("Expected .ciphertext output"); return
        }
        XCTAssertFalse(ct.isEmpty)
    }

    func testNip44EncryptDecrypt_roundTrip() throws {
        _ = try store.createIdentity(label: "Test", makeActive: true)
        guard let peer = NostrSDK.Keypair() else { XCTFail("Keypair gen failed"); return }

        let plaintext = "hello NIP-44! 🔐"
        let client = testClient()

        let encOut = try orchestrator.execute(
            operation: .nip44Encrypt(peerPubkeyHex: peer.publicKey.hex, plaintext: plaintext),
            identity: .active, client: client
        )
        guard case .ciphertext(let ct) = encOut else {
            XCTFail("Expected .ciphertext"); return
        }

        // Decrypt with the same identity + same peer → should recover plaintext
        let decOut = try orchestrator.execute(
            operation: .nip44Decrypt(peerPubkeyHex: peer.publicKey.hex, ciphertext: ct),
            identity: .active, client: client
        )
        guard case .plaintext(let result) = decOut else {
            XCTFail("Expected .plaintext"); return
        }
        XCTAssertEqual(result, plaintext)
    }

    func testNip44Decrypt_invalidCiphertext_throws() throws {
        _ = try store.createIdentity(label: "Test", makeActive: true)
        guard let peer = NostrSDK.Keypair() else { XCTFail("Keypair gen failed"); return }

        XCTAssertThrowsError(try orchestrator.execute(
            operation: .nip44Decrypt(peerPubkeyHex: peer.publicKey.hex, ciphertext: "not-valid"),
            identity: .active, client: testClient()
        ))
    }
}

// MARK: - NIP-04 Operation Tests

final class PipelineNIP04Tests: XCTestCase {

    private var store: PipelineMockStore!
    private var consent: MockConsentProvider!
    private var orchestrator: SignOrchestrator!

    override func setUp() {
        super.setUp()
        store = PipelineMockStore()
        consent = MockConsentProvider()
        PolicyEngine.shared.consentProvider = consent
        orchestrator = SignOrchestrator(identityStore: store)
    }

    override func tearDown() {
        PolicyEngine.shared.consentProvider = nil
        super.tearDown()
    }

    private func testClient() -> ClientContext {
        ClientContext(channel: .xpc, clientID: "com.test.nip04.\(UUID().uuidString)")
    }

    func testNip04EncryptDecrypt_roundTrip() throws {
        _ = try store.createIdentity(label: "Test", makeActive: true)
        guard let peer = NostrSDK.Keypair() else { XCTFail("Keypair gen failed"); return }

        let plaintext = "hello NIP-04! (legacy)"
        let client = testClient()

        let encOut = try orchestrator.execute(
            operation: .nip04Encrypt(peerPubkeyHex: peer.publicKey.hex, plaintext: plaintext),
            identity: .active, client: client
        )
        guard case .ciphertext(let ct) = encOut else {
            XCTFail("Expected .ciphertext"); return
        }
        XCTAssertFalse(ct.isEmpty)

        let decOut = try orchestrator.execute(
            operation: .nip04Decrypt(peerPubkeyHex: peer.publicKey.hex, ciphertext: ct),
            identity: .active, client: client
        )
        guard case .plaintext(let result) = decOut else {
            XCTFail("Expected .plaintext"); return
        }
        XCTAssertEqual(result, plaintext)
    }

    func testNip04Decrypt_invalidCiphertext_throws() throws {
        _ = try store.createIdentity(label: "Test", makeActive: true)
        guard let peer = NostrSDK.Keypair() else { XCTFail("Keypair gen failed"); return }

        XCTAssertThrowsError(try orchestrator.execute(
            operation: .nip04Decrypt(peerPubkeyHex: peer.publicKey.hex, ciphertext: "garbage"),
            identity: .active, client: testClient()
        ))
    }
}

// MARK: - Identity Resolution Tests

final class PipelineIdentityTests: XCTestCase {

    private var store: PipelineMockStore!
    private var consent: MockConsentProvider!
    private var orchestrator: SignOrchestrator!

    override func setUp() {
        super.setUp()
        store = PipelineMockStore()
        consent = MockConsentProvider()
        PolicyEngine.shared.consentProvider = consent
        orchestrator = SignOrchestrator(identityStore: store)
    }

    override func tearDown() {
        PolicyEngine.shared.consentProvider = nil
        super.tearDown()
    }

    private func testClient() -> ClientContext {
        ClientContext(channel: .xpc, clientID: "com.test.identity.\(UUID().uuidString)")
    }

    func testNoActiveIdentity_throws() {
        let event = NostrEvent(kind: 1, pubkey: "", created_at: 1000, tags: [], content: "test")

        XCTAssertThrowsError(try orchestrator.execute(
            operation: .sign(event), identity: .active, client: testClient()
        )) { error in
            XCTAssertEqual(error as? OperationPipelineError, .noActiveIdentity)
        }
    }

    func testSpecificIdentity_happyPath() throws {
        let identity = try store.createIdentity(label: "Specific", makeActive: false)
        // Also create an active identity so .active wouldn't match
        _ = try store.createIdentity(label: "Active", makeActive: true)

        let event = NostrEvent(
            kind: 1, pubkey: identity.pubkeyHex,
            created_at: 1000, tags: [], content: "test"
        )

        let output = try orchestrator.execute(
            operation: .sign(event), identity: .specific(identity.id), client: testClient()
        )

        guard case .signature(let resp) = output else {
            XCTFail("Expected .signature output"); return
        }
        XCTAssertEqual(resp.pubkey, identity.pubkeyHex)
    }

    func testSpecificIdentity_notFound_throws() {
        let fakeID = UUID()
        let event = NostrEvent(kind: 1, pubkey: "", created_at: 1000, tags: [], content: "test")

        XCTAssertThrowsError(try orchestrator.execute(
            operation: .sign(event), identity: .specific(fakeID), client: testClient()
        )) { error in
            XCTAssertEqual(error as? IdentityStoreError, .identityNotFound(fakeID))
        }
    }

    func testMultipleIdentities_switchActive() throws {
        let id1 = try store.createIdentity(label: "Key 1", makeActive: true)
        let id2 = try store.createIdentity(label: "Key 2", makeActive: true)

        // Active is now id2
        let event1 = NostrEvent(kind: 1, pubkey: id2.pubkeyHex, created_at: 1000, tags: [], content: "from 2")
        let out1 = try orchestrator.execute(
            operation: .sign(event1), identity: .active, client: testClient()
        )
        guard case .signature(let r1) = out1 else { XCTFail(); return }
        XCTAssertEqual(r1.pubkey, id2.pubkeyHex)

        // Switch active to id1
        try store.setActiveIdentity(id1.id)
        let event2 = NostrEvent(kind: 1, pubkey: id1.pubkeyHex, created_at: 1000, tags: [], content: "from 1")
        let out2 = try orchestrator.execute(
            operation: .sign(event2), identity: .active, client: testClient()
        )
        guard case .signature(let r2) = out2 else { XCTFail(); return }
        XCTAssertEqual(r2.pubkey, id1.pubkeyHex)
    }

    func testSpecificIdentity_overridesActive() throws {
        _ = try store.createIdentity(label: "Key 1", makeActive: true)
        let id2 = try store.createIdentity(label: "Key 2", makeActive: false)

        let event = NostrEvent(
            kind: 1, pubkey: id2.pubkeyHex,
            created_at: 1000, tags: [], content: "from key 2"
        )

        let output = try orchestrator.execute(
            operation: .sign(event), identity: .specific(id2.id), client: testClient()
        )
        guard case .signature(let resp) = output else { XCTFail(); return }
        XCTAssertEqual(resp.pubkey, id2.pubkeyHex)
    }
}

// MARK: - Validation Tests

final class PipelineValidationTests: XCTestCase {

    private var store: PipelineMockStore!
    private var consent: MockConsentProvider!
    private var orchestrator: SignOrchestrator!

    override func setUp() {
        super.setUp()
        store = PipelineMockStore()
        consent = MockConsentProvider()
        PolicyEngine.shared.consentProvider = consent
        orchestrator = SignOrchestrator(identityStore: store)
    }

    override func tearDown() {
        PolicyEngine.shared.consentProvider = nil
        super.tearDown()
    }

    private func testClient() -> ClientContext {
        ClientContext(channel: .xpc, clientID: "com.test.valid.\(UUID().uuidString)")
    }

    func testInvalidPeerPubkey_tooShort() throws {
        _ = try store.createIdentity(label: "Test", makeActive: true)

        XCTAssertThrowsError(try orchestrator.execute(
            operation: .nip44Encrypt(peerPubkeyHex: "abcd", plaintext: "test"),
            identity: .active, client: testClient()
        )) { error in
            XCTAssertEqual(error as? OperationPipelineError, .invalidPeerPublicKey("abcd"))
        }
    }

    func testInvalidPeerPubkey_tooLong() throws {
        _ = try store.createIdentity(label: "Test", makeActive: true)
        let longPK = String(repeating: "a", count: 66)

        XCTAssertThrowsError(try orchestrator.execute(
            operation: .nip44Encrypt(peerPubkeyHex: longPK, plaintext: "test"),
            identity: .active, client: testClient()
        )) { error in
            XCTAssertEqual(error as? OperationPipelineError, .invalidPeerPublicKey(longPK))
        }
    }

    func testInvalidPeerPubkey_uppercase() throws {
        _ = try store.createIdentity(label: "Test", makeActive: true)
        let upperPK = String(repeating: "A", count: 64)

        XCTAssertThrowsError(try orchestrator.execute(
            operation: .nip44Encrypt(peerPubkeyHex: upperPK, plaintext: "test"),
            identity: .active, client: testClient()
        )) { error in
            XCTAssertEqual(error as? OperationPipelineError, .invalidPeerPublicKey(upperPK))
        }
    }

    func testInvalidPeerPubkey_nonHex() throws {
        _ = try store.createIdentity(label: "Test", makeActive: true)
        let nonHex = String(repeating: "g", count: 64)

        XCTAssertThrowsError(try orchestrator.execute(
            operation: .nip44Decrypt(peerPubkeyHex: nonHex, ciphertext: "test"),
            identity: .active, client: testClient()
        )) { error in
            XCTAssertEqual(error as? OperationPipelineError, .invalidPeerPublicKey(nonHex))
        }
    }

    func testValidation_runsBeforeIdentityResolution() {
        // Bad peer pubkey should fail even without any identity in the store
        XCTAssertThrowsError(try orchestrator.execute(
            operation: .nip44Encrypt(peerPubkeyHex: "short", plaintext: "test"),
            identity: .active, client: testClient()
        )) { error in
            // Should get invalidPeerPublicKey, NOT noActiveIdentity
            XCTAssertEqual(error as? OperationPipelineError, .invalidPeerPublicKey("short"))
        }
    }

    func testValidation_allCryptoOps() throws {
        _ = try store.createIdentity(label: "Test", makeActive: true)
        let badPK = "tooshort"

        // nip44Encrypt
        XCTAssertThrowsError(try orchestrator.execute(
            operation: .nip44Encrypt(peerPubkeyHex: badPK, plaintext: ""),
            identity: .active, client: testClient()
        )) { XCTAssertEqual($0 as? OperationPipelineError, .invalidPeerPublicKey(badPK)) }

        // nip44Decrypt
        XCTAssertThrowsError(try orchestrator.execute(
            operation: .nip44Decrypt(peerPubkeyHex: badPK, ciphertext: ""),
            identity: .active, client: testClient()
        )) { XCTAssertEqual($0 as? OperationPipelineError, .invalidPeerPublicKey(badPK)) }

        // nip04Encrypt
        XCTAssertThrowsError(try orchestrator.execute(
            operation: .nip04Encrypt(peerPubkeyHex: badPK, plaintext: ""),
            identity: .active, client: testClient()
        )) { XCTAssertEqual($0 as? OperationPipelineError, .invalidPeerPublicKey(badPK)) }

        // nip04Decrypt
        XCTAssertThrowsError(try orchestrator.execute(
            operation: .nip04Decrypt(peerPubkeyHex: badPK, ciphertext: ""),
            identity: .active, client: testClient()
        )) { XCTAssertEqual($0 as? OperationPipelineError, .invalidPeerPublicKey(badPK)) }
    }
}

// MARK: - Policy Integration Tests

final class PipelinePolicyTests: XCTestCase {

    private var store: PipelineMockStore!
    private var consent: MockConsentProvider!
    private var orchestrator: SignOrchestrator!

    override func setUp() {
        super.setUp()
        store = PipelineMockStore()
        consent = MockConsentProvider()
        PolicyEngine.shared.consentProvider = consent
        orchestrator = SignOrchestrator(identityStore: store)
    }

    override func tearDown() {
        PolicyEngine.shared.consentProvider = nil
        super.tearDown()
    }

    private func testClient(_ id: String? = nil) -> ClientContext {
        ClientContext(
            channel: .xpc,
            clientID: id ?? "com.test.policy.\(UUID().uuidString)"
        )
    }

    func testConsentDenied_throws() throws {
        _ = try store.createIdentity(label: "Test", makeActive: true)
        consent.shouldApprove = false

        let event = NostrEvent(kind: 1, pubkey: "", created_at: 1000, tags: [], content: "test")

        XCTAssertThrowsError(try orchestrator.execute(
            operation: .sign(event), identity: .active, client: testClient()
        ))
    }

    func testConsentCalled_forEachExecute() throws {
        _ = try store.createIdentity(label: "Test", makeActive: true)
        guard let peer = NostrSDK.Keypair() else { XCTFail("Keypair gen failed"); return }
        let peerHex = peer.publicKey.hex

        let event = NostrEvent(kind: 1, pubkey: "", created_at: 1000, tags: [], content: "test")

        _ = try orchestrator.execute(
            operation: .sign(event), identity: .active, client: testClient()
        )
        XCTAssertEqual(consent.callCount, 1)

        _ = try orchestrator.execute(
            operation: .nip44Encrypt(peerPubkeyHex: peerHex, plaintext: "hi"),
            identity: .active, client: testClient()
        )
        XCTAssertEqual(consent.callCount, 2)
    }

    func testNoConsentProvider_throws() throws {
        _ = try store.createIdentity(label: "Test", makeActive: true)
        PolicyEngine.shared.consentProvider = nil

        let event = NostrEvent(kind: 1, pubkey: "", created_at: 1000, tags: [], content: "test")

        XCTAssertThrowsError(try orchestrator.execute(
            operation: .sign(event), identity: .active, client: testClient()
        ))
    }

    func testSessionApprovalPreference() throws {
        _ = try store.createIdentity(label: "Test", makeActive: true)
        let event = NostrEvent(kind: 1, pubkey: "", created_at: 1000, tags: [], content: "test")
        let client = ClientContext(
            channel: .xpc,
            clientID: "com.test.session.\(UUID().uuidString)",
            approvalPreference: .session
        )

        // Should complete without error — session mode still goes through consent
        let output = try orchestrator.execute(
            operation: .sign(event), identity: .active, client: client
        )
        guard case .signature = output else { XCTFail("Expected .signature"); return }
    }
}

// MARK: - Legacy API Tests

final class PipelineLegacyTests: XCTestCase {

    private var consent: MockConsentProvider!

    override func setUp() {
        super.setUp()
        consent = MockConsentProvider()
        PolicyEngine.shared.consentProvider = consent
    }

    override func tearDown() {
        PolicyEngine.shared.consentProvider = nil
        super.tearDown()
    }

    func testLegacyInit_executeFails() {
        let legacy = SignOrchestrator()
        let event = NostrEvent(kind: 1, pubkey: "", created_at: 1000, tags: [], content: "test")

        XCTAssertThrowsError(try legacy.execute(
            operation: .sign(event),
            identity: .active,
            client: ClientContext(channel: .xpc, clientID: "com.test.legacy")
        )) { error in
            XCTAssertEqual(error as? OperationPipelineError, .noActiveIdentity)
        }
    }

    func testLegacyModeEnum_exists() {
        // Verify the legacy Mode enum still compiles and has both cases
        let perReq = SignOrchestrator.Mode.perRequest
        let sess = SignOrchestrator.Mode.session
        XCTAssertNotEqual(String(describing: perReq), String(describing: sess))
    }

    func testLegacyInit_noStoreForCryptoOps() {
        let legacy = SignOrchestrator()

        // All operation types should fail with noActiveIdentity
        XCTAssertThrowsError(try legacy.execute(
            operation: .nip44Encrypt(peerPubkeyHex: String(repeating: "a", count: 64), plaintext: ""),
            identity: .active,
            client: ClientContext(channel: .xpc, clientID: "com.test")
        )) { error in
            XCTAssertEqual(error as? OperationPipelineError, .noActiveIdentity)
        }
    }
}

// MARK: - Pipeline Conformance Tests

final class PipelineConformanceTests: XCTestCase {

    func testConformsToOperationPipeline() {
        let store = PipelineMockStore()
        let orchestrator = SignOrchestrator(identityStore: store)
        // Compile-time check: SignOrchestrator conforms to OperationPipeline
        let pipeline: OperationPipeline = orchestrator
        XCTAssertNotNil(pipeline)
    }

    func testAllOperationTypes_returnCorrectOutputVariants() throws {
        let store = PipelineMockStore()
        let consent = MockConsentProvider()
        PolicyEngine.shared.consentProvider = consent
        defer { PolicyEngine.shared.consentProvider = nil }

        _ = try store.createIdentity(label: "Test", makeActive: true)
        let orchestrator = SignOrchestrator(identityStore: store)
        guard let peer = NostrSDK.Keypair() else { XCTFail("Keypair gen failed"); return }
        let peerHex = peer.publicKey.hex

        let client = ClientContext(
            channel: .xpc,
            clientID: "com.test.variants.\(UUID().uuidString)"
        )

        // Sign → .signature
        let event = NostrEvent(kind: 1, pubkey: "", created_at: 1000, tags: [], content: "test")
        let signOut = try orchestrator.execute(
            operation: .sign(event), identity: .active, client: client
        )
        if case .signature = signOut { } else { XCTFail("Expected .signature for sign") }

        // NIP-44 encrypt → .ciphertext
        let enc44 = try orchestrator.execute(
            operation: .nip44Encrypt(peerPubkeyHex: peerHex, plaintext: "hi"),
            identity: .active, client: client
        )
        if case .ciphertext = enc44 { } else { XCTFail("Expected .ciphertext for nip44Encrypt") }

        // NIP-04 encrypt → .ciphertext
        let enc04 = try orchestrator.execute(
            operation: .nip04Encrypt(peerPubkeyHex: peerHex, plaintext: "hi"),
            identity: .active, client: client
        )
        if case .ciphertext = enc04 { } else { XCTFail("Expected .ciphertext for nip04Encrypt") }
    }

    func testOutputKind_matchesOperationKind() throws {
        let store = PipelineMockStore()
        let consent = MockConsentProvider()
        PolicyEngine.shared.consentProvider = consent
        defer { PolicyEngine.shared.consentProvider = nil }

        _ = try store.createIdentity(label: "Test", makeActive: true)
        let orchestrator = SignOrchestrator(identityStore: store)
        guard let peer = NostrSDK.Keypair() else { XCTFail("Keypair gen failed"); return }
        let peerHex = peer.publicKey.hex
        let client = ClientContext(
            channel: .xpc,
            clientID: "com.test.kindmatch.\(UUID().uuidString)"
        )

        // Encrypt then decrypt — verify output types match expectation
        let encOut = try orchestrator.execute(
            operation: .nip44Encrypt(peerPubkeyHex: peerHex, plaintext: "msg"),
            identity: .active, client: client
        )
        guard case .ciphertext(let ct) = encOut else { XCTFail("Expected ciphertext"); return }

        let decOut = try orchestrator.execute(
            operation: .nip44Decrypt(peerPubkeyHex: peerHex, ciphertext: ct),
            identity: .active, client: client
        )
        guard case .plaintext(let pt) = decOut else { XCTFail("Expected plaintext"); return }
        XCTAssertEqual(pt, "msg")
    }
}

// MARK: - Client Context Tests

final class PipelineClientContextTests: XCTestCase {

    private var store: PipelineMockStore!
    private var consent: MockConsentProvider!
    private var orchestrator: SignOrchestrator!

    override func setUp() {
        super.setUp()
        store = PipelineMockStore()
        consent = MockConsentProvider()
        PolicyEngine.shared.consentProvider = consent
        orchestrator = SignOrchestrator(identityStore: store)
    }

    override func tearDown() {
        PolicyEngine.shared.consentProvider = nil
        super.tearDown()
    }

    func testDifferentChannels_allWork() throws {
        _ = try store.createIdentity(label: "Test", makeActive: true)
        let event = NostrEvent(kind: 1, pubkey: "", created_at: 1000, tags: [], content: "test")

        for channel in Channel.allCases {
            let client = ClientContext(
                channel: channel,
                clientID: "com.test.\(channel.rawValue).\(UUID().uuidString)"
            )
            let output = try orchestrator.execute(
                operation: .sign(event), identity: .active, client: client
            )
            guard case .signature = output else { XCTFail("Failed for channel \(channel)"); return }
        }
    }

    func testApprovalPreference_perRequest() throws {
        _ = try store.createIdentity(label: "Test", makeActive: true)
        let event = NostrEvent(kind: 1, pubkey: "", created_at: 1000, tags: [], content: "test")

        let client = ClientContext(
            channel: .xpc,
            clientID: "com.test.perreq.\(UUID().uuidString)",
            approvalPreference: .perRequest
        )
        let output = try orchestrator.execute(
            operation: .sign(event), identity: .active, client: client
        )
        guard case .signature = output else { XCTFail("Expected .signature"); return }
    }

    func testApprovalPreference_inheritPolicy() throws {
        _ = try store.createIdentity(label: "Test", makeActive: true)
        let event = NostrEvent(kind: 1, pubkey: "", created_at: 1000, tags: [], content: "test")

        let client = ClientContext(
            channel: .xpc,
            clientID: "com.test.inherit.\(UUID().uuidString)",
            approvalPreference: .inheritPolicy
        )
        let output = try orchestrator.execute(
            operation: .sign(event), identity: .active, client: client
        )
        guard case .signature = output else { XCTFail("Expected .signature"); return }
    }
}
