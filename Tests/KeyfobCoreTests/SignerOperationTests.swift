//
//  SignerOperationTests.swift
//
//
//  Created for Keyfob – kf-rek
//

import XCTest
@testable import KeyfobCore
import KeyfobCrypto

// MARK: - SignerOperationKind Tests

final class SignerOperationKindTests: XCTestCase {

    func testAllCases() {
        let kinds = SignerOperationKind.allCases
        XCTAssertEqual(kinds.count, 5)
        XCTAssertTrue(kinds.contains(.sign))
        XCTAssertTrue(kinds.contains(.nip44Encrypt))
        XCTAssertTrue(kinds.contains(.nip44Decrypt))
        XCTAssertTrue(kinds.contains(.nip04Encrypt))
        XCTAssertTrue(kinds.contains(.nip04Decrypt))
    }

    func testRawValues() {
        XCTAssertEqual(SignerOperationKind.sign.rawValue, "sign")
        XCTAssertEqual(SignerOperationKind.nip44Encrypt.rawValue, "nip44Encrypt")
        XCTAssertEqual(SignerOperationKind.nip44Decrypt.rawValue, "nip44Decrypt")
        XCTAssertEqual(SignerOperationKind.nip04Encrypt.rawValue, "nip04Encrypt")
        XCTAssertEqual(SignerOperationKind.nip04Decrypt.rawValue, "nip04Decrypt")
    }

    func testCodableRoundTrip() throws {
        for kind in SignerOperationKind.allCases {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(SignerOperationKind.self, from: data)
            XCTAssertEqual(kind, decoded)
        }
    }
}

// MARK: - SignerOperation Tests

final class SignerOperationTests: XCTestCase {

    private let sampleEvent = NostrEvent(
        kind: 1,
        pubkey: "aaaa",
        created_at: 1000,
        tags: [["e", "1234"]],
        content: "hello"
    )

    // MARK: - Kind derivation

    func testSignKind() {
        let op = SignerOperation.sign(sampleEvent)
        XCTAssertEqual(op.kind, .sign)
    }

    func testNip44EncryptKind() {
        let op = SignerOperation.nip44Encrypt(peerPubkeyHex: "bbbb", plaintext: "hi")
        XCTAssertEqual(op.kind, .nip44Encrypt)
    }

    func testNip44DecryptKind() {
        let op = SignerOperation.nip44Decrypt(peerPubkeyHex: "bbbb", ciphertext: "enc")
        XCTAssertEqual(op.kind, .nip44Decrypt)
    }

    func testNip04EncryptKind() {
        let op = SignerOperation.nip04Encrypt(peerPubkeyHex: "bbbb", plaintext: "hi")
        XCTAssertEqual(op.kind, .nip04Encrypt)
    }

    func testNip04DecryptKind() {
        let op = SignerOperation.nip04Decrypt(peerPubkeyHex: "bbbb", ciphertext: "enc")
        XCTAssertEqual(op.kind, .nip04Decrypt)
    }

    // MARK: - eventKind

    func testSignEventKind() {
        let op = SignerOperation.sign(sampleEvent)
        XCTAssertEqual(op.eventKind, 1)
    }

    func testCryptoOpsEventKindIsNil() {
        XCTAssertNil(SignerOperation.nip44Encrypt(peerPubkeyHex: "aa", plaintext: "").eventKind)
        XCTAssertNil(SignerOperation.nip44Decrypt(peerPubkeyHex: "aa", ciphertext: "").eventKind)
        XCTAssertNil(SignerOperation.nip04Encrypt(peerPubkeyHex: "aa", plaintext: "").eventKind)
        XCTAssertNil(SignerOperation.nip04Decrypt(peerPubkeyHex: "aa", ciphertext: "").eventKind)
    }

    // MARK: - peerPubkeyHex

    func testSignPeerPubkeyHexIsNil() {
        let op = SignerOperation.sign(sampleEvent)
        XCTAssertNil(op.peerPubkeyHex)
    }

    func testCryptoOpsPeerPubkeyHex() {
        let pk = "deadbeef"
        XCTAssertEqual(SignerOperation.nip44Encrypt(peerPubkeyHex: pk, plaintext: "").peerPubkeyHex, pk)
        XCTAssertEqual(SignerOperation.nip44Decrypt(peerPubkeyHex: pk, ciphertext: "").peerPubkeyHex, pk)
        XCTAssertEqual(SignerOperation.nip04Encrypt(peerPubkeyHex: pk, plaintext: "").peerPubkeyHex, pk)
        XCTAssertEqual(SignerOperation.nip04Decrypt(peerPubkeyHex: pk, ciphertext: "").peerPubkeyHex, pk)
    }

