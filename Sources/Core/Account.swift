import Foundation

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

/// What Sluice observed and would otherwise relearn after a restart.
struct Memory: Codable {
    /// By account.
    var accounts: [String: Known] = [:]
    var router = Router()
    /// By provider: how its own client last named itself.
    var clients: [String: String] = [:]

    init() {}

    /// A memory an older Sluice wrote names none of what is by account: the rest of it is still read.
    init(from decoder: any Decoder) throws {
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try keyed.decodeIfPresent([String: Known].self, forKey: .accounts) ?? [:]
        router = try keyed.decode(Router.self, forKey: .router)
        clients = try keyed.decodeIfPresent([String: String].self, forKey: .clients) ?? [:]
    }
}

/// An account as its provider last told of it, and what its week is seen to hold.
struct Known: Codable {
    var plan: Plan?
    var windows: [Window] = []
    /// The limits on a part of its use.
    var scoped: [Window] = []
    var resets: [Reset] = []
    var sizing = Sizing()
}

public struct AccountStatus: Codable, Sendable {
    public var provider: String
    public var label: String
    public var profile: String
    /// As its provider last told it.
    public var plan: Plan?
    public var windows: [Window]
    /// The limits on a part of its use, such as one model's own share of the week.
    public var scoped: [Window] = []
    /// The resets it holds, as its provider last told.
    public var resets: [Reset] = []
    public var warmConversations: Int
    /// When it last answered a relayed request, or finished answering one, since the relay started.
    public var lastAnswered: Date?
    /// How many requests it is at work on now: sent to it, and not yet answered to the end.
    public var streaming: Int
    /// Why it cannot serve, in the provider's or Sluice's words; nil when nothing is known to be wrong.
    public var problem: String?
    /// How much its week holds beside the other accounts of its pool. Where its provider's meter has a
    /// formula, the weighed tokens in a point of the week: as seen, or as its plan is taken to give until
    /// enough was seen. Otherwise its plan's multiple.
    public var size: Double
    /// How far the size seen varies from one rise of the week to the next, as a share of it; nil until
    /// one is seen. Wide for long, the provider counts otherwise than the formula weighs.
    public var spread: Double?
}

