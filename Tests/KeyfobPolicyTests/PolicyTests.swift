import XCTest
@testable import KeyfobPolicy

final class PolicyTests: XCTestCase {
    func testPreflightNoThrow() throws {
        // For now, preflight is a no-op
        XCTAssertNoThrow(try PolicyEngine.shared.preflight(origin: "test"))
    }

    class MockConsent: PolicyEngine.ConsentProvider {
        func requestConsent(origin: String, eventPreview: String, mode: PolicyEngine.ConsentMode) throws {
            // Always approve
        }
    }

    func testAllowlistAndSession() throws {
        let engine = PolicyEngine.shared
        let keeper = MockConsent()
        engine.consentProvider = keeper
        let origin = "unit.test.origin.\(UUID().uuidString)"
        // Allow this origin for 60s and default to session mode
        engine.allow(origin: origin, duration: 60, defaultMode: .session)
        // Should not throw consent for session mode
        XCTAssertNoThrow(try engine.requestConsent(origin: origin, eventPreview: "{}", mode: .session))
        // Start an explicit session and validate
        engine.startSession(origin: origin, pubkey: "pkhex", ttl: 2)
        XCTAssertTrue(engine.hasValidSession(origin: origin, pubkey: "pkhex"))
    }

    func testRateLimiter() throws {
        let engine = PolicyEngine.shared
        let keeper = MockConsent()
        engine.consentProvider = keeper
        let origin = "rate.limit.origin.\(UUID().uuidString)"
        var threw = false
        // Exceed token bucket capacity (10) in a short burst
        for _ in 0..<12 {
            do { try engine.preflight(origin: origin) } catch { threw = true; break }
        }
        XCTAssertTrue(threw, "Expected rate limit to trigger")
    }
}
