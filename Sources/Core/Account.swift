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
    public var config: @Sendable () throws -> Config
    public var storeConfig: @Sendable (Config) throws -> Void
    var loadMemory: @Sendable () throws -> Memory
    var storeMemory: @Sendable (Memory) throws -> Void

    /// Accounts in one Keychain item, so a save is atomic; the config in `~/.config/sluice`;
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
            storeConfig: { config in
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try UserFile(configFile).write(encoder.encode(config) + Data("\n".utf8))
            },
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

/// One separate setup: the accounts whose usage it pools, and the work that belongs to it.
public struct Profile: Codable, Sendable, Equatable {
    /// The accounts that serve its relayed requests.
    public internal(set) var accounts: [String] = []
    /// Folders (`~` allowed) whose work belongs to this profile.
    public internal(set) var folders: [String] = []
    /// Owners, as in a repository's origin remote, whose repositories belong to this profile.
    public internal(set) var owners: [String] = []

    init() {}

    public init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try keys.decodeIfPresent([String].self, forKey: .accounts) ?? []
        folders = try keys.decodeIfPresent([String].self, forKey: .folders) ?? []
        owners = try keys.decodeIfPresent([String].self, forKey: .owners) ?? []
    }

    /// Only what is set is written, as a person would write it.
    public func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: CodingKeys.self)
        if !accounts.isEmpty { try keys.encode(accounts, forKey: .accounts) }
        if !folders.isEmpty { try keys.encode(folders, forKey: .folders) }
        if !owners.isEmpty { try keys.encode(owners, forKey: .owners) }
    }

    private enum CodingKeys: CodingKey { case accounts, folders, owners }
}

/// `config.json`, written by hand or by the `sluice` command: the profiles. Work no profile claims, and
/// an account no profile lists, belong to the profile named `default`, which exists whether or not it
/// is written down.
public struct Config: Codable, Sendable, Equatable {
    public static let defaultProfile = "default"
    public internal(set) var profiles: [String: Profile] = [:]

    init() {}

    public init(from decoder: any Decoder) throws {
        profiles = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([String: Profile].self, forKey: .profiles) ?? [:]
    }

    private enum CodingKeys: CodingKey { case profiles }

    /// Every profile's name, the default first.
    public var names: [String] { [Self.defaultProfile] + profiles.keys.filter { $0 != Self.defaultProfile }.sorted() }

    /// The profile that work in `directory` belongs to: the one claiming the deepest folder containing it,
    /// or else the one claiming the owner of the repository it is in, or else the default.
    public func profile(for directory: String, home: String = NSHomeDirectory(), owner: (String) -> String? = Repo.owner) -> String {
        func folder(_ rule: String) -> String { (rule.hasPrefix("~") ? home + rule.dropFirst() : rule).trimmingSuffix("/") + "/" }
        let claims = profiles.flatMap { name, profile in profile.folders.map { (name: name, folder: folder($0)) } }
        if let claim = claims.filter({ (directory.trimmingSuffix("/") + "/").hasPrefix($0.folder) }).max(by: { $0.folder.count < $1.folder.count }) { return claim.name }
        guard profiles.values.contains(where: { !$0.owners.isEmpty }), let owner = owner(directory) else { return Self.defaultProfile }
        return profiles.first { $0.value.owners.contains { $0.lowercased() == owner } }?.key ?? Self.defaultProfile
    }

    /// The profile an account belongs to.
    public func profile(ofAccount label: String) -> String {
        profiles.first { $0.value.accounts.contains(label) }?.key ?? Self.defaultProfile
    }

    /// The accounts that may pay for `profile`'s work: its own and no other's, so a profile with none
    /// at a provider cannot use that provider.
    func pool(_ accounts: [Account], for profile: String) -> [Account] {
        accounts.filter { self.profile(ofAccount: $0.label) == profile }
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
    public var profile: String
    /// As its provider last told it, since the relay started.
    public var plan: Plan?
    public var windows: [Window]
    public var warmConversations: Int
    /// When it last answered a relayed request, since the relay started.
    public var lastAnswered: Date?
    /// Why it cannot serve, in the provider's or Sluice's words; nil when nothing is known to be wrong.
    public var problem: String?
}

/// The accounts, what each provider last said about them, and where conversations are held.
actor Accounts {
    private let storage: Storage
    private var accounts: [Account]
    private var refreshing: [String: Task<Account, any Error>] = [:]
    private var memory: Memory
    private var lastAnswered: [String: Date] = [:]
    private var problems: [String: String] = [:]
    private var plans: [String: Plan] = [:]

    init(storage: Storage) throws {
        self.storage = storage
        accounts = try storage.loadAccounts()
        memory = try storage.loadMemory()
    }

    func status() throws -> [AccountStatus] {
        let config = try storage.config(), now = Date()
        return accounts.map {
            AccountStatus(
                provider: $0.provider, label: $0.label, profile: config.profile(ofAccount: $0.label), plan: plans[$0.id],
                windows: (memory.usage[$0.id] ?? []).filter { $0.resetsAt > now }.sorted { $0.resetsAt < $1.resetsAt },
                warmConversations: memory.router.warmConversations(on: $0.id, now: now), lastAnswered: lastAnswered[$0.id], problem: problems[$0.id]
            )
        }
    }

    /// Forgets a sign-in, and what was observed about it. False when there is no such account.
    func remove(provider: String, label: String) throws -> Bool {
        guard let gone = accounts.first(where: { $0.provider == provider && $0.label == label }) else { return false }
        let next = accounts.filter { $0.id != gone.id }
        try storage.storeAccounts(next)
        accounts = next
        memory.usage[gone.id] = nil
        (plans[gone.id], problems[gone.id], lastAnswered[gone.id]) = (nil, nil, nil)
        remember()
        return true
    }

    func save(_ account: Account) throws {
        var next = accounts
        if let index = next.firstIndex(where: { $0.id == account.id }) { next[index] = account } else { next.append(account) }
        try storage.storeAccounts(next)
        accounts = next
    }

    /// The profile the caller's folder belongs to, and the accounts to try, in order: its pool at the
    /// provider, or of that pool the one account a pin in the address names.
    func candidates(provider: String, pin: String?, folder: String?, conversation: String?) throws -> (profile: String, accounts: [Account]) {
        let config = try storage.config()
        let profile = folder.map { config.profile(for: $0) } ?? Config.defaultProfile
        let pool = config.pool(accounts.filter { $0.provider == provider }, for: profile)
        if let pin { return (profile, pool.filter { $0.label == pin }) }
        return (profile, memory.router.order(pool, conversation: conversation, usage: memory.usage, now: Date()))
    }

    var all: [Account] { accounts }

    /// The account could not be used, for a reason worth showing until it next works.
    func failed(_ id: String, _ problem: String) {
        problems[id] = problem
    }

    /// What the provider said about the account when asked.
    func record(_ usage: Usage, for id: String) {
        plans[id] = usage.plan
        record(usage.windows, for: id)
    }

    /// The account answered a relayed request, reporting these windows.
    func answered(_ id: String, reporting windows: [Window]) {
        lastAnswered[id] = Date()
        record(windows, for: id)
    }

    private func record(_ windows: [Window], for id: String) {
        problems[id] = nil
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
