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
    do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: file)) } catch { throw UnreadableFile(path: file.path, cause: error) }
}

struct UnreadableFile: Error, CustomStringConvertible {
    let path: String
    let cause: any Error
    var description: String { "\(path) could not be read: \(cause)" }
}

/// The colors a profile can be told apart by.
public enum Tint: String, Codable, Sendable, CaseIterable {
    case red, orange, yellow, green, teal, blue, purple, pink
}

/// One separate setup: the accounts whose usage it pools, and the work that belongs to it.
public struct Profile: Codable, Sendable, Equatable {
    /// What the user calls it, where its name in the config is not what they want to read.
    public internal(set) var label: String?
    public internal(set) var color: Tint?
    /// The providers whose pool here is shown in the menu bar.
    public internal(set) var starred: [String] = []
    /// The accounts that serve its relayed requests.
    public internal(set) var accounts: [String] = []
    /// Folders (`~` allowed) whose work belongs to this profile.
    public internal(set) var folders: [String] = []
    /// Owners, as in a repository's origin remote, whose repositories belong to this profile.
    public internal(set) var owners: [String] = []

    init() {}

    public init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        label = try keys.decodeIfPresent(String.self, forKey: .label)
        color = try keys.decodeIfPresent(Tint.self, forKey: .color)
        starred = try keys.decodeIfPresent([String].self, forKey: .starred) ?? []
        accounts = try keys.decodeIfPresent([String].self, forKey: .accounts) ?? []
        folders = try keys.decodeIfPresent([String].self, forKey: .folders) ?? []
        owners = try keys.decodeIfPresent([String].self, forKey: .owners) ?? []
    }

    /// Only what is set is written, as a person would write it.
    public func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: CodingKeys.self)
        try keys.encodeIfPresent(label, forKey: .label)
        try keys.encodeIfPresent(color, forKey: .color)
        if !starred.isEmpty { try keys.encode(starred, forKey: .starred) }
        if !accounts.isEmpty { try keys.encode(accounts, forKey: .accounts) }
        if !folders.isEmpty { try keys.encode(folders, forKey: .folders) }
        if !owners.isEmpty { try keys.encode(owners, forKey: .owners) }
    }

    private enum CodingKeys: CodingKey { case label, color, starred, accounts, folders, owners }
}

/// `config.json`, written by hand or by the `sluice` command: the profiles, and what holds for them all. Work no profile claims, and
/// an account no profile lists, belong to the profile named `default`, which exists whether or not it
/// is written down.
public struct Config: Codable, Sendable, Equatable {
    public static let defaultProfile = "default"
    public internal(set) var profiles: [String: Profile] = [:]
    /// A pool uses the resets its accounts hold without being asked: when it is out, and before one lapses.
    public internal(set) var autoResets = false

    public init() {}

    public init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try keys.decodeIfPresent([String: Profile].self, forKey: .profiles) ?? [:]
        autoResets = try keys.decodeIfPresent(Bool.self, forKey: .autoResets) ?? false
    }

    /// Only what is set is written, as a person would write it.
    public func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: CodingKeys.self)
        try keys.encode(profiles, forKey: .profiles)
        if autoResets { try keys.encode(true, forKey: .autoResets) }
    }

    private enum CodingKeys: CodingKey { case profiles, autoResets }

    /// Every profile's name, the default first.
    public var names: [String] { [Self.defaultProfile] + profiles.keys.filter { $0 != Self.defaultProfile }.sorted() }

    /// What a profile is shown as: its label, or failing one its name.
    public func shown(_ profile: String) -> String { profiles[profile]?.label ?? profile }

    /// The profile that work in `directory` belongs to: the one claiming the deepest folder containing it,
    /// or else the one claiming the owner of the repository it is in, or else the default.
    public func profile(for directory: String, home: String = NSHomeDirectory(), owner: (String) -> String? = Repo.owner) -> String {
        func folder(_ rule: String) -> String { (rule.hasPrefix("~") ? home + rule.dropFirst() : rule).trimmingSuffix("/") + "/" }
        let claims = profiles.flatMap { name, profile in profile.folders.map { (name: name, folder: folder($0)) } }
        if let claim = claims.filter({ (directory.trimmingSuffix("/") + "/").hasPrefix($0.folder) }).max(by: { $0.folder.count < $1.folder.count }) { return claim.name }
        guard profiles.values.contains(where: { !$0.owners.isEmpty }), let owner = owner(directory) else { return Self.defaultProfile }
        return profiles.first { $0.value.owners.contains { $0.lowercased() == owner } }?.key ?? Self.defaultProfile
    }

    /// A client's folder in a profile: its usual one in the default, and beside it `<usual>-<name>` in another.
    public static func folder(_ usual: String, of profile: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: profile == defaultProfile ? usual : "\(usual)-\(profile)")
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
    /// By provider: how its own client last named itself. Nil in a memory from before this was kept.
    var clients: [String: String]?
}

