//
//  PermissionRuleStore.swift
//
//
//  Created for Keyfob – kf-sxf
//

import Foundation

// MARK: - PermissionRuleStore Protocol

/// Errors from ``PermissionRuleStore`` operations.
public enum PermissionRuleStoreError: Error, Equatable {
    case ruleNotFound(UUID)
    case storageUnavailable(String)
    case dataCorrupt(String)
}

/// Protocol for persisting and querying ``PermissionRule`` instances.
public protocol PermissionRuleStore: Sendable {

    /// Add a new rule to the store.
    func addRule(_ rule: PermissionRule) throws

    /// Remove a rule by its ID.
    func removeRule(id: UUID) throws

    /// Remove all rules for a given client.
    func removeRules(forClient clientID: String) throws

    /// Retrieve all rules for a given client, including expired ones.
    func rules(forClient clientID: String) throws -> [PermissionRule]

    /// Retrieve all rules in the store.
    func allRules() throws -> [PermissionRule]

    /// Remove expired rules and return the count of removed rules.
    @discardableResult
    func pruneExpired() throws -> Int

    /// Evaluate rules for a specific request context.
    ///
    /// Convenience that fetches matching rules and calls ``PermissionRule/evaluate(rules:clientID:identityID:operationKind:eventKind:)``.
    func evaluate(
        clientID: String,
        identityID: UUID?,
        operationKind: String,
        eventKind: Int?
    ) throws -> PermissionRule.Decision?
}

// MARK: - Persistence Envelope

/// On-disk JSON envelope for permission rules.
struct PermissionRuleFile: Codable {
    var schemaVersion: Int = 1
    var rules: [PermissionRule]
}

// MARK: - FilePermissionRuleStore

/// JSON-file-backed implementation of ``PermissionRuleStore``.
///
/// Follows the same cross-process safety pattern as `FileClientRegistry`:
/// `flock` file locking + atomic file replacement.
public final class FilePermissionRuleStore: PermissionRuleStore, @unchecked Sendable {

    // MARK: - Properties

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.keyfob.permissionRuleStore", qos: .userInitiated)

    // MARK: - Init

    /// Creates a rule store in the given container directory.
    ///
    /// - Parameter containerURL: The directory in which to store rule data.
    ///   A `PermissionRules` subdirectory is created automatically.
    public init(containerURL: URL) throws {
        let dir = containerURL.appendingPathComponent("PermissionRules", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("rules.json")

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let empty = PermissionRuleFile(rules: [])
            try writeFile(empty)
        }
    }

    // MARK: - PermissionRuleStore

    public func addRule(_ rule: PermissionRule) throws {
        try withFileLock { file in
            file.rules.append(rule)
            try self.writeFile(file)
        }
    }

    public func removeRule(id: UUID) throws {
        try withFileLock { file in
            guard file.rules.contains(where: { $0.id == id }) else {
                throw PermissionRuleStoreError.ruleNotFound(id)
            }
            file.rules.removeAll(where: { $0.id == id })
            try self.writeFile(file)
        }
    }

    public func removeRules(forClient clientID: String) throws {
        try withFileLock { file in
            file.rules.removeAll(where: { $0.clientID == clientID })
            try self.writeFile(file)
        }
    }

    public func rules(forClient clientID: String) throws -> [PermissionRule] {
        let file = try readFile()
        return file.rules.filter { $0.clientID == clientID }
    }

    public func allRules() throws -> [PermissionRule] {
        try readFile().rules
    }

    @discardableResult
    public func pruneExpired() throws -> Int {
        try withFileLock { file in
            let before = file.rules.count
            file.rules.removeAll(where: { $0.isExpired })
            let removed = before - file.rules.count
            if removed > 0 {
                try self.writeFile(file)
            }
            return removed
        }
    }

    public func evaluate(
        clientID: String,
        identityID: UUID?,
        operationKind: String,
        eventKind: Int?
    ) throws -> PermissionRule.Decision? {
        let clientRules = try rules(forClient: clientID)
        return PermissionRule.evaluate(
            rules: clientRules,
            clientID: clientID,
            identityID: identityID,
            operationKind: operationKind,
            eventKind: eventKind
        )
    }

    // MARK: - Private: File I/O

    private func readFile() throws -> PermissionRuleFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return PermissionRuleFile(rules: [])
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw PermissionRuleStoreError.storageUnavailable(error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            return try decoder.decode(PermissionRuleFile.self, from: data)
        } catch {
            throw PermissionRuleStoreError.dataCorrupt(error.localizedDescription)
        }
    }

    private func writeFile(_ file: PermissionRuleFile) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(file)
        } catch {
            throw PermissionRuleStoreError.storageUnavailable("Encoding failed: \(error.localizedDescription)")
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw PermissionRuleStoreError.storageUnavailable("Write failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func withFileLock<T>(_ body: (inout PermissionRuleFile) throws -> T) throws -> T {
        let lockURL = fileURL.appendingPathExtension("lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            throw PermissionRuleStoreError.storageUnavailable("Could not open lock file")
        }
        defer { close(fd) }

        guard flock(fd, LOCK_EX) == 0 else {
            throw PermissionRuleStoreError.storageUnavailable("Could not acquire file lock")
        }
        defer { flock(fd, LOCK_UN) }

        var file = try readFile()
        return try body(&file)
    }
}
