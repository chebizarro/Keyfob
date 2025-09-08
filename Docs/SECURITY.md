# Security Model

- Keys stored only in Keychain (optionally iCloud). Access Group: `TODO_TEAMID.com.yourorg.keyfob.shared`.
- App Group for small shared state: `group.com.yourorg.keyfob`.
- Every signature requires visible consent unless a session (Mode B) is active and within timeout.
- Biometrics via LocalAuthentication required per approval or at session start.
- Strict JSON schema; deterministic canonical JSON; stable field order; normalized unicode.
- Payload caps; reject ambiguous/extra fields; constant-time compares.
- Encrypted export only; no screenshots on sensitive screens; blur in app switcher.
- macOS uses XPC only; no localhost sockets.
