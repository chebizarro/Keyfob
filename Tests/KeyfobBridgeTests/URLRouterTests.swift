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

    func testCallbackURLError() throws {
        let cb = URL(string: "https://example.com/cb")!
        let u = URLRouter.makeCallbackURL(cb: cb, result: .init(error: "rate_limited", msg: "Too fast"))
        XCTAssertNotNil(u)
        let comps = URLComponents(url: u!, resolvingAgainstBaseURL: false)
        let q = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["ok"], "0")
        XCTAssertEqual(q["code"], "rate_limited")
        XCTAssertEqual(q["msg"], "Too fast")
    }

    func testRejectsInvalidScheme() {
        XCTAssertThrowsError(try URLRouter.parse(URL(string: "keyfob://badhost")!))
        XCTAssertThrowsError(try URLRouter.parse(URL(string: "https://keyfob.example.com/app/sign")!))
    }

    func testRejectsInvalidUniversalLinkPath() {
        let url = URL(string: "https://\(URLRouter.ulHost)/app/unknown?cb=https://x.com&origin=test")!
        XCTAssertThrowsError(try URLRouter.parseUniversalLink(url))
    }

    func testRejectsOversizedPayload() throws {
        // Create payload larger than maxPayload (16KB)
        let bigContent = String(repeating: "x", count: 20_000)
        let evt = NostrEvent(kind: 1, pubkey: "", created_at: 0, tags: [], content: bigContent, id: nil, sig: nil)
        let json = try JSONEncoder().encode(evt)
        let b64 = json.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let url = URL(string: "https://\(URLRouter.ulHost)/app/sign?payload=\(b64)&cb=https://x.com&origin=test")!
        XCTAssertThrowsError(try URLRouter.parseUniversalLink(url)) { error in
            XCTAssertTrue(error is URLRouterError)
        }
    }

    func testBase64URLDecoding() throws {
        // Verify standard base64 with +/= is handled via URL-safe substitution
        let evt = NostrEvent(kind: 1, pubkey: "aabb", created_at: 0, tags: [], content: "test", id: nil, sig: nil)
        let json = try JSONEncoder().encode(evt)
        let b64url = json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let url = URL(string: "keyfob://sign?payload=\(b64url)&cb=https://x.com&origin=test")!
        let parsed = try URLRouter.parse(url)
        XCTAssertEqual(parsed.event.content, "test")
    }
}
