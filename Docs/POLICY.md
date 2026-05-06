# Policy Engine

## Origin Registry
- Map: origin (domain or app bundle) → { status, expiry, sessionPolicy, lastUsed }
- Stored under the App Group container.

## Sessions
- Mode A: Always prompt per request.
- Mode B: One-time approval establishes a short-lived session (default 5 min, configurable), bound to (origin, pubkey).

## Limits
- Token bucket per origin
- Max payload size for events
- Reject unknown fields, enforce schemas

## Audit Log

The `PolicyEngine` maintains an append-only audit log (`AuditLog`) recording
every policy decision. The log is stored as a JSON Lines file
(`audit_log.jsonl`) in the App Group container.

### Recorded Events

| Action | When |
|---|---|
| `approved` | Consent provider approved a signing request |
| `denied` | Consent provider denied a signing request |
| `sessionAutoApproved` | Session-mode request auto-approved (origin allowed + valid session window) |
| `rateLimited` | Preflight rejected the request (token bucket exhausted) |
| `noProvider` | No consent provider was configured when a request arrived |

### Entry Fields

Each entry contains:
- **timestamp** — ISO-8601 date of the decision
- **origin** — requesting domain or bundle ID
- **action** — one of the actions above
- **eventKind** — Nostr event kind (optional, when available)
- **detail** — human-readable context (consent mode, error message, etc.)

### API

```swift
// Access via the shared engine
let log = PolicyEngine.shared.auditLog

// Read recent entries
let recent = log.entries(limit: 50)

// Filter by origin or action
let fromExample = log.entries(forOrigin: "example.com")
let denials     = log.entries(withAction: .denied)

// Total count
let total = log.entryCount

// Privacy: clear all entries
log.clear()
```

### Storage

- File: `<App Group Container>/audit_log.jsonl`
- Format: One JSON object per line (JSON Lines)
- Auto-trims at 10,000 entries (keeps most recent 5,000)
- Thread-safe (serial dispatch queue)
