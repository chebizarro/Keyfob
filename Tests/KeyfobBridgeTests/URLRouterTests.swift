import XCTest
@testable import KeyfobBridge
@testable import KeyfobCore

final class URLRouterTests: XCTestCase {
    func testParseUniversalLinkSign() throws {
        let evt = NostrEvent(kind: 1, pubkey: "", created_at: 123, tags: [], content: "hello", id: nil, sig: nil)
        let json = try JSONEncoder().encode(evt)
        let b64 = json.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let cb = "https://example.com/callback.html#keyfob-cb-123"
        let url = URL(string: "https://\(URLRouter.ulHost)/app/sign?payload=\(b64)&cb=\(cb.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)&origin=test")!
        let parsed = try URLRouter.parseUniversalLink(url)
        XCTAssertEqual(parsed.mode, "sign")
        XCTAssertEqual(parsed.event?.content, "hello")
        XCTAssertEqual(parsed.origin, "test")
        XCTAssertEqual(parsed.callback.absoluteString, cb)
    }

    func testParseUniversalLinkPubkey() throws {
        let cb = "https://example.com/callback.html#keyfob-cb-123"
        let url = URL(string: "https://\(URLRouter.ulHost)/app/pubkey?cb=\(cb.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)&origin=test")!
        let parsed = try URLRouter.parseUniversalLink(url)
        XCTAssertEqual(parsed.mode, "pubkey")
        XCTAssertNil(parsed.event)
        XCTAssertEqual(parsed.origin, "test")
        XCTAssertEqual(parsed.callback.absoluteString, cb)
    }

    func testCallbackURLSuccess() throws {
        let cb = URL(string: "https://example.com/callback.html#keyfob-cb-xyz")!
        let u = URLRouter.makeCallbackURL(cb: cb, result: .init(success: "idhex", sig: "sighex", pubkey: "pkhex"))
        XCTAssertNotNil(u)
        let comps = URLComponents(url: u!, resolvingAgainstBaseURL: false)
        let q = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["ok"], "1")
        XCTAssertEqual(q["id"], "idhex")
        XCTAssertEqual(q["sig"], "sighex")
        XCTAssertEqual(q["pubkey"], "pkhex")
    }
}
