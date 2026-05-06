import XCTest
@testable import KeyfobBridge
@testable import KeyfobCore

final class BridgeTests: XCTestCase {

    // MARK: - URLRouter.parse (custom scheme)

    func testURLRouterRejectsInvalid() {
        XCTAssertThrowsError(try URLRouter.parse(URL(string: "keyfob://badhost")!))
    }

    func testURLRouterRejectsWrongScheme() {
        XCTAssertThrowsError(try URLRouter.parse(URL(string: "https://sign")!))
    }

    func testURLRouterParseCustomSchemeHappyPath() throws {
        let evt = NostrEvent(kind: 1, pubkey: "pk", created_at: 100, tags: [], content: "test", id: nil, sig: nil)
        let json = try JSONEncoder().encode(evt)
        let b64 = json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let cb = "myapp://callback"
        let origin = "com.test.app"
        let url = URL(string: "keyfob://sign?payload=\(b64)&cb=\(cb)&origin=\(origin)")!
        let parsed = try URLRouter.parse(url)
        XCTAssertEqual(parsed.event.kind, 1)
        XCTAssertEqual(parsed.event.content, "test")
        XCTAssertEqual(parsed.callback.absoluteString, cb)
        XCTAssertEqual(parsed.origin, origin)
    }

    func testURLRouterParsePreservesEventFields() throws {
        let evt = NostrEvent(
            kind: 42,
            pubkey: "aabb",
            created_at: 1700000000,
            tags: [["p", "xyz"]],
            content: "complex \"content\"\nwith newlines",
            id: nil,
            sig: nil
        )
        let json = try JSONEncoder().encode(evt)
        let b64 = json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let url = URL(string: "keyfob://sign?payload=\(b64)&cb=myapp://done&origin=test")!
        let parsed = try URLRouter.parse(url)
        XCTAssertEqual(parsed.event.kind, 42)
        XCTAssertEqual(parsed.event.pubkey, "aabb")
        XCTAssertEqual(parsed.event.created_at, 1700000000)
        XCTAssertEqual(parsed.event.tags, [["p", "xyz"]])
        XCTAssertTrue(parsed.event.content.contains("newlines"))
    }

    func testURLRouterRejectsMissingCallback() {
        // No cb parameter
        let url = URL(string: "keyfob://sign?payload=e30&origin=test")!
        XCTAssertThrowsError(try URLRouter.parse(url))
    }

    func testURLRouterRejectsEmptyPayload() {
        let url = URL(string: "keyfob://sign?payload=&cb=myapp://done&origin=test")!
        XCTAssertThrowsError(try URLRouter.parse(url))
    }

    // MARK: - BridgeHandler

    func testBridgeHandlerRejectsNonUniversalLink() {
        // A non-HTTPS URL should fail parsing, but BridgeHandler still returns
        // an error callback URL if a cb parameter is present
        let url = URL(string: "http://other.com/app/sign?cb=https://x.com&origin=t")!
        let result = BridgeHandler.handleUniversalLink(url)
        // Result is an error callback URL, not nil (because cb was extractable)
        if let result = result {
            let comps = URLComponents(url: result, resolvingAgainstBaseURL: false)
            let q = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(q["ok"], "0", "Should be an error callback")
        }
    }

    func testBridgeHandlerRejectsWrongHost() {
        let url = URL(string: "https://wrong.host.com/app/pubkey?cb=https://x.com&origin=t")!
        let result = BridgeHandler.handleUniversalLink(url)
        if let result = result {
            let comps = URLComponents(url: result, resolvingAgainstBaseURL: false)
            let q = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(q["ok"], "0", "Should be an error callback")
        }
    }

    func testBridgeHandlerReturnsNilWithoutCallback() {
        // Without a cb parameter, BridgeHandler should return nil
        let url = URL(string: "https://wrong.host.com/app/sign?origin=test")!
        let result = BridgeHandler.handleUniversalLink(url)
        XCTAssertNil(result)
    }

    // MARK: - CallbackResult

    func testCallbackResultSuccessEncoding() throws {
        let result = URLRouter.CallbackResult(success: "id123", sig: "sig456", pubkey: "pk789")
        XCTAssertEqual(result.ok, 1)
        XCTAssertEqual(result.id, "id123")
        XCTAssertEqual(result.sig, "sig456")
        XCTAssertEqual(result.pubkey, "pk789")
        XCTAssertNil(result.code)
        XCTAssertNil(result.msg)
    }

    func testCallbackResultErrorEncoding() throws {
        let result = URLRouter.CallbackResult(error: "rate_limit", msg: "Too fast")
        XCTAssertEqual(result.ok, 0)
        XCTAssertNil(result.id)
        XCTAssertNil(result.sig)
        XCTAssertNil(result.pubkey)
        XCTAssertEqual(result.code, "rate_limit")
        XCTAssertEqual(result.msg, "Too fast")
    }

    func testCallbackResultCodable() throws {
        let result = URLRouter.CallbackResult(success: "id", sig: "sig", pubkey: "pk")
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(URLRouter.CallbackResult.self, from: data)
        XCTAssertEqual(decoded.ok, result.ok)
        XCTAssertEqual(decoded.id, result.id)
        XCTAssertEqual(decoded.sig, result.sig)
    }

    // MARK: - Round-trip: encode callback URL → parse query params

    func testCallbackURLRoundTrip() throws {
        let cb = URL(string: "https://example.com/done")!
        let result = URLRouter.CallbackResult(success: "abc", sig: "def", pubkey: "ghi")
        let url = URLRouter.makeCallbackURL(cb: cb, result: result)!
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        // All fields present
        XCTAssertEqual(q["ok"], "1")
        XCTAssertEqual(q["id"], "abc")
        XCTAssertEqual(q["sig"], "def")
        XCTAssertEqual(q["pubkey"], "ghi")
        // No error fields
        XCTAssertNil(q["code"])
        XCTAssertNil(q["msg"])
    }
}
