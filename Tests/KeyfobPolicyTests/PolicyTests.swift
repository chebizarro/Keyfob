import XCTest
@testable import KeyfobPolicy

final class PolicyTests: XCTestCase {
    func testPreflightNoThrow() throws {
        // preflight does rate-limiting and lazy origin loading; should not throw for fresh origin
        let engine = PolicyEngine.shared
        let origin = "preflight.test.\(UUID().uuidString)"
        XCTAssertNoThrow(try engine.preflight(origin: origin))
    }

    class MockConsent: PolicyEngine.ConsentProvider {
        var approveAll = true
        var callCount = 0
        func requestConsent(origin: String, eventPreview: String, mode: PolicyEngine.ConsentMode) throws {
            callCount += 1
            if !approveAll {
                throw NSError(domain: "MockConsent", code: 1, userInfo: [NSLocalizedDescriptionKey: "Denied by mock"])
            }
        }
    }

    func testConsentRequiresProvider() throws {
        // When no consentProvider is set, requestConsent must throw (not silently approve)
        let engine = PolicyEngine.shared
        let savedProvider = engine.consentProvider
        engine.consentProvider = nil
        defer { engine.consentProvider = savedProvider }

        let origin = "no.provider.test.\(UUID().uuidString)"
        XCTAssertThrowsError(try engine.requestConsent(origin: origin, eventPreview: "{}", mode: .perRequest)) { error in
            let nsErr = error as NSError
            XCTAssertEqual(nsErr.code, -2, "Expected 'no provider' error code")
        }
    }

    func testConsentDenialPropagates() throws {
        let engine = PolicyEngine.shared
        let mock = MockConsent()
        mock.approveAll = false
        engine.consentProvider = mock
        defer { engine.consentProvider = nil }

        let origin = "denial.test.\(UUID().uuidString)"
        XCTAssertThrowsError(try engine.requestConsent(origin: origin, eventPreview: "{}", mode: .perRequest))
        XCTAssertEqual(mock.callCount, 1)
    }

    func testAllowlistAndSession() throws {
        let engine = PolicyEngine.shared
        let keeper = MockConsent()
        engine.consentProvider = keeper
        defer { engine.consentProvider = nil }

        let origin = "unit.test.origin.\(UUID().uuidString)"
        // Allow this origin for 60s and default to session mode
        engine.allow(origin: origin, duration: 60, defaultMode: .session)
        // Should not throw consent for session mode (session auto-approve)
        XCTAssertNoThrow(try engine.requestConsent(origin: origin, eventPreview: "{}", mode: .session))
        // Start an explicit session and validate
        engine.startSession(origin: origin, pubkey: "pkhex", ttl: 2)
        XCTAssertTrue(engine.hasValidSession(origin: origin, pubkey: "pkhex"))
    }

    func testSessionExpiry() throws {
        let engine = PolicyEngine.shared
        let origin = "expiry.test.\(UUID().uuidString)"
        // Start a session with very short TTL
        engine.startSession(origin: origin, pubkey: "pk", ttl: 0.01)
        // Should be valid immediately
        XCTAssertTrue(engine.hasValidSession(origin: origin, pubkey: "pk"))
        // Wait for expiry
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertFalse(engine.hasValidSession(origin: origin, pubkey: "pk"))
    }

    func testCallerAllowlist() throws {
        let engine = PolicyEngine.shared
        let bundleID = "test.caller.\(UUID().uuidString)"

        XCTAssertFalse(engine.isCallerAllowed(bundleID))
        engine.allowCaller(bundleID)
        XCTAssertTrue(engine.isCallerAllowed(bundleID))
        XCTAssertTrue(engine.listAllowedCallers().contains(bundleID))

        engine.removeCaller(bundleID)
        XCTAssertFalse(engine.isCallerAllowed(bundleID))
    }

    func testRateLimiter() throws {
        let engine = PolicyEngine.shared
        let keeper = MockConsent()
        engine.consentProvider = keeper
        defer { engine.consentProvider = nil }

        let origin = "rate.limit.origin.\(UUID().uuidString)"
        var threw = false
        // Exceed token bucket capacity (10) in a short burst
        for _ in 0..<12 {
            do { try engine.preflight(origin: origin) } catch { threw = true; break }
        }
        XCTAssertTrue(threw, "Expected rate limit to trigger")
    }

