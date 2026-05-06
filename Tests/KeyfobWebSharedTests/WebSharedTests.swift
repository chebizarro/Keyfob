import XCTest
@testable import KeyfobWebShared

final class WebSharedTests: XCTestCase {

    // MARK: - WebMessageName Constants

    func testMessageNameValues() {
        // These must match the JS content scripts exactly
        XCTAssertEqual(WebMessageName.getPublicKey, "keyfob_getPublicKey")
        XCTAssertEqual(WebMessageName.signEvent, "keyfob_signEvent")
        XCTAssertEqual(WebMessageName.response, "keyfob_response")
        XCTAssertEqual(WebMessageName.pubkeyPath, "pubkey")
        XCTAssertEqual(WebMessageName.signPath, "sign")
    }

    func testMessageKeyValues() {
        XCTAssertEqual(WebMessageKey.reqId, "reqId")
        XCTAssertEqual(WebMessageKey.ok, "ok")
        XCTAssertEqual(WebMessageKey.pubkey, "pubkey")
        XCTAssertEqual(WebMessageKey.id, "id")
        XCTAssertEqual(WebMessageKey.sig, "sig")
        XCTAssertEqual(WebMessageKey.msg, "msg")
        XCTAssertEqual(WebMessageKey.eventJSON, "eventJSON")
        XCTAssertEqual(WebMessageKey.origin, "origin")
        XCTAssertEqual(WebMessageKey.callback, "cb")
    }

    func testWebStatusValues() {
        XCTAssertEqual(WebStatus.success, 1)
        XCTAssertEqual(WebStatus.failure, 0)
    }

    // MARK: - WebResponse

    func testPubkeyResponse() {
        let resp = WebResponse.pubkey("aabbccdd")
        XCTAssertEqual(resp.ok, 1)
        XCTAssertEqual(resp.pubkey, "aabbccdd")
        XCTAssertNil(resp.id)
        XCTAssertNil(resp.sig)
        XCTAssertNil(resp.msg)
    }

    func testSignedResponse() {
        let resp = WebResponse.signed(id: "id123", sig: "sig456", pubkey: "pk789")
        XCTAssertEqual(resp.ok, 1)
        XCTAssertEqual(resp.id, "id123")
        XCTAssertEqual(resp.sig, "sig456")
        XCTAssertEqual(resp.pubkey, "pk789")
        XCTAssertNil(resp.msg)
    }

    func testErrorResponse() {
        let resp = WebResponse.error("something went wrong")
        XCTAssertEqual(resp.ok, 0)
        XCTAssertEqual(resp.msg, "something went wrong")
        XCTAssertNil(resp.pubkey)
        XCTAssertNil(resp.id)
        XCTAssertNil(resp.sig)
    }

    func testUserInfoContainsReqId() {
        let resp = WebResponse.pubkey("aabb")
        let info = resp.userInfo(reqId: "req-42")
        XCTAssertEqual(info["reqId"] as? String, "req-42")
        XCTAssertEqual(info["ok"] as? Int, 1)
        XCTAssertEqual(info["pubkey"] as? String, "aabb")
    }

    func testUserInfoOmitsNilFields() {
        let resp = WebResponse.pubkey("ff00")
        let info = resp.userInfo()
        // id and sig should not be in the dictionary
        XCTAssertNil(info["id"])
        XCTAssertNil(info["sig"])
        XCTAssertNil(info["msg"])
    }

    func testErrorUserInfoIncludesMessage() {
        let resp = WebResponse.error("denied")
        let info = resp.userInfo(reqId: "r1")
        XCTAssertEqual(info["ok"] as? Int, 0)
        XCTAssertEqual(info["msg"] as? String, "denied")
        XCTAssertEqual(info["reqId"] as? String, "r1")
    }

