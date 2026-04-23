// ──────────────────────────────────────────────────────────────────
// NIP46Handler.swift — NIP-46 remote signer protocol handler
// ──────────────────────────────────────────────────────────────────

import Foundation

// MARK: - NIP-46 Delegate Protocol

/// Protocol for the host app to handle NIP-46 operations.
///
/// Keeps KeyfobRelay decoupled from KeyfobCrypto and KeyfobCore.
/// The host app implements this to provide encryption, signing,
/// and consent flow integration.
public protocol NIP46Delegate: Sendable {
    /// Decrypt NIP-46 content from a requester's pubkey.
    /// Uses NIP-44 (preferred) or NIP-04 (legacy).
    func decrypt(content: String, fromPubkey: String) async throws -> String

    /// Encrypt NIP-46 response content for a requester's pubkey.
    func encrypt(content: String, forPubkey: String) async throws -> String

    /// Get the signer's public key (hex).
    func getPublicKey() async -> String

    /// Sign a Nostr event (from NIP-46 sign_event request).
    /// The implementation should route through consent and policy.
    /// Returns the signed event as a JSON string.
    func signEvent(eventJSON: String, requesterPubkey: String) async throws -> String

    /// Build and sign a kind 24133 response event.
    /// - Parameters:
    ///   - content: Encrypted response content.
    ///   - recipientPubkey: The #p tag recipient.
    /// - Returns: A signed RelayEvent ready to publish.
    func buildResponseEvent(content: String, recipientPubkey: String) async throws -> RelayEvent
}

// MARK: - NIP-46 Handler

/// Manages the NIP-46 remote signer protocol.
///
/// Subscribes to kind 24133 events, decrypts requests, routes them
/// through the delegate for consent/signing, and publishes responses.
public final class NIP46Handler: @unchecked Sendable {

    // MARK: - Properties

    private let connection: RelayConnection
    private let deduplicator: EventDeduplicator
    private let delegate: NIP46Delegate

    private let lock = NSLock()
    private var _signerPubkey: String
    private var _connectedApps: [String: ConnectedApp] = [:]
    private var _activeSessions: [String: NIP46RequestSession] = [:]
    private var subscriptionHandle: SubscriptionHandle?
    private var timeoutTask: Task<Void, Never>?

    /// Secret token required for `connect` method (from bunker:// URI).
    public var requiredSecret: String?

    /// Request timeout (stale consent, etc.). Default: 5 minutes.
    public var requestTimeout: TimeInterval = 300

    /// Called when a new request session is created.
    public var onRequestReceived: (@Sendable (NIP46RequestSession) -> Void)?

    /// Called when a request session state changes.
    public var onRequestStateChange: (@Sendable (NIP46RequestSession, NIP46RequestState) -> Void)?

    // MARK: - Connected App

    /// A remote app that has completed the `connect` handshake.
    public struct ConnectedApp: Sendable, Equatable {
        public let pubkey: String
        public let connectedAt: Date
    }

    // MARK: - Init

    public init(
        connection: RelayConnection,
        delegate: NIP46Delegate,
        signerPubkey: String,
        deduplicator: EventDeduplicator = EventDeduplicator()
    ) {
        self.connection = connection
        self.delegate = delegate
        self._signerPubkey = signerPubkey
        self.deduplicator = deduplicator
    }

    // MARK: - Lifecycle

    /// Start listening for NIP-46 requests.
    ///
    /// Subscribes to kind 24133 events with #p filter matching the signer's pubkey.
    public func start() throws {
        lock.lock()
        guard subscriptionHandle == nil else {
            lock.unlock()
            return
        }
        let pubkey = _signerPubkey
        lock.unlock()

        var filter = NostrFilter()
        filter.kinds = [24133]
        filter.p = [pubkey]

        let handle = try connection.subscribe(
            filters: [filter],
            callbacks: SubscriptionCallbacks(
                onEvent: { [weak self] event in
                    self?.handleIncomingEvent(event)
                }
            )
        )

        lock.lock()
        subscriptionHandle = handle
        lock.unlock()

        startTimeoutSweep()
    }

    /// Stop listening and clean up.
    public func stop() {
        lock.lock()
        if let handle = subscriptionHandle {
            subscriptionHandle = nil
            lock.unlock()
            try? connection.closeSubscription(handle)
        } else {
            lock.unlock()
        }

        timeoutTask?.cancel()
        timeoutTask = nil
    }

    /// The signer's public key.
    public var signerPubkey: String {
        lock.lock()
        defer { lock.unlock() }
        return _signerPubkey
    }

    /// Currently connected remote apps.
    public var connectedApps: [ConnectedApp] {
        lock.lock()
        defer { lock.unlock() }
        return Array(_connectedApps.values)
    }

    /// Active (in-flight) request sessions.
    public var activeSessions: [NIP46RequestSession] {
        lock.lock()
        defer { lock.unlock() }
        return Array(_activeSessions.values)
    }

    // MARK: - Incoming Event Handling

    private func handleIncomingEvent(_ event: RelayEvent) {
        // Deduplicate
        let check = deduplicator.check(event.id)
        guard check == .new else { return }

        // Process asynchronously
        Task { [weak self] in
            await self?.processRequest(event: event)
        }
    }

