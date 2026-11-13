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

/// Where accounts are kept.
public struct Vault: Sendable {
    let load: @Sendable () throws -> [Account]
    let store: @Sendable ([Account]) throws -> Void

    /// Every account in one Keychain item, so a save is atomic.
    public static let keychain: Vault = {
        let query: [String: any Sendable] = [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrService as String: "dev.vikng.sluice",
            kSecAttrAccount as String: "accounts",
        ]
        return Vault(
            load: {
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &item)
                if status == errSecItemNotFound { return [] }
                guard status == errSecSuccess, let data = item as? Data else { throw VaultError(status: status) }
                return try JSONDecoder().decode([Account].self, from: data)
            },
            store: { accounts in
                let data = try JSONEncoder().encode(accounts)
                var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
                if status == errSecItemNotFound {
                    status = SecItemAdd(query.merging([kSecValueData as String: data]) { $1 } as CFDictionary, nil)
                }
                guard status == errSecSuccess else { throw VaultError(status: status) }
            }
        )
    }()
}

/// `~/.config/sluice/config.json`, read at each placement so an edit takes effect at once.
struct Config: Decodable {
    /// Labels of accounts that only a pin reaches.
    var pinOnly: Set<String> = []

    static let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/sluice/config.json")

    @Sendable static func load() throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }
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
    private let vault: Vault
    private var accounts: [Account]
    private var refreshing: [String: Task<Account, any Error>] = [:]
    private var usage: [String: [Window]] = [:]
    private var router = Router()
    private let config: @Sendable () throws -> Config

    init(vault: Vault, config: @escaping @Sendable () throws -> Config) throws {
        self.vault = vault
        self.config = config
        accounts = try vault.load()
    }

    func status() throws -> [AccountStatus] {
        let config = try config(), now = Date()
        return accounts.map {
            AccountStatus(
                provider: $0.provider, label: $0.label, pinOnly: config.pinOnly.contains($0.label),
                windows: (usage[$0.id] ?? []).filter { $0.resetsAt > now }, warmConversations: router.warmConversations(on: $0.id, now: now)
            )
        }
    }

    func save(_ account: Account) throws {
        var next = accounts
        if let index = next.firstIndex(where: { $0.id == account.id }) { next[index] = account } else { next.append(account) }
        try vault.store(next)
        accounts = next
    }

    func candidates(provider: String, pin: String?, conversation: String?) throws -> [Account] {
        router.order(
            accounts.filter { $0.provider == provider }, pin: pin, pinOnly: try config().pinOnly,
            conversation: conversation, usage: usage, now: Date()
        )
    }

    func record(_ windows: [Window], for id: String) {
        for window in windows {
            usage[id, default: []].removeAll { $0.name == window.name }
            usage[id, default: []].append(window)
        }
    }

    func served(_ conversation: String, by id: String, cacheLifetime: TimeInterval) {
        router.served(conversation, by: id, cacheLifetime: cacheLifetime, now: Date())
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
