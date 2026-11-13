import Foundation
import Security

/// One sign-in at one provider.
public struct Account: Codable, Sendable, Equatable {
    public var provider: String
    /// The provider's own id for the account.
    public var subject: String
    public var organization: String?
    /// What the user calls it: the email the provider reports.
    public var label: String
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public var id: String { [provider, subject, organization].compactMap { $0 }.joined(separator: "/") }

    public init(provider: String, subject: String, organization: String?, label: String, accessToken: String, refreshToken: String, expiresAt: Date) {
        self.provider = provider
        self.subject = subject
        self.organization = organization
        self.label = label
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public struct VaultError: Error, CustomStringConvertible {
    let status: OSStatus
    public var description: String { "Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)")" }
}

/// Where Sluice keeps things between runs.
public struct Storage: Sendable {
    var loadAccounts: @Sendable () throws -> [Account]
    var storeAccounts: @Sendable ([Account]) throws -> Void
    /// Read at each placement, so an edit takes effect at once.
    var config: @Sendable () throws -> Config
    var loadMemory: @Sendable () throws -> Memory
    var storeMemory: @Sendable (Memory) throws -> Void

    /// Accounts in one Keychain item, so a save is atomic; the hand-edited config in `~/.config/sluice`;
    /// what was observed in Application Support.
    public static let live: Storage = {
        let query: [String: any Sendable] = [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrService as String: "dev.vikng.sluice",
            kSecAttrAccount as String: "accounts",
        ]
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configFile = home.appending(path: ".config/sluice/config.json")
        let memoryFile = home.appending(path: "Library/Application Support/Sluice/memory.json")
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
            loadMemory: { try readJSON(memoryFile, or: Memory()) },
            storeMemory: { memory in
                try FileManager.default.createDirectory(at: memoryFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(memory).write(to: memoryFile, options: .atomic)
            }
        )
    }()
}

/// A JSON file's contents, or `empty` when the file does not exist yet.
private func readJSON<T: Decodable>(_ file: URL, or empty: T) throws -> T {
    guard FileManager.default.fileExists(atPath: file.path) else { return empty }
    do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: file)) } catch { throw UnreadableFile(path: file.path, cause: error) }
}

struct UnreadableFile: Error, CustomStringConvertible {
    let path: String
    let cause: any Error
    var description: String { "\(path) could not be read: \(cause)" }
}

/// `config.json`, written by hand. A key left out is an empty rule.
public struct Config: Decodable, Sendable {
    /// Labels of accounts that only a pin reaches.
    var pinOnly: Set<String> = []
    /// Folders whose work is pinned to one account: folder (`~` allowed) to the account's label.
    var pins: [String: String] = [:]
    /// Repository owners whose work is pinned to one account: the owner in a repository's origin remote, to the label.
    var owners: [String: String] = [:]

    init() {}

    public init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        pinOnly = try keys.decodeIfPresent(Set<String>.self, forKey: .pinOnly) ?? []
        pins = try keys.decodeIfPresent([String: String].self, forKey: .pins) ?? [:]
        owners = try keys.decodeIfPresent([String: String].self, forKey: .owners) ?? [:]
    }

    private enum CodingKeys: CodingKey { case pinOnly, pins, owners }

    /// The account pinned for work in `directory`: the rule for the deepest folder containing it,
    /// or else the rule for the owner of the repository it is in.
    func pin(for directory: String, home: String, owner: (String) -> String? = Repo.owner) -> String? {
        func folder(_ rule: String) -> String { (rule.hasPrefix("~") ? home + rule.dropFirst() : rule).trimmingSuffix("/") + "/" }
        if let rule = pins.filter({ (directory.trimmingSuffix("/") + "/").hasPrefix(folder($0.key)) }).max(by: { folder($0.key).count < folder($1.key).count }) { return rule.value }
        guard !owners.isEmpty, let owner = owner(directory) else { return nil }
        return owners.first { $0.key.lowercased() == owner }?.value
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String { hasSuffix(suffix) ? String(dropLast(suffix.count)) : self }
}

/// What Sluice observed and would otherwise relearn after a restart.
struct Memory: Codable {
    var usage: [String: [Window]] = [:]
    var router = Router()
}

public struct AccountStatus: Codable, Sendable {
    public var provider: String
    public var label: String
    public var pinOnly: Bool
    public var windows: [Window]
    public var warmConversations: Int
}

/// The accounts, what each provider last said about them, and where conversations are held.
actor Accounts {
    private let storage: Storage
    private var accounts: [Account]
    private var refreshing: [String: Task<Account, any Error>] = [:]
    private var memory: Memory

    init(storage: Storage) throws {
        self.storage = storage
        accounts = try storage.loadAccounts()
        memory = try storage.loadMemory()
    }

    func status() throws -> [AccountStatus] {
        let config = try storage.config(), now = Date()
        return accounts.map {
            AccountStatus(
                provider: $0.provider, label: $0.label, pinOnly: config.pinOnly.contains($0.label),
                windows: (memory.usage[$0.id] ?? []).filter { $0.resetsAt > now }, warmConversations: memory.router.warmConversations(on: $0.id, now: now)
            )
        }
    }

    func save(_ account: Account) throws {
        var next = accounts
        if let index = next.firstIndex(where: { $0.id == account.id }) { next[index] = account } else { next.append(account) }
        try storage.storeAccounts(next)
        accounts = next
    }

    /// The accounts to try, in order. A pin in the address wins; without one the caller's folder may name one.
    func candidates(provider: String, pin: String?, folder: String?, conversation: String?) throws -> [Account] {
        let config = try storage.config()
        return memory.router.order(
            accounts.filter { $0.provider == provider },
            pin: pin ?? folder.flatMap { config.pin(for: $0, home: NSHomeDirectory()) }, pinOnly: config.pinOnly,
            conversation: conversation, usage: memory.usage, now: Date()
        )
    }

    func record(_ windows: [Window], for id: String) {
        for window in windows {
            memory.usage[id, default: []].removeAll { $0.name == window.name }
            memory.usage[id, default: []].append(window)
        }
        if !windows.isEmpty { remember() }
    }

    func served(_ conversation: String, by id: String, cacheLifetime: TimeInterval) {
        memory.router.served(conversation, by: id, cacheLifetime: cacheLifetime, now: Date())
        remember()
    }

    /// Memory is relearned from the next responses, so a failed write costs only that and is reported, not fatal.
    private func remember() {
        do { try storage.storeMemory(memory) } catch {
            FileHandle.standardError.write(Data("sluice: could not save what was observed: \(error)\n".utf8))
        }
    }

    /// The account with a token good for at least five more minutes, renewed once however many requests ask.
    func fresh(_ id: String, using provider: any Provider) async throws -> Account {
        if let running = refreshing[id] { return try await running.value }
        guard let account = accounts.first(where: { $0.id == id }) else { throw ProviderError.signedOut }
        guard account.expiresAt < Date().addingTimeInterval(300) else { return account }
        let task = Task { try await provider.refresh(account) }
        refreshing[id] = task
        defer { refreshing[id] = nil }
        let renewed = try await task.value
        try save(renewed)
        return renewed
    }
}