    // MARK: - Equatable

    func testSignEquality() {
        let a = SignerOperation.sign(sampleEvent)
        let b = SignerOperation.sign(sampleEvent)
        XCTAssertEqual(a, b)
    }

    func testSignInequalityDifferentEvent() {
        let other = NostrEvent(kind: 2, pubkey: "bb", created_at: 2000, tags: [], content: "bye")
        XCTAssertNotEqual(
            SignerOperation.sign(sampleEvent),
            SignerOperation.sign(other)
        )
    }

    func testCryptoOpEquality() {
        XCTAssertEqual(
            SignerOperation.nip44Encrypt(peerPubkeyHex: "aa", plaintext: "hi"),
            SignerOperation.nip44Encrypt(peerPubkeyHex: "aa", plaintext: "hi")
        )
    }

    func testCryptoOpInequalityDifferentPlaintext() {
        XCTAssertNotEqual(
            SignerOperation.nip44Encrypt(peerPubkeyHex: "aa", plaintext: "hi"),
            SignerOperation.nip44Encrypt(peerPubkeyHex: "aa", plaintext: "bye")
        )
    }

    func testDifferentOperationTypesNotEqual() {
        XCTAssertNotEqual(
            SignerOperation.nip44Encrypt(peerPubkeyHex: "aa", plaintext: "hi"),
            SignerOperation.nip04Encrypt(peerPubkeyHex: "aa", plaintext: "hi")
        )
    }
}

// MARK: - IdentitySelection Tests

final class IdentitySelectionTests: XCTestCase {

    func testActiveEquality() {
        XCTAssertEqual(IdentitySelection.active, .active)
    }

    func testSpecificEquality() {
        let id = UUID()
        XCTAssertEqual(IdentitySelection.specific(id), .specific(id))
    }

    func testSpecificInequalityDifferentUUID() {
        XCTAssertNotEqual(
            IdentitySelection.specific(UUID()),
            IdentitySelection.specific(UUID())
        )
    }

    func testActiveNotEqualToSpecific() {
        XCTAssertNotEqual(
            IdentitySelection.active,
            IdentitySelection.specific(UUID())
        )
    }
}

// MARK: - OperationOutput Tests

final class OperationOutputTests: XCTestCase {

    func testSignatureEquality() {
        let resp = SignatureResponse(id: "abc", sig: "def", pubkey: "ghi")
        XCTAssertEqual(
            OperationOutput.signature(resp),
            OperationOutput.signature(resp)
        )
    }

    func testCiphertextEquality() {
        XCTAssertEqual(
            OperationOutput.ciphertext("enc123"),
            OperationOutput.ciphertext("enc123")
        )
    }

    func testPlaintextEquality() {
        XCTAssertEqual(
            OperationOutput.plaintext("hello"),
            OperationOutput.plaintext("hello")
        )
    }

    func testDifferentOutputTypesNotEqual() {
        XCTAssertNotEqual(
            OperationOutput.ciphertext("data"),
            OperationOutput.plaintext("data")
        )
    }

    func testSignatureNotEqualToCiphertext() {
        let resp = SignatureResponse(id: "a", sig: "b", pubkey: "c")
        XCTAssertNotEqual(
            OperationOutput.signature(resp),
            OperationOutput.ciphertext("a")
        )
    }
}

// MARK: - OperationPipelineError Tests

final class OperationPipelineErrorTests: XCTestCase {

    func testNoActiveIdentityEquality() {
        XCTAssertEqual(
            OperationPipelineError.noActiveIdentity,
            OperationPipelineError.noActiveIdentity
        )
    }

    func testInvalidPeerPublicKeyEquality() {
        XCTAssertEqual(
            OperationPipelineError.invalidPeerPublicKey("short"),
            OperationPipelineError.invalidPeerPublicKey("short")
        )
    }

    func testInvalidPeerPublicKeyInequality() {
        XCTAssertNotEqual(
            OperationPipelineError.invalidPeerPublicKey("aa"),
            OperationPipelineError.invalidPeerPublicKey("bb")
        )
    }

    func testEventPubkeyMismatchEquality() {
        XCTAssertEqual(
            OperationPipelineError.eventPubkeyMismatch(expected: "aa", provided: "bb"),
            OperationPipelineError.eventPubkeyMismatch(expected: "aa", provided: "bb")
        )
    }

    func testEventPubkeyMismatchInequality() {
        XCTAssertNotEqual(
            OperationPipelineError.eventPubkeyMismatch(expected: "aa", provided: "bb"),
            OperationPipelineError.eventPubkeyMismatch(expected: "aa", provided: "cc")
        )
    }

