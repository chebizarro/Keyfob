//
//  OperationPipeline.swift
//
//
//  Created for Keyfob – kf-rek
//

import Foundation

/// The single entry point for ALL crypto operations from ALL IPC channels.
///
/// Conformers implement the full pipeline:
/// 1. **Validate** the operation (e.g. check pubkey format, event fields)
/// 2. **Resolve identity** via ``IdentitySelection`` → ``Identity``
/// 3. **Check policy rules** (rate limiting, origin allowlist)
/// 4. **Prompt consent** if required by policy or ``ApprovalPreference``
/// 5. **Execute** via SDK protocols (signing, NIP-44, NIP-04)
/// 6. **Audit log** the outcome
/// 7. **Return** the ``OperationOutput``
///
/// Failures at any stage are thrown as errors. The pipeline does not catch
/// and wrap errors — `IdentityStoreError`, `SignerError`, and policy errors
/// propagate directly so callers can handle them specifically.
///
/// ## Threading
///
/// Implementations should be safe for concurrent calls. Internal synchronization
/// (e.g. via `PolicyEngine`'s serial queue or `IdentityStore`'s file lock)
/// is the conformer's responsibility. Callers may invoke `execute` from any thread.
///
/// ## Current Status
///
/// The initial conformer (``SignOrchestrator``, via kf-85t) will support only
/// `.sign` operations. NIP-44 and NIP-04 operations will throw
/// ``OperationPipelineError/unsupportedOperation(_:)`` until their executor
/// beads land.
///
/// > Note: This protocol is synchronous. If async execution is needed in the
/// > future, an async overload can be added without breaking existing callers.
public protocol OperationPipeline {
    /// Execute a crypto operation through the full pipeline.
    ///
    /// - Parameters:
    ///   - operation: The operation to perform (sign, encrypt, decrypt).
    ///   - identity: Which identity to use for the operation.
    ///   - client: Context about the requesting client.
    /// - Returns: The operation output on success.
    /// - Throws: ``OperationPipelineError``, `IdentityStoreError`, `SignerError`,
    ///           or policy-layer errors on failure.
    func execute(
        operation: SignerOperation,
        identity: IdentitySelection,
        client: ClientContext
    ) throws -> OperationOutput
}
