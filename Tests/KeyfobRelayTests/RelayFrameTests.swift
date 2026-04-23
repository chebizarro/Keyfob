// ──────────────────────────────────────────────────────────────────
// RelayFrameTests.swift — Tests for Nostr relay frame parsing/serialization
// ──────────────────────────────────────────────────────────────────

import XCTest
@testable import KeyfobRelay

// MARK: - Test Fixtures

private let sampleEvent = RelayEvent(
    id: "abc123",
    pubkey: "deadbeef",
    created_at: 1700000000,
    kind: 1,
    tags: [["e", "ref1"], ["p", "ref2"]],
    content: "Hello Nostr",
    sig: "sig123"
)

private func sampleEventJSON() -> String {
    // Sorted keys to match encoder output
    return """
    {"content":"Hello Nostr","created_at":1700000000,"id":"abc123","kind":1,"pubkey":"deadbeef","sig":"sig123","tags":[["e","ref1"],["p","ref2"]]}
    """
}

// MARK: - ServerFrame Parsing Tests

final class ServerFrameParseTests: XCTestCase {

    func testParseEVENT() throws {
        let json = """
        ["EVENT","sub1",{"id":"abc123","pubkey":"deadbeef","created_at":1700000000,"kind":1,"tags":[["e","ref1"],["p","ref2"]],"content":"Hello Nostr","sig":"sig123"}]
        """
        let frame = try ServerFrame.parse(json)
        guard case .event(let subId, let event) = frame else {
            XCTFail("Expected EVENT frame"); return
        }
        XCTAssertEqual(subId, "sub1")
        XCTAssertEqual(event.id, "abc123")
        XCTAssertEqual(event.pubkey, "deadbeef")
        XCTAssertEqual(event.created_at, 1700000000)
        XCTAssertEqual(event.kind, 1)
        XCTAssertEqual(event.tags, [["e", "ref1"], ["p", "ref2"]])
        XCTAssertEqual(event.content, "Hello Nostr")
        XCTAssertEqual(event.sig, "sig123")
    }

    func testParseOK_accepted() throws {
        let json = #"["OK","evt1",true,""]"#
        let frame = try ServerFrame.parse(json)
        guard case .ok(let eventId, let accepted, let message) = frame else {
            XCTFail("Expected OK frame"); return
        }
        XCTAssertEqual(eventId, "evt1")
        XCTAssertTrue(accepted)
        XCTAssertEqual(message, "")
    }

    func testParseOK_rejected() throws {
        let json = #"["OK","evt2",false,"duplicate: already have this event"]"#
        let frame = try ServerFrame.parse(json)
        guard case .ok(let eventId, let accepted, let message) = frame else {
            XCTFail("Expected OK frame"); return
        }
        XCTAssertEqual(eventId, "evt2")
        XCTAssertFalse(accepted)
        XCTAssertEqual(message, "duplicate: already have this event")
    }

    func testParseEOSE() throws {
        let json = #"["EOSE","sub42"]"#
        let frame = try ServerFrame.parse(json)
        guard case .eose(let subId) = frame else {
            XCTFail("Expected EOSE frame"); return
        }
        XCTAssertEqual(subId, "sub42")
    }

    func testParseCLOSED() throws {
        let json = #"["CLOSED","sub1","auth-required: please authenticate"]"#
        let frame = try ServerFrame.parse(json)
        guard case .closed(let subId, let message) = frame else {
            XCTFail("Expected CLOSED frame"); return
        }
        XCTAssertEqual(subId, "sub1")
        XCTAssertEqual(message, "auth-required: please authenticate")
    }

    func testParseNOTICE() throws {
        let json = #"["NOTICE","rate limited"]"#
        let frame = try ServerFrame.parse(json)
        guard case .notice(let message) = frame else {
            XCTFail("Expected NOTICE frame"); return
        }
        XCTAssertEqual(message, "rate limited")
    }

    func testParseAUTH() throws {
        let json = #"["AUTH","challenge-string-123"]"#
        let frame = try ServerFrame.parse(json)
        guard case .auth(let challenge) = frame else {
            XCTFail("Expected AUTH frame"); return
        }
        XCTAssertEqual(challenge, "challenge-string-123")
    }

    func testParseInvalidJSON() {
        // JSONSerialization throws its own error for unparseable input;
        // verify that parse propagates an error (not necessarily our custom type)
        XCTAssertThrowsError(try ServerFrame.parse("<<<not json>>>"))
    }