    func testDenyOrigin() throws {
        let engine = PolicyEngine.shared
        let mock = MockConsent()
        engine.consentProvider = mock
        defer { engine.consentProvider = nil }

        let origin = "deny.test.\(UUID().uuidString)"
        engine.deny(origin: origin)
        // Denied origins still go through consent (deny just records status)
        // The consent provider decides
        mock.approveAll = true
        XCTAssertNoThrow(try engine.requestConsent(origin: origin, eventPreview: "{}", mode: .perRequest))
    }

    // MARK: - Concurrent Access

    func testConcurrentPreflightDoesNotCrash() throws {
        // Hammer preflight from many threads simultaneously to verify thread safety
        let engine = PolicyEngine.shared
        let group = DispatchGroup()
        let iterations = 100

        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                let origin = "concurrent.preflight.\(i).\(UUID().uuidString)"
                // Should not crash even under concurrent access
                _ = try? engine.preflight(origin: origin)
            }
        }
        let result = group.wait(timeout: .now() + 5)
        XCTAssertEqual(result, .success, "Concurrent preflight timed out")
    }

    func testConcurrentCallerAllowlistDoesNotCrash() throws {
        let engine = PolicyEngine.shared
        let group = DispatchGroup()
        let iterations = 50

        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                let bundleID = "concurrent.caller.\(i).\(UUID().uuidString)"
                engine.allowCaller(bundleID)
                _ = engine.isCallerAllowed(bundleID)
                _ = engine.listAllowedCallers()
                engine.removeCaller(bundleID)
            }
        }
        let result = group.wait(timeout: .now() + 5)
        XCTAssertEqual(result, .success, "Concurrent allowlist ops timed out")
    }

    func testConcurrentSessionOpsDoNotCrash() throws {
        let engine = PolicyEngine.shared
        let group = DispatchGroup()
        let iterations = 50

        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                let origin = "concurrent.session.\(i)"
                let pubkey = "pk.\(i)"
                engine.startSession(origin: origin, pubkey: pubkey, ttl: 1)
                _ = engine.hasValidSession(origin: origin, pubkey: pubkey)
            }
        }
        let result = group.wait(timeout: .now() + 5)
        XCTAssertEqual(result, .success, "Concurrent session ops timed out")
    }

    func testConcurrentAllowAndRecordDoNotCrash() throws {
        let engine = PolicyEngine.shared
        let mock = MockConsent()
        engine.consentProvider = mock
        defer { engine.consentProvider = nil }

        let group = DispatchGroup()
        let iterations = 50

        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                let origin = "concurrent.allow.\(i).\(UUID().uuidString)"
                engine.allow(origin: origin, duration: 10)
                engine.recordSuccess(origin: origin)
                engine.deny(origin: origin)
            }
        }
        let result = group.wait(timeout: .now() + 5)
        XCTAssertEqual(result, .success, "Concurrent allow/record/deny ops timed out")
    }

    // MARK: - Session mode vs perRequest mode

    func testPerRequestModeAlwaysConsults() throws {
        let engine = PolicyEngine.shared
        let mock = MockConsent()
        engine.consentProvider = mock
        defer { engine.consentProvider = nil }

        let origin = "perreq.test.\(UUID().uuidString)"
        // Allow origin with session mode
        engine.allow(origin: origin, duration: 60, defaultMode: .session)
        // perRequest mode should NOT auto-approve even if origin is allowed
        mock.callCount = 0
        XCTAssertNoThrow(try engine.requestConsent(origin: origin, eventPreview: "{}", mode: .perRequest))
        XCTAssertEqual(mock.callCount, 1, "perRequest should always consult provider")
    }

    func testSessionModeAutoApprovesWhenAllowed() throws {
        let engine = PolicyEngine.shared
        let mock = MockConsent()
        engine.consentProvider = mock
        defer { engine.consentProvider = nil }

        let origin = "session.auto.\(UUID().uuidString)"
        engine.allow(origin: origin, duration: 60, defaultMode: .session)
        mock.callCount = 0
        XCTAssertNoThrow(try engine.requestConsent(origin: origin, eventPreview: "{}", mode: .session))
        XCTAssertEqual(mock.callCount, 0, "session mode with allowed origin should auto-approve")
    }
}