    private func processRequest(event: RelayEvent) async {
        let requesterPubkey = event.pubkey

        // Decrypt content
        let decrypted: String
        do {
            decrypted = try await delegate.decrypt(
                content: event.content,
                fromPubkey: requesterPubkey
            )
        } catch {
            deduplicator.markCompleted(event.id)
            return // Can't decrypt → silently drop
        }

        // Parse NIP-46 request
        let request: NIP46Request
        do {
            request = try NIP46Request.parse(decrypted)
        } catch {
            deduplicator.markCompleted(event.id)
            // Send error response if we can parse the id
            if let id = extractId(from: decrypted) {
                await sendErrorResponse(
                    id: id,
                    error: "invalid request: \(error)",
                    toPubkey: requesterPubkey
                )
            }
            return
        }

        // Create session
        let session = NIP46RequestSession(
            request: request,
            requesterPubkey: requesterPubkey,
            eventId: event.id
        )
        session.onStateChange = { [weak self] state in
            self?.onRequestStateChange?(session, state)
        }

        lock.lock()
        _activeSessions[request.id] = session
        lock.unlock()

        onRequestReceived?(session)

        // Route by method
        switch request.method {
        case .ping:
            await handlePing(session: session)
        case .get_public_key:
            await handleGetPublicKey(session: session)
        case .connect:
            await handleConnect(session: session)
        case .sign_event:
            await handleSignEvent(session: session)
        }
    }

    // MARK: - Method Handlers

    private func handlePing(session: NIP46RequestSession) async {
        session.transition(to: .publishing)
        await sendSuccessResponse(
            id: session.request.id,
            result: "pong",
            toPubkey: session.requesterPubkey
        )
        completeSession(session)
    }

    private func handleGetPublicKey(session: NIP46RequestSession) async {
        session.transition(to: .publishing)
        let pubkey = await delegate.getPublicKey()
        await sendSuccessResponse(
            id: session.request.id,
            result: pubkey,
            toPubkey: session.requesterPubkey
        )
        completeSession(session)
    }

    private func handleConnect(session: NIP46RequestSession) async {
        // Validate secret if required
        if let required = requiredSecret {
            let providedSecret = session.request.params.first
            guard providedSecret == required else {
                session.transition(to: .errored("invalid secret"))
                await sendErrorResponse(
                    id: session.request.id,
                    error: "invalid secret",
                    toPubkey: session.requesterPubkey
                )
                cleanupSession(session)
                return
            }
        }

        // Register connected app
        lock.lock()
        _connectedApps[session.requesterPubkey] = ConnectedApp(
            pubkey: session.requesterPubkey,
            connectedAt: Date()
        )
        lock.unlock()

        session.transition(to: .publishing)
        await sendSuccessResponse(
            id: session.request.id,
            result: "ack",
            toPubkey: session.requesterPubkey
        )
        completeSession(session)
    }

    private func handleSignEvent(session: NIP46RequestSession) async {
        guard !session.request.params.isEmpty else {
            session.transition(to: .errored("missing event parameter"))
            await sendErrorResponse(
                id: session.request.id,
                error: "missing event parameter",
                toPubkey: session.requesterPubkey
            )
            cleanupSession(session)
            return
        }

        let eventJSON = session.request.params[0]
        session.transition(to: .awaitingConsent)

        // Delegate handles consent + signing (may block for user approval)
        let signedJSON: String
        do {
            session.transition(to: .signing)
            signedJSON = try await delegate.signEvent(
                eventJSON: eventJSON,
                requesterPubkey: session.requesterPubkey
            )
        } catch {
            session.transition(to: .errored(error.localizedDescription))
            await sendErrorResponse(
                id: session.request.id,
                error: "signing failed: \(error.localizedDescription)",
                toPubkey: session.requesterPubkey
            )
            cleanupSession(session)
            return
        }

        session.transition(to: .publishing)
        await sendSuccessResponse(
            id: session.request.id,
            result: signedJSON,
            toPubkey: session.requesterPubkey
        )
        completeSession(session)
    }

    // MARK: - Response Publishing

    private func sendSuccessResponse(id: String, result: String, toPubkey: String) async {
        let response = NIP46Response.success(id: id, result: result)
        await publishResponse(response, toPubkey: toPubkey)
    }

    private func sendErrorResponse(id: String, error: String, toPubkey: String) async {
        let response = NIP46Response.failure(id: id, error: error)
        await publishResponse(response, toPubkey: toPubkey)
    }

    private func publishResponse(_ response: NIP46Response, toPubkey: String) async {
        do {
            let json = try response.toJSON()
            let encrypted = try await delegate.encrypt(content: json, forPubkey: toPubkey)
            let event = try await delegate.buildResponseEvent(
                content: encrypted,
                recipientPubkey: toPubkey
            )
            _ = try await connection.publish(event: event)
        } catch {
            // Log but don't crash — best effort delivery
        }
    }

    // MARK: - Session Management

    private func completeSession(_ session: NIP46RequestSession) {
        session.transition(to: .completed)
        deduplicator.markCompleted(session.eventId)

        lock.lock()
        _activeSessions.removeValue(forKey: session.request.id)
        lock.unlock()
    }

    private func cleanupSession(_ session: NIP46RequestSession) {
        deduplicator.markCompleted(session.eventId)

        lock.lock()
        _activeSessions.removeValue(forKey: session.request.id)
        lock.unlock()
    }

    // MARK: - Timeout Sweep

    private func startTimeoutSweep() {
        timeoutTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
                self?.sweepTimedOut()
            }
        }
    }

    private func sweepTimedOut() {
        lock.lock()
        let sessions = Array(_activeSessions.values)
        let timeout = requestTimeout
        lock.unlock()

        for session in sessions {
            if session.hasTimedOut(timeout: timeout) {
                session.transition(to: .timedOut)
                Task {
                    await sendErrorResponse(
                        id: session.request.id,
                        error: "request timed out",
                        toPubkey: session.requesterPubkey
                    )
                    cleanupSession(session)
                }
            }
        }
    }

    // MARK: - Helpers

    /// Try to extract the "id" field from a JSON string (for error responses).
    private func extractId(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else {
            return nil
        }
        return id
    }
}
