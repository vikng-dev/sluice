import Foundation
import Security

public struct VaultError: Error, CustomStringConvertible {
    let status: OSStatus
    public var description: String { "Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)")" }
}

/// Where Sluice keeps things between runs.
public struct Storage: Sendable {
    var loadAccounts: @Sendable () throws -> [Account]
    var storeAccounts: @Sendable ([Account]) throws -> Void
    /// Read at each placement, so an edit takes effect at once.
    public var config: @Sendable () throws -> Config
    public var storeConfig: @Sendable (Config) throws -> Void
    var loadMemory: @Sendable () throws -> Memory
    var storeMemory: @Sendable (Memory) throws -> Void
    var appendSample: @Sendable (Sample) throws -> Void = { _ in }
    var appendServed: @Sendable (Served) throws -> Void = { _ in }
    /// The histories, oldest first.
    public var readings: @Sendable () throws -> [Sample] = { [] }
    public var requests: @Sendable () throws -> [Served] = { [] }

    /// Accounts in one Keychain item, so a save is atomic; the config in `~/.config/sluice`;
    /// what was observed, and the history of it, in Application Support.
    public static let live: Storage = {
        let query: [String: any Sendable] = [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrService as String: Sluice.id,
            kSecAttrAccount as String: "accounts",
        ]
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configFile = home.appending(path: ".config/sluice/config.json")
        let memoryFile = home.appending(path: "Library/Application Support/Sluice/memory.json")
        let readingsFile = home.appending(path: "Library/Application Support/Sluice/readings.jsonl")
        let requestsFile = home.appending(path: "Library/Application Support/Sluice/requests.jsonl")
        return Storage(
            loadAccounts: {
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &item)
                if status == errSecItemNotFound { return [] }
                guard status == errSecSuccess, let data = item as? Data else { throw VaultError(status: status) }
                return try JSONDecoder().decode([Account].self, from: data)
            },
            storeAccounts: { accounts in
                let data = try JSONEncoder().encode(accounts)
                var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
                if status == errSecItemNotFound {
                    status = SecItemAdd(query.merging([kSecValueData as String: data]) { $1 } as CFDictionary, nil)
                }
                guard status == errSecSuccess else { throw VaultError(status: status) }
            },
            config: { try readJSON(configFile, or: Config()) },
            storeConfig: { config in
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try UserFile(configFile).write(encoder.encode(config) + Data("\n".utf8))
            },
            loadMemory: { try readJSON(memoryFile, or: Memory()) },
            storeMemory: { memory in
                try FileManager.default.createDirectory(at: memoryFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(memory).write(to: memoryFile, options: .atomic)
            },
            appendSample: { try append($0, to: readingsFile) },
            appendServed: { try append($0, to: requestsFile) },
            readings: { try lines(of: readingsFile) },
            requests: { try lines(of: requestsFile) }
        )
    }()
}

/// A JSON file's contents, or `empty` when the file does not exist yet.
private func readJSON<T: Decodable>(_ file: URL, or empty: T) throws -> T {
    guard FileManager.default.fileExists(atPath: file.path) else { return empty }
    do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: file)) } catch { throw UserFileError(path: file.path, reason: "could not be read: \(error)") }
}

/// Adds a line to a history file, which is made on the first.
func append(_ entry: some Encodable, to file: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let line = try encoder.encode(entry) + Data("\n".utf8)
    if !FileManager.default.fileExists(atPath: file.path) {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try line.write(to: file)
    }
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
}

/// A history file's lines, oldest first; none when there is no file yet. A line that cannot be read is
/// left out: the last may be half written, and an older build wrote less.
func lines<Entry: Decodable>(of file: URL) throws -> [Entry] {
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try Data(contentsOf: file).split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(Entry.self, from: $0) }
}

/// A file of the user's that Sluice could not read or may not change.
public struct UserFileError: Error, CustomStringConvertible {
    public let path: String
    public let reason: String
    public init(path: String, reason: String) { self.path = path; self.reason = reason }
    public var description: String { "\(path): \(reason)" }
}

/// A file of the user's that Sluice edits: absent is empty, and a write goes to the file a link points at.
public struct UserFile: Sendable {
    let file: URL
    public init(_ file: URL) { self.file = file.resolvingSymlinksInPath() }
    public var path: String { file.path }

    public func read() throws -> Data? {
        FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
    }

    public func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}
