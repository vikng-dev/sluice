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

/// Every account, in one Keychain item, so a save is atomic.
public struct Vault: Sendable {
    private let query: [String: any Sendable] = [
        kSecClass as String: kSecClassGenericPassword as String,
        kSecAttrService as String: "dev.vikng.sluice",
        kSecAttrAccount as String: "accounts",
    ]

    public init() {}

    func load() throws -> [Account] {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = item as? Data else { throw VaultError(status: status) }
        return try JSONDecoder().decode([Account].self, from: data)
    }

    func store(_ accounts: [Account]) throws {
        let data = try JSONEncoder().encode(accounts)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging([kSecValueData as String: data]) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw VaultError(status: status) }
    }
}

actor Accounts {
    private let vault: Vault
    private var accounts: [Account]
    private var refreshing: [String: Task<Account, any Error>] = [:]

    init(vault: Vault) throws {
        self.vault = vault
        accounts = try vault.load()
    }

    var all: [Account] { accounts }

    func save(_ account: Account) throws {
        var next = accounts
        if let index = next.firstIndex(where: { $0.id == account.id }) { next[index] = account } else { next.append(account) }
        try vault.store(next)
        accounts = next
    }

    func pick(provider: String, pin: String?) -> Account? {
        accounts.first { $0.provider == provider && (pin == nil || $0.label == pin) }
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