    func testResponseEquality() {
        let a = WebResponse.pubkey("abc")
        let b = WebResponse.pubkey("abc")
        let c = WebResponse.pubkey("def")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - NIP07UnsignedEvent

    func testUnsignedEventInit() {
        let evt = NIP07UnsignedEvent(kind: 1, created_at: 1700000000, tags: [["p", "abc"]], content: "hello")
        XCTAssertEqual(evt.kind, 1)
        XCTAssertEqual(evt.created_at, 1700000000)
        XCTAssertEqual(evt.tags, [["p", "abc"]])
        XCTAssertEqual(evt.content, "hello")
    }

    func testUnsignedEventCodable() throws {
        let evt = NIP07UnsignedEvent(kind: 1, created_at: 1700000000, tags: [], content: "test")
        let data = try JSONEncoder().encode(evt)
        let decoded = try JSONDecoder().decode(NIP07UnsignedEvent.self, from: data)
        XCTAssertEqual(evt, decoded)
    }

    func testUnsignedEventDecodesFromJS() throws {
        // Simulate what content.js sends
        let json = """
        {"kind":1,"created_at":1700000000,"tags":[["e","abc123"]],"content":"gm"}
        """
        let evt = try JSONDecoder().decode(NIP07UnsignedEvent.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(evt.kind, 1)
        XCTAssertEqual(evt.created_at, 1700000000)
        XCTAssertEqual(evt.tags, [["e", "abc123"]])
        XCTAssertEqual(evt.content, "gm")
    }

    // MARK: - NIP07SignedEvent

    func testSignedEventFromUnsigned() {
        let unsigned = NIP07UnsignedEvent(kind: 1, created_at: 1700000000, tags: [], content: "hello")
        let signed = NIP07SignedEvent(unsigned: unsigned, id: "aabb", sig: "ccdd", pubkey: "eeff")

        XCTAssertEqual(signed.id, "aabb")
        XCTAssertEqual(signed.sig, "ccdd")
        XCTAssertEqual(signed.pubkey, "eeff")
        XCTAssertEqual(signed.kind, 1)
        XCTAssertEqual(signed.created_at, 1700000000)
        XCTAssertEqual(signed.content, "hello")
        XCTAssertEqual(signed.tags, [])
    }

    func testSignedEventCodable() throws {
        let unsigned = NIP07UnsignedEvent(kind: 4, created_at: 1700000001, tags: [["p", "pk"]], content: "enc")
        let signed = NIP07SignedEvent(unsigned: unsigned, id: "id1", sig: "sig1", pubkey: "pk1")
        let data = try JSONEncoder().encode(signed)
        let decoded = try JSONDecoder().decode(NIP07SignedEvent.self, from: data)
        XCTAssertEqual(signed, decoded)
    }

    func testSignedEventJSONContainsAllFields() throws {
        let unsigned = NIP07UnsignedEvent(kind: 1, created_at: 1700000000, tags: [], content: "hi")
        let signed = NIP07SignedEvent(unsigned: unsigned, id: "abc", sig: "def", pubkey: "123")
        let data = try JSONEncoder().encode(signed)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // All NIP-07 required fields present
        XCTAssertNotNil(dict["id"])
        XCTAssertNotNil(dict["pubkey"])
        XCTAssertNotNil(dict["sig"])
        XCTAssertNotNil(dict["kind"])
        XCTAssertNotNil(dict["created_at"])
        XCTAssertNotNil(dict["tags"])
        XCTAssertNotNil(dict["content"])
    }

    // MARK: - Edge Cases

    func testUnsignedEventEmptyContent() throws {
        let evt = NIP07UnsignedEvent(kind: 0, created_at: 0, tags: [], content: "")
        let data = try JSONEncoder().encode(evt)
        let decoded = try JSONDecoder().decode(NIP07UnsignedEvent.self, from: data)
        XCTAssertEqual(decoded.content, "")
        XCTAssertEqual(decoded.kind, 0)
    }

    func testUnsignedEventNestedTags() throws {
        let tags: [[String]] = [["p", "abc", "wss://relay.example.com"], ["e", "def", "", "root"]]
        let evt = NIP07UnsignedEvent(kind: 1, created_at: 1700000000, tags: tags, content: "")
        let data = try JSONEncoder().encode(evt)
        let decoded = try JSONDecoder().decode(NIP07UnsignedEvent.self, from: data)
        XCTAssertEqual(decoded.tags[0], ["p", "abc", "wss://relay.example.com"])
        XCTAssertEqual(decoded.tags[1], ["e", "def", "", "root"])
    }

    func testResponseDefaultReqId() {
        let resp = WebResponse.pubkey("aa")
        let info = resp.userInfo() // no reqId argument
        XCTAssertEqual(info["reqId"] as? String, "")
    }
}