    func testParseNonArrayJSON() {
        XCTAssertThrowsError(try ServerFrame.parse(#"{"type":"EVENT"}"#)) { error in
            XCTAssertEqual(error as? RelayFrameError, .invalidStructure)
        }
    }

    func testParseUnknownFrame() {
        XCTAssertThrowsError(try ServerFrame.parse(#"["UNKNOWN","data"]"#)) { error in
            XCTAssertEqual(error as? RelayFrameError, .unknownFrame("UNKNOWN"))
        }
    }

    func testParseEmptyArray() {
        XCTAssertThrowsError(try ServerFrame.parse("[]")) { error in
            XCTAssertEqual(error as? RelayFrameError, .invalidStructure)
        }
    }

    func testParseEVENT_missingFields() {
        // Missing subscription ID
        XCTAssertThrowsError(try ServerFrame.parse(#"["EVENT"]"#)) { error in
            XCTAssertEqual(error as? RelayFrameError, .invalidStructure)
        }
    }
}

// MARK: - ClientFrame Serialization Tests

final class ClientFrameSerializeTests: XCTestCase {

    func testSerializeEVENT() throws {
        let frame = ClientFrame.event(sampleEvent)
        let json = try frame.serialize()
        // Parse back and verify structure
        let data = json.data(using: .utf8)!
        let array = try JSONSerialization.jsonObject(with: data) as! [Any]
        XCTAssertEqual(array[0] as? String, "EVENT")
        let eventDict = array[1] as! [String: Any]
        XCTAssertEqual(eventDict["id"] as? String, "abc123")
        XCTAssertEqual(eventDict["kind"] as? Int, 1)
    }

    func testSerializeREQ() throws {
        let filter = NostrFilter(kinds: [1], limit: 10)
        let frame = ClientFrame.req(subscriptionId: "sub1", filters: [filter])
        let json = try frame.serialize()
        let data = json.data(using: .utf8)!
        let array = try JSONSerialization.jsonObject(with: data) as! [Any]
        XCTAssertEqual(array[0] as? String, "REQ")
        XCTAssertEqual(array[1] as? String, "sub1")
        let filterDict = array[2] as! [String: Any]
        XCTAssertEqual(filterDict["kinds"] as? [Int], [1])
        XCTAssertEqual(filterDict["limit"] as? Int, 10)
    }

    func testSerializeREQ_multipleFilters() throws {
        let f1 = NostrFilter(kinds: [1])
        let f2 = NostrFilter(authors: ["abc"])
        let frame = ClientFrame.req(subscriptionId: "sub2", filters: [f1, f2])
        let json = try frame.serialize()
        let data = json.data(using: .utf8)!
        let array = try JSONSerialization.jsonObject(with: data) as! [Any]
        XCTAssertEqual(array.count, 4) // REQ, subId, filter1, filter2
    }

    func testSerializeCLOSE() throws {
        let frame = ClientFrame.close(subscriptionId: "sub99")
        let json = try frame.serialize()
        let data = json.data(using: .utf8)!
        let array = try JSONSerialization.jsonObject(with: data) as! [Any]
        XCTAssertEqual(array[0] as? String, "CLOSE")
        XCTAssertEqual(array[1] as? String, "sub99")
        XCTAssertEqual(array.count, 2)
    }

    func testSerializeAUTH() throws {
        let frame = ClientFrame.auth(sampleEvent)
        let json = try frame.serialize()
        let data = json.data(using: .utf8)!
        let array = try JSONSerialization.jsonObject(with: data) as! [Any]
        XCTAssertEqual(array[0] as? String, "AUTH")
        let eventDict = array[1] as! [String: Any]
        XCTAssertEqual(eventDict["id"] as? String, "abc123")
    }
}

// MARK: - NostrFilter Encoding Tests

final class NostrFilterTests: XCTestCase {

    func testEncodeMinimalFilter() throws {
        let filter = NostrFilter()
        let data = try JSONEncoder().encode(filter)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertTrue(dict.isEmpty, "Empty filter should encode to {}")
    }

    func testEncodeKindsAndLimit() throws {
        let filter = NostrFilter(kinds: [1, 4], limit: 50)
        let data = try JSONEncoder().encode(filter)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["kinds"] as? [Int], [1, 4])
        XCTAssertEqual(dict["limit"] as? Int, 50)
        XCTAssertNil(dict["ids"])
        XCTAssertNil(dict["authors"])
    }

    func testEncodeTagFilters() throws {
        let filter = NostrFilter(e: ["event1"], p: ["pubkey1"], t: ["nostr"])
        let data = try JSONEncoder().encode(filter)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["#e"] as? [String], ["event1"])
        XCTAssertEqual(dict["#p"] as? [String], ["pubkey1"])
        XCTAssertEqual(dict["#t"] as? [String], ["nostr"])
    }

    func testEncodeTimeRange() throws {
        let filter = NostrFilter(since: 1700000000, until: 1700001000)
        let data = try JSONEncoder().encode(filter)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["since"] as? Int, 1700000000)
        XCTAssertEqual(dict["until"] as? Int, 1700001000)
    }

    func testDecodeFilter() throws {
        let json = ##"{"kinds":[1],"#e":["abc"],"limit":5}"##
        let data = json.data(using: .utf8)!
        let filter = try JSONDecoder().decode(NostrFilter.self, from: data)
        XCTAssertEqual(filter.kinds, [1])
        XCTAssertEqual(filter.e, ["abc"])
        XCTAssertEqual(filter.limit, 5)
        XCTAssertNil(filter.authors)
    }

    func testRoundTrip() throws {
        let filter = NostrFilter(ids: ["id1"], authors: ["auth1"], kinds: [1, 7],
                                  e: ["e1"], p: ["p1"], t: ["t1"],
                                  since: 100, until: 200, limit: 25)
        let data = try JSONEncoder().encode(filter)
        let decoded = try JSONDecoder().decode(NostrFilter.self, from: data)
        XCTAssertEqual(filter, decoded)
    }
}

// MARK: - RelayEvent Tests

final class RelayEventTests: XCTestCase {

    func testRelayEventEquatable() {
        let e1 = sampleEvent
        let e2 = RelayEvent(id: "abc123", pubkey: "deadbeef", created_at: 1700000000,
                            kind: 1, tags: [["e", "ref1"], ["p", "ref2"]],
                            content: "Hello Nostr", sig: "sig123")
        XCTAssertEqual(e1, e2)
    }

    func testRelayEventCodable() throws {
        let data = try JSONEncoder().encode(sampleEvent)
        let decoded = try JSONDecoder().decode(RelayEvent.self, from: data)
        XCTAssertEqual(sampleEvent, decoded)
    }
}
