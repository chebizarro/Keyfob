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
- Local-only event approvals/denials with timestamp and origin.