    func testUnsupportedOperationEquality() {
        XCTAssertEqual(
            OperationPipelineError.unsupportedOperation(.nip44Encrypt),
            OperationPipelineError.unsupportedOperation(.nip44Encrypt)
        )
    }

    func testUnsupportedOperationInequality() {
        XCTAssertNotEqual(
            OperationPipelineError.unsupportedOperation(.nip44Encrypt),
            OperationPipelineError.unsupportedOperation(.nip04Decrypt)
        )
    }

    func testDifferentErrorCasesNotEqual() {
        XCTAssertNotEqual(
            OperationPipelineError.noActiveIdentity as OperationPipelineError,
            OperationPipelineError.unsupportedOperation(.sign)
        )
    }
}

// MARK: - ClientContext Tests

final class ClientContextTests: XCTestCase {

    func testInitDefaults() {
        let ctx = ClientContext(channel: .xpc, clientID: "com.test.app")
        XCTAssertEqual(ctx.channel, .xpc)
        XCTAssertEqual(ctx.clientID, "com.test.app")
        XCTAssertNil(ctx.webOrigin)
        XCTAssertNil(ctx.bundleID)
        XCTAssertNil(ctx.displayName)
        XCTAssertEqual(ctx.approvalPreference, .inheritPolicy)
    }

    func testInitWithAllFields() {
        let ctx = ClientContext(
            channel: .safariWebExtension,
            clientID: "example.com",
            webOrigin: "https://example.com",
            bundleID: nil,
            displayName: "Example App",
            approvalPreference: .perRequest
        )
        XCTAssertEqual(ctx.channel, .safariWebExtension)
        XCTAssertEqual(ctx.clientID, "example.com")
        XCTAssertEqual(ctx.webOrigin, "https://example.com")
        XCTAssertNil(ctx.bundleID)
        XCTAssertEqual(ctx.displayName, "Example App")
        XCTAssertEqual(ctx.approvalPreference, .perRequest)
    }

    func testEquality() {
        let a = ClientContext(channel: .xpc, clientID: "com.test", approvalPreference: .session)
        let b = ClientContext(channel: .xpc, clientID: "com.test", approvalPreference: .session)
        XCTAssertEqual(a, b)
    }

    func testInequalityDifferentChannel() {
        let a = ClientContext(channel: .xpc, clientID: "com.test")
        let b = ClientContext(channel: .nip46, clientID: "com.test")
        XCTAssertNotEqual(a, b)
    }

    func testInequalityDifferentClientID() {
        let a = ClientContext(channel: .xpc, clientID: "com.test1")
        let b = ClientContext(channel: .xpc, clientID: "com.test2")
        XCTAssertNotEqual(a, b)
    }

    func testInequalityDifferentApproval() {
        let a = ClientContext(channel: .xpc, clientID: "com.test", approvalPreference: .perRequest)
        let b = ClientContext(channel: .xpc, clientID: "com.test", approvalPreference: .session)
        XCTAssertNotEqual(a, b)
    }
}

// MARK: - Channel Tests

final class ChannelTests: XCTestCase {

    func testAllCases() {
        let cases = Channel.allCases
        XCTAssertEqual(cases.count, 8)
    }

    func testRawValues() {
        XCTAssertEqual(Channel.universalLink.rawValue, "universalLink")
        XCTAssertEqual(Channel.urlScheme.rawValue, "urlScheme")
        XCTAssertEqual(Channel.xpc.rawValue, "xpc")
        XCTAssertEqual(Channel.appIntent.rawValue, "appIntent")
        XCTAssertEqual(Channel.actionExtension.rawValue, "actionExtension")
        XCTAssertEqual(Channel.safariWebExtension.rawValue, "safariWebExtension")
        XCTAssertEqual(Channel.safariAppExtension.rawValue, "safariAppExtension")
        XCTAssertEqual(Channel.nip46.rawValue, "nip46")
    }

    func testCodableRoundTrip() throws {
        for ch in Channel.allCases {
            let data = try JSONEncoder().encode(ch)
            let decoded = try JSONDecoder().decode(Channel.self, from: data)
            XCTAssertEqual(ch, decoded)
        }
    }
}

// MARK: - ApprovalPreference Tests

final class ApprovalPreferenceTests: XCTestCase {

    func testRawValues() {
        XCTAssertEqual(ApprovalPreference.inheritPolicy.rawValue, "inheritPolicy")
        XCTAssertEqual(ApprovalPreference.perRequest.rawValue, "perRequest")
        XCTAssertEqual(ApprovalPreference.session.rawValue, "session")
    }

