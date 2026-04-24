//
//  FileClientRegistry.swift
//
//
//  Created for Keyfob – kf-92b
//

import Foundation

// MARK: - Persistence Envelope

/// On-disk JSON envelope for registered clients.
///
/// Stored at `<containerDir>/ClientRegistry/clients.json`.
/// The `schemaVersion` field allows forward-compatible migrations.
struct ClientRegistryFile: Codable {
    var schemaVersion: Int = 1
    var clients: [ClientIdentity]
}

// MARK: - FileClientRegistry

/// JSON-file-backed implementation of ``ClientRegistry``.
///
/// - The registry file is stored in a configurable directory (defaults to
///   the app group container via ``KeyfobCoreConfig``).
/// - Cross-process safety follows the same pattern as `KeychainIdentityStore`:
///   `flock` file locking + atomic file replacement.
/// - Lightweight: no Keychain involvement, no Darwin notifications.
///   The registry is consulted synchronously during pipeline execution.
public final class FileClientRegistry: ClientRegistry, @unchecked Sendable {

    // MARK: - Properties

    /// URL of the registry JSON file.
    private let registryURL: URL

    /// Serial queue protecting in-process access.
    private let queue = DispatchQueue(label: "com.keyfob.clientRegistry", qos: .userInitiated)

    // MARK: - Init

    /// Creates a registry in the given container directory.
    ///
    /// - Parameter containerURL: The directory in which to store registry data.
    ///   A `ClientRegistry` subdirectory is created automatically.
    public init(containerURL: URL) throws {
        let dir = containerURL.appendingPathComponent("ClientRegistry", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.registryURL = dir.appendingPathComponent("clients.json")

        // Create empty file if it doesn't exist.
        if !FileManager.default.fileExists(atPath: registryURL.path) {
            let empty = ClientRegistryFile(clients: [])
            try writeFile(empty)
        }
    }

    // MARK: - ClientRegistry

    @discardableResult
    public func registerOrUpdate(from context: ClientContext) throws -> ClientIdentity {
        try withFileLock { file in
            if let index = file.clients.firstIndex(where: { $0.id == context.clientID }) {
                // Update existing client.
                file.clients[index].lastSeen = Date()
                if let name = context.displayName, !name.isEmpty {
                    file.clients[index].displayName = name
                }
                try self.writeFile(file)
                return file.clients[index]
            } else {
                // Register new client.
                let identity = ClientIdentity(
                    id: context.clientID,
                    displayName: context.displayName,
                    channel: context.channel
                )
                file.clients.append(identity)
                try self.writeFile(file)
                return identity
            }
        }
    }

    public func lookup(id: String) throws -> ClientIdentity? {
        let file = try readFile()
        return file.clients.first(where: { $0.id == id })
    }

    public func listClients() throws -> [ClientIdentity] {
        let file = try readFile()
        return file.clients.sorted { $0.lastSeen > $1.lastSeen }
    }

    public func remove(id: String) throws {
        try withFileLock { file in
            guard file.clients.contains(where: { $0.id == id }) else {
                throw ClientRegistryError.clientNotFound(id)
            }
            file.clients.removeAll(where: { $0.id == id })
            try self.writeFile(file)
        }
    }

    // MARK: - Private: File I/O

    private func readFile() throws -> ClientRegistryFile {
        guard FileManager.default.fileExists(atPath: registryURL.path) else {
            return ClientRegistryFile(clients: [])
        }
        let data: Data
        do {
            data = try Data(contentsOf: registryURL)
        } catch {
            throw ClientRegistryError.storageUnavailable(error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            return try decoder.decode(ClientRegistryFile.self, from: data)
        } catch {
            throw ClientRegistryError.dataCorrupt(error.localizedDescription)
        }
    }

    private func writeFile(_ file: ClientRegistryFile) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(file)
        } catch {
            throw ClientRegistryError.storageUnavailable("Encoding failed: \(error.localizedDescription)")
        }
        do {
            try data.write(to: registryURL, options: .atomic)
        } catch {
            throw ClientRegistryError.storageUnavailable("Write failed: \(error.localizedDescription)")
        }
    }

    /// Execute a closure with exclusive file lock and fresh data.
    @discardableResult
    private func withFileLock<T>(_ body: (inout ClientRegistryFile) throws -> T) throws -> T {
        let lockURL = registryURL.appendingPathExtension("lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            throw ClientRegistryError.storageUnavailable("Could not open lock file")
        }
        defer { close(fd) }

        guard flock(fd, LOCK_EX) == 0 else {
            throw ClientRegistryError.storageUnavailable("Could not acquire file lock")
        }
        defer { flock(fd, LOCK_UN) }

        var file = try readFile()
        return try body(&file)
    }
}