/// The accounts, what each provider last said about them, and where conversations are held.
actor Accounts {
    private let storage: Storage
    /// By provider, for those whose meter has one.
    private let formulas: [String: Formula]
    private var accounts: [Account]
    private var refreshing: [String: Task<Account, any Error>] = [:]
    private var memory: Memory
    /// By account, in this run of the relay.
    private var run: [String: Run] = [:]

    private struct Run {
        /// When it last answered a relayed request.
        var answered: Date?
        /// How many requests it is at work on now.
        var streaming = 0
        /// Why it cannot serve; nil when nothing is known to be wrong.
        var problem: String?
        /// When its usage was last told, and its resets last asked for.
        var usageAsked: Date?
        var resetsAsked: Date?
        /// What its windows read when its last line of history was written.
        var sampled: [Window]?
        /// No reset is used on it unasked: one is being used there now, or one was and it is not known
        /// to have gone well.
        var paused = false
    }

    init(storage: Storage, formulas: [String: Formula] = [:]) throws {
        self.storage = storage
        self.formulas = formulas
        accounts = try storage.loadAccounts()
        // What was observed is relearned from the next answers, so a memory that cannot be read is said and started afresh.
        do { memory = try storage.loadMemory() } catch {
            log("starting without what was observed: \(error)", kept: true)
            memory = Memory()
        }
    }

    func status() throws -> [AccountStatus] {
        let config = try storage.config(), now = Date()
        return accounts.map {
            let live = live($0.id, now: now), plan = memory.accounts[$0.id]?.plan, sizing = memory.accounts[$0.id]?.sizing
            return AccountStatus(
                provider: $0.provider, label: $0.label, profile: config.profile(ofAccount: $0.label), plan: plan,
                windows: live.windows, scoped: live.scoped, resets: live.resets,
                warmConversations: memory.router.warmConversations(on: $0.id, now: now), lastAnswered: run[$0.id]?.answered, streaming: run[$0.id]?.streaming ?? 0, problem: run[$0.id]?.problem,
                size: sizing?.size ?? formulas[$0.provider]?.size(of: plan) ?? Double(plan?.multiple ?? 1), spread: sizing?.spread
            )
        }
    }

    /// Forgets a sign-in, and what was observed about it. False when there is no such account.
    func remove(provider: String, label: String) throws -> Bool {
        guard let gone = accounts.first(where: { $0.provider == provider && $0.label == label }) else { return false }
        let next = try storage.loadAccounts().filter { $0.id != gone.id }
        try storage.storeAccounts(next)
        accounts = next
        (memory.accounts[gone.id], run[gone.id]) = (nil, nil)
        remember()
        return true
    }

    /// What is stored is what is changed: during a handover another copy saves there too.
    func save(_ account: Account) throws {
        var next = try storage.loadAccounts()
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
        run[id, default: Run()].problem = problem
    }

    /// What the provider said about the account when asked.
    func record(_ usage: Usage, for id: String) {
        (memory.accounts[id, default: Known()].plan, memory.accounts[id, default: Known()].scoped) = (usage.plan, usage.scoped)
        run[id, default: Run()].usageAsked = Date()
        record(usage.windows, for: id)
        remember()
    }

    /// Whether the account's usage was last told longer ago than `age`.
    func owesUsage(_ id: String, after age: TimeInterval, now: Date = Date()) -> Bool {
        run[id]?.usageAsked.map { now.timeIntervalSince($0) >= age } ?? true
    }

    /// A provider's own client named itself on a request. True when that is news: none was known, or
    /// this is a later version. Two versions running side by side are then one name, not news at each turn.
    func seen(client: String, of provider: String) -> Bool {
        guard memory.clients[provider].map({ client.compare($0, options: .numeric) == .orderedDescending }) ?? true else { return false }
        memory.clients[provider] = client
        remember()
        return true
    }

    func client(of provider: String) -> String? { memory.clients[provider] }

    /// Whether the account's resets were last asked for longer ago than `age`, or a reset its provider
    /// would not take until some time has reached that time.
    func owesResets(_ id: String, after age: TimeInterval, now: Date = Date()) -> Bool {
        guard let asked = run[id]?.resetsAsked else { return true }
        return now.timeIntervalSince(asked) >= age || (memory.accounts[id]?.resets ?? []).contains { !$0.usable && $0.usableAfter.map { $0 <= now } == true }
    }

    func record(resets held: [Reset], for id: String) {
        memory.accounts[id, default: Known()].resets = held
        run[id, default: Run()].resetsAsked = Date()
        remember()
    }

    /// The account's resets were asked for and not told. What was known stands until they are next due.
    func resetsNotTold(_ id: String) {
        run[id, default: Run()].resetsAsked = Date()
    }

    /// What is live of what the account was last told to stand at: the windows by when they reset, and
    /// the resets it still holds.
    private func live(_ id: String, now: Date) -> (windows: [Window], scoped: [Window], resets: [Reset]) {
        let known = memory.accounts[id] ?? Known()
        return (
            known.windows.filter { $0.resetsAt > now }.sorted { $0.resetsAt < $1.resetsAt }, known.scoped.filter { $0.resetsAt > now },
            known.resets.filter { $0.left > 0 && $0.expiresAt.map { $0 > now } != false }
        )
    }

    private func standing(_ account: Account, now: Date) -> Standing {
        let live = live(account.id, now: now)
        return Standing(account: account.id, windows: live.windows, scoped: live.scoped, resets: live.resets)
    }

    /// The reset `id` that the provider's account `label` holds.
    func reset(_ id: String, heldBy label: String, at provider: String) -> (account: Account, reset: Reset)? {
        guard let account = accounts.first(where: { $0.provider == provider && $0.label == label }),
              let reset = live(account.id, now: Date()).resets.first(where: { $0.id == id }) else { return nil }
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
        guard usesResets, let pick = memory.router.refill(standings.filter { run[$0.account]?.paused != true }, model: model), let account = account(pick.account) else { return nil }
        run[account.id, default: Run()].paused = true
        return .reset(account, pick.reset)
    }

    /// A reset of the account's to use with no request waiting, on the same terms.
    func due(_ account: Account, now: Date = Date()) -> Reset? {
        guard usesResets, run[account.id]?.paused != true, let reset = memory.router.due(standing(account, now: now), now: now) else { return nil }
        run[account.id, default: Run()].paused = true
        return reset
    }

    private var usesResets: Bool { (try? storage.config())?.autoResets == true }

    /// A reset's use on the account is over. Resets are used on it unasked again where that went well or
    /// the provider refused in so many words; otherwise not until a person uses one there, or the relay restarts.
    func usedReset(on id: String, well: Bool) {
        run[id, default: Run()].paused = !well
    }

    /// The provider did not take the reset. It is not offered again until the account's resets are next read.
    func notTaken(_ reset: Reset, by id: String) {
        if let index = memory.accounts[id]?.resets.firstIndex(where: { $0.id == reset.id }) { memory.accounts[id]?.resets[index].usable = false }
    }

    /// The account answered a relayed request, reporting these windows.
    func answered(_ id: String, reporting windows: [Window]) {
        run[id, default: Run()].answered = Date()
        record(windows, for: id)
    }

    /// A request was sent to the account, or with -1 its answer came to its end.
    func streams(_ id: String, _ change: Int) {
        run[id, default: Run()].streaming += change
        // It was at work until now.
        if change < 0 { run[id]?.answered = Date() }
    }

    private func record(_ windows: [Window], for id: String) {
        run[id, default: Run()].problem = nil
        for window in windows {
            // A provider's answers and its usage endpoint round the same use a point apart, so within one
            // window a reading a point lower than the last says nothing new.
            if let kept = memory.accounts[id]?.windows.first(where: { $0.name == window.name }), kept.settled.resetsAt == window.settled.resetsAt,
               window.used < kept.used, kept.used - window.used < 0.015 { continue }
            memory.accounts[id, default: Known()].windows.removeAll { $0.name == window.name }
            memory.accounts[id, default: Known()].windows.append(window)
        }
        if !windows.isEmpty {
            if let budget = live(id, now: Date()).windows.budget, accounts.contains(where: { $0.id == id && formulas[$0.provider] != nil }) {
                memory.accounts[id]?.sizing.read(budget)
            }
            remember()
            sample(id)
        }
    }

    /// A reading that says something new is a line of history. One that cannot be written is logged and
    /// tried again at the next reading.
    private func sample(_ id: String, now: Date = Date()) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        let live = live(id, now: now), windows = live.windows.map(\.settled), parts = live.scoped.map(\.settled)
        guard windows + parts != run[id]?.sampled else { return }
        do {
            try storage.appendSample(Sample(at: now, provider: account.provider, account: account.label, windows: windows, scoped: parts.isEmpty ? nil : parts))
            run[id, default: Run()].sampled = windows + parts
        } catch {
            log("could not add to the history: \(error)", kept: true)
        }
    }

    /// An answer that cost something is a line of history. One that cannot be written is logged and lost.
    func spent(_ spend: Spend, by id: String, for profile: String, folder: String?, conversation: String?, since asked: Date) {
        guard spend != Spend(), let account = accounts.first(where: { $0.id == id }) else { return }
        if let formula = formulas[account.provider] { memory.accounts[id]?.sizing.answered(weighing: formula.weigh(spend)) }
        let now = Date()
        do {
            try storage.appendServed(Served(
                at: now, provider: account.provider, account: account.label, profile: profile, folder: folder, conversation: conversation,
                seconds: (now.timeIntervalSince(asked) * 10).rounded() / 10, spend: spend
            ))
        } catch {
            log("could not add to the history: \(error)", kept: true)
        }
    }

    func served(_ conversation: String, by id: String, cacheLifetime: TimeInterval) {
        memory.router.served(conversation, by: id, cacheLifetime: cacheLifetime, now: Date())
        remember()
    }

    /// Memory is relearned from the next responses, so a failed write costs only that and is logged, not fatal.
    private func remember() {
        do { try storage.storeMemory(memory) } catch {
            log("could not save what was observed: \(error)", kept: true)
        }
    }

    /// The account with a token good for at least five more minutes, renewed once however many requests ask.
    /// A renewal that fails is the account's problem until it next works.
    func fresh(_ id: String, using provider: any Provider) async throws -> Account {
        if let running = refreshing[id] { return try await running.value }
        func known() throws -> Account {
            guard let account = accounts.first(where: { $0.id == id }) else { throw ProviderError.signedOut }
            return account
        }
        var account = try known()
        guard account.expiresAt < Date().addingTimeInterval(300) else { return account }
        // During a handover another copy may have renewed it, and a sign-in is renewed with what the last renewal gave.
        accounts = try storage.loadAccounts()
        account = try known()
        guard account.expiresAt < Date().addingTimeInterval(300) else { return account }
        let task = Task { try await provider.refresh(account) }
        refreshing[id] = task
        defer { refreshing[id] = nil }
        do {
            let renewed = try await task.value
            // Removed while it was renewing, it is not brought back.
            guard accounts.contains(where: { $0.id == id }) else { throw ProviderError.signedOut }
            try save(renewed)
            return renewed
        } catch {
            run[id, default: Run()].problem = "Could not renew its sign-in: \(error)"
            throw error
        }
    }
}