public struct AccountStatus: Codable, Sendable {
    public var provider: String
    public var label: String
    public var profile: String
    /// As its provider last told it, since the relay started.
    public var plan: Plan?
    public var windows: [Window]
    /// The limits on a part of its use, such as one model's own share of the week.
    public var scoped: [Window] = []
    /// The resets it holds, as its provider last told.
    public var resets: [Reset] = []
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
    /// What each account's windows read when its last line of history was written.
    private var sampled: [String: [Window]] = [:]
    /// The limits on a part of each account's use, as last told.
    private var scoped: [String: [Window]] = [:]
    /// The resets each account holds, and when that was last asked, since the relay started.
    private var resets: [String: [Reset]] = [:]
    private var resetsAsked: [String: Date] = [:]
    /// The accounts no reset is used on unasked: one is being used there now, or one was and it is not
    /// known to have gone well.
    private var paused: Set<String> = []

    init(storage: Storage) throws {
        self.storage = storage
        accounts = try storage.loadAccounts()
        memory = try storage.loadMemory()
    }

    func status() throws -> [AccountStatus] {
        let config = try storage.config(), now = Date()
        return accounts.map {
            let live = live($0.id, now: now)
            return AccountStatus(
                provider: $0.provider, label: $0.label, profile: config.profile(ofAccount: $0.label), plan: plans[$0.id],
                windows: live.windows.sorted { $0.resetsAt < $1.resetsAt }, scoped: live.scoped, resets: live.resets,
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
        (plans[gone.id], problems[gone.id], lastAnswered[gone.id], scoped[gone.id], resets[gone.id], resetsAsked[gone.id]) = (nil, nil, nil, nil, nil, nil)
        paused.remove(gone.id)
        remember()
        return true
    }

    func save(_ account: Account) throws {
        var next = accounts
        if let index = next.firstIndex(where: { $0.id == account.id }) { next[index] = account } else { next.append(account) }
        try storage.storeAccounts(next)
        accounts = next
    }

    /// The profile the caller's folder belongs to, and the accounts to try for a request for `model`, in
    /// order: its pool at the provider, or of that pool the one account a pin in the address names. With
    /// them, all of the accounts the request could be answered by, for when those tried all refuse.
    func candidates(provider: String, pin: String?, folder: String?, conversation: String?, model: String?) throws -> (profile: String, accounts: [Account], pool: [Account]) {
        let config = try storage.config(), now = Date()
        let profile = folder.map { config.profile(for: $0) } ?? Config.defaultProfile
        var pool = config.pool(accounts.filter { $0.provider == provider }, for: profile)
        if let pin { pool = pool.filter { $0.label == pin } }
        let order = pin == nil ? memory.router.order(pool.map { standing($0, now: now) }, conversation: conversation, model: model, now: now) : pool.map(\.id)
        return (profile, order.compactMap { id in pool.first { $0.id == id } }, pool)
    }

    var all: [Account] { accounts }

    /// The account could not be used, for a reason worth showing until it next works.
    func failed(_ id: String, _ problem: String) {
        problems[id] = problem
    }

    /// What the provider said about the account when asked.
    func record(_ usage: Usage, for id: String) {
        plans[id] = usage.plan
        scoped[id] = usage.scoped
        record(usage.windows, for: id)
    }

    /// A provider's own client named itself on a request. True when that is news.
    func seen(client: String, of provider: String) -> Bool {
        guard memory.clients?[provider] != client else { return false }
        memory.clients = (memory.clients ?? [:]).merging([provider: client]) { $1 }
        remember()
        return true
    }

    func client(of provider: String) -> String? { memory.clients?[provider] }

    /// Providers answer about resets grudgingly, so each account is asked once an hour, and when a reset
    /// its provider would not take until some time has reached that time.
    func owesResets(_ id: String, now: Date = Date()) -> Bool {
        guard let asked = resetsAsked[id] else { return true }
        return now.timeIntervalSince(asked) >= 3600 || (resets[id] ?? []).contains { !$0.usable && $0.usableAfter.map { $0 <= now } == true }
    }

    func record(resets held: [Reset], for id: String) {
        resets[id] = held
        resetsAsked[id] = Date()
    }

    /// The account's resets were asked for and not told. What was known stands until the next hour.
    func resetsNotTold(_ id: String) {
        resetsAsked[id] = Date()
    }

    /// The resets the account still holds.
    private func held(by id: String, now: Date) -> [Reset] {
        (resets[id] ?? []).filter { $0.left > 0 && $0.expiresAt.map { $0 > now } != false }
    }

    /// What is live of what the account was last told to stand at.
    private func live(_ id: String, now: Date) -> (windows: [Window], scoped: [Window], resets: [Reset]) {
        ((memory.usage[id] ?? []).filter { $0.resetsAt > now }, (scoped[id] ?? []).filter { $0.resetsAt > now }, held(by: id, now: now))
    }

    private func standing(_ account: Account, now: Date) -> Standing {
        let live = live(account.id, now: now)
        return Standing(account: account.id, windows: live.windows, scoped: live.scoped, resets: live.resets)
    }

    /// The reset `id` that the provider's account `label` holds.
    func reset(_ id: String, heldBy label: String, at provider: String) -> (account: Account, reset: Reset)? {
        guard let account = accounts.first(where: { $0.provider == provider && $0.label == label }),
              let reset = held(by: account.id, now: Date()).first(where: { $0.id == id }) else { return nil }
        return (account, reset)
    }

    /// How a pool whose accounts all refused a request for `model` answers it after all.
    enum Back {
        /// The account has spent no limit the request draws on.
        case open(Account)
        /// The reset brings the account back.
        case reset(Account, Reset)
    }

    /// For these accounts, as each now stands. A reset only where the user said to use resets for them,
    /// and never while the config cannot be read; its account is paused until the use is over.
    func back(among pool: [Account], model: String?, now: Date = Date()) -> Back? {
        let standings = pool.map { standing($0, now: now) }
        func account(_ id: String) -> Account? { pool.first { $0.id == id } }
        if standings.contains(where: { $0.spent(for: model).isEmpty }) {
            return memory.router.order(standings, conversation: nil, model: model, now: now).first.flatMap(account).map(Back.open)
        }
        guard usesResets, let pick = memory.router.refill(standings.filter { !paused.contains($0.account) }, model: model), let account = account(pick.account) else { return nil }
        paused.insert(account.id)
        return .reset(account, pick.reset)
    }

    /// A reset of the account's to use with no request waiting, on the same terms.
    func due(_ account: Account, now: Date = Date()) -> Reset? {
        guard usesResets, !paused.contains(account.id), let reset = memory.router.due(standing(account, now: now), now: now) else { return nil }
        paused.insert(account.id)
        return reset
    }

    private var usesResets: Bool { (try? storage.config())?.autoResets == true }

    /// A reset's use on the account is over. Resets are used on it unasked again where that went well or
    /// the provider refused in so many words; otherwise not until a person uses one there, or the relay restarts.
    func usedReset(on id: String, well: Bool) {
        if well { paused.remove(id) } else { paused.insert(id) }
    }

    /// The provider did not take the reset. It is not offered again until the account's resets are next read.
    func notTaken(_ reset: Reset, by id: String) {
        if let index = resets[id]?.firstIndex(where: { $0.id == reset.id }) { resets[id]?[index].usable = false }
    }

    /// The account answered a relayed request, reporting these windows.
    func answered(_ id: String, reporting windows: [Window]) {
        lastAnswered[id] = Date()
        record(windows, for: id)
    }

    private func record(_ windows: [Window], for id: String) {
        problems[id] = nil
        for window in windows {
            // A provider's answers and its usage endpoint round the same use a point apart, so within one
            // window a reading a point lower than the last says nothing new.
            if let kept = memory.usage[id]?.first(where: { $0.name == window.name }), kept.settled.resetsAt == window.settled.resetsAt,
               window.used < kept.used, kept.used - window.used < 0.015 { continue }
            memory.usage[id, default: []].removeAll { $0.name == window.name }
            memory.usage[id, default: []].append(window)
        }
        if !windows.isEmpty {
            remember()
            sample(id)
        }
    }

    /// A reading that says something new is a line of history. One that cannot be written is reported and
    /// tried again at the next reading.
    private func sample(_ id: String, now: Date = Date()) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        let windows = (memory.usage[id] ?? []).filter { $0.resetsAt > now }.map(\.settled).sorted { $0.resetsAt < $1.resetsAt }
        let parts = (scoped[id] ?? []).filter { $0.resetsAt > now }.map(\.settled)
        guard windows + parts != sampled[id] else { return }
        do {
            try storage.appendSample(Sample(at: now, provider: account.provider, account: account.label, windows: windows, scoped: parts.isEmpty ? nil : parts))
            sampled[id] = windows + parts
        } catch {
            FileHandle.standardError.write(Data("sluice: could not add to the history: \(error)\n".utf8))
        }
    }

    /// An answer that cost something is a line of history. One that cannot be written is reported and lost.
    func spent(_ spend: Spend, by id: String, for profile: String, folder: String?, conversation: String?, since asked: Date) {
        guard spend != Spend(), let account = accounts.first(where: { $0.id == id }) else { return }
        let now = Date()
        do {
            try storage.appendServed(Served(
                at: now, provider: account.provider, account: account.label, profile: profile, folder: folder, conversation: conversation,
                seconds: (now.timeIntervalSince(asked) * 10).rounded() / 10, spend: spend
            ))
        } catch {
            FileHandle.standardError.write(Data("sluice: could not add to the history: \(error)\n".utf8))
        }
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
    /// A renewal that fails is the account's problem until it next works.
    func fresh(_ id: String, using provider: any Provider) async throws -> Account {
        if let running = refreshing[id] { return try await running.value }
        guard let account = accounts.first(where: { $0.id == id }) else { throw ProviderError.signedOut }
        guard account.expiresAt < Date().addingTimeInterval(300) else { return account }
        let task = Task { try await provider.refresh(account) }
        refreshing[id] = task
        defer { refreshing[id] = nil }
        do {
            let renewed = try await task.value
            try save(renewed)
            return renewed
        } catch {
            problems[id] = "Could not renew its sign-in: \(error)"
            throw error
        }
    }
}