    func testCodableRoundTrip() throws {
        for pref in [ApprovalPreference.inheritPolicy, .perRequest, .session] {
            let data = try JSONEncoder().encode(pref)
            let decoded = try JSONDecoder().decode(ApprovalPreference.self, from: data)
            XCTAssertEqual(pref, decoded)
        }
    }
}

// MARK: - OperationPipeline Protocol Conformance Test

/// A mock pipeline that records calls for testing.
private final class MockPipeline: OperationPipeline {
    var lastOperation: SignerOperation?
    var lastIdentity: IdentitySelection?
    var lastClient: ClientContext?
    var resultToReturn: OperationOutput?
    var errorToThrow: Error?

    func execute(
        operation: SignerOperation,
        identity: IdentitySelection,
        client: ClientContext
    ) throws -> OperationOutput {
        lastOperation = operation
        lastIdentity = identity
        lastClient = client
        if let error = errorToThrow { throw error }
        return resultToReturn!
    }
}

final class OperationPipelineProtocolTests: XCTestCase {

    func testMockPipelineRecordsCalls() throws {
        let pipeline = MockPipeline()
        let event = NostrEvent(kind: 1, pubkey: "aa", created_at: 100, tags: [], content: "test")
        let client = ClientContext(channel: .universalLink, clientID: "test.com", approvalPreference: .perRequest)
        let expectedResp = SignatureResponse(id: "id", sig: "sig", pubkey: "pk")
        pipeline.resultToReturn = .signature(expectedResp)

        let output = try pipeline.execute(
            operation: .sign(event),
            identity: .active,
            client: client
        )

        XCTAssertEqual(pipeline.lastOperation, .sign(event))
        XCTAssertEqual(pipeline.lastIdentity, .active)
        XCTAssertEqual(pipeline.lastClient, client)
        XCTAssertEqual(output, .signature(expectedResp))
    }

    func testMockPipelineThrowsError() {
        let pipeline = MockPipeline()
        pipeline.errorToThrow = OperationPipelineError.unsupportedOperation(.nip44Encrypt)

        let event = NostrEvent(kind: 1, pubkey: "aa", created_at: 100, tags: [], content: "")
        let client = ClientContext(channel: .xpc, clientID: "com.test")

        XCTAssertThrowsError(try pipeline.execute(
            operation: .sign(event),
            identity: .specific(UUID()),
            client: client
        )) { error in
            XCTAssertEqual(error as? OperationPipelineError, .unsupportedOperation(.nip44Encrypt))
        }
    }

    func testMockPipelineWithSpecificIdentity() throws {
        let pipeline = MockPipeline()
        let id = UUID()
        let expectedResp = SignatureResponse(id: "a", sig: "b", pubkey: "c")
        pipeline.resultToReturn = .signature(expectedResp)

        let event = NostrEvent(kind: 0, pubkey: "cc", created_at: 0, tags: [], content: "{}")
        let client = ClientContext(channel: .nip46, clientID: "relay.example.com")

        _ = try pipeline.execute(operation: .sign(event), identity: .specific(id), client: client)

        XCTAssertEqual(pipeline.lastIdentity, .specific(id))
    }

    func testMockPipelineCryptoOutput() throws {
        let pipeline = MockPipeline()
        pipeline.resultToReturn = .ciphertext("encrypted_data")

        let client = ClientContext(channel: .safariWebExtension, clientID: "app.example.com")
        let output = try pipeline.execute(
            operation: .nip44Encrypt(peerPubkeyHex: "deadbeef", plaintext: "secret"),
            identity: .active,
            client: client
        )

        XCTAssertEqual(output, .ciphertext("encrypted_data"))
        XCTAssertEqual(pipeline.lastOperation?.kind, .nip44Encrypt)
    }
}

// MARK: - NostrEvent Sendable Conformance Test

final class NostrEventSendableTests: XCTestCase {

    func testNostrEventIsSendable() {
        // Compile-time check: NostrEvent can be used in a Sendable context.
        let event = NostrEvent(kind: 1, pubkey: "aa", created_at: 100, tags: [], content: "hi")
        let op = SignerOperation.sign(event)
        // If NostrEvent weren't Sendable, SignerOperation couldn't be Sendable,
        // and this wouldn't compile.
        XCTAssertEqual(op.kind, .sign)
    }
}

// MARK: - SignatureResponse Sendable Conformance Test

final class SignatureResponseSendableTests: XCTestCase {

    func testSignatureResponseIsSendable() {
        // Compile-time check: SignatureResponse can be used in a Sendable context.
        let resp = SignatureResponse(id: "a", sig: "b", pubkey: "c")
        let output = OperationOutput.signature(resp)
        // If SignatureResponse weren't Sendable, OperationOutput couldn't be Sendable.
        XCTAssertEqual(output, .signature(resp))
    }
}
