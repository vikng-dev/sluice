import Foundation
import os

/// A local address, read as a route. The grammar:
/// `/login/<provider>`, `/callback?code=…&state=…`, `/status`, `/accounts/<provider>/<account>[?reset=<id>]`, and
/// `/<provider>[/pin/<account>]/<the provider's own path and query>`. The caller's folder decides the
/// profile (see `Config.profile`); a pin names one account of that profile's pool.
enum Route: Equatable {
    case login(provider: String, profile: String?)
    case callback(code: String, state: String)
    case status
    case account(provider: String, label: String)
    case relay(provider: String, pin: String?, target: String)

    init?(target: String) {
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let query = parts.count > 1 ? "?" + parts[1] : ""
        var rest = parts[0].dropFirst()
        func segment() -> Substring {
            let part = rest.prefix { $0 != "/" }
            rest = rest.dropFirst(part.count)
            return part
        }
        let first = String(segment())
        switch (first, rest) {
        case ("", _): return nil
        case ("status", ""): self = .status
        case ("callback", ""):
            guard let code = Self.query("code", in: target), let state = Self.query("state", in: target) else { return nil }
            self = .callback(code: code, state: state)
        case ("accounts", _):
            rest = rest.dropFirst()
            let provider = String(segment())
            rest = rest.dropFirst()
            guard !provider.isEmpty, let label = String(rest).removingPercentEncoding, !label.isEmpty, !label.contains("/") else { return nil }
            self = .account(provider: provider, label: label)
        case ("login", _):
            rest = rest.dropFirst()
            let provider = String(segment())
            guard !provider.isEmpty, rest.isEmpty else { return nil }
            self = .login(provider: provider, profile: Self.query("profile", in: target))
        default:
            var pin: String?
            if rest.hasPrefix("/pin/") {
                rest = rest.dropFirst(5)
                guard let name = segment().removingPercentEncoding, !name.isEmpty else { return nil }
                pin = name
            }
            self = .relay(provider: first, pin: pin, target: (rest.isEmpty ? "/" : String(rest)) + query)
        }
    }

    static func query(_ name: String, in target: String) -> String? {
        URLComponents(string: target)?.queryItems?.first { $0.name == name }?.value
    }
}

public final class Relay: Sendable {
    private let providers: [String: any Provider]
    private let accounts: Accounts
    private let storage: Storage
    private let signIns = SignIns()
    private let refills = Refills()
    private let upstream = Upstream()
    private let redirectURI: String

    public init(providers: [any Provider], storage: Storage, port: UInt16) throws {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        accounts = try Accounts(storage: storage)
        self.storage = storage
        redirectURI = "http://localhost:\(port)/callback"
    }

    public func status() async throws -> [AccountStatus] {
        try await accounts.status()
    }

    /// Asks each provider for each account's usage, once. An account that cannot sign in is marked;
    /// a usage address that does not answer says nothing about the account, so that is only logged.
    public func checkUsage() async {
        for account in await accounts.all {
            // An account is only ever stored under a provider that signed it in.
            let provider = providers[account.provider]!
            // What is not read now is not acted on: a reset is never used on what an account stood at before.
            guard let fresh = try? await accounts.fresh(account.id, using: provider), await checkUsage(of: fresh, at: provider) else { continue }
            if await accounts.owesResets(account.id) { await checkResets(of: fresh, at: provider) }
            if let reset = await accounts.due(account) { try? await use(reset, of: fresh, at: provider) }
        }
    }

    /// Asks the provider for the account's usage. False when it was not told.
    @discardableResult
    private func checkUsage(of account: Account, at provider: any Provider) async -> Bool {
        do {
            try await accounts.record(provider.usage(of: account), for: account.id)
            return true
        } catch ProviderError.signedOut {
            await accounts.failed(account.id, "Signed out. Run: sluice login \(account.provider)")
        } catch {
            log("\(account.provider) \(account.label) usage check failed: \(error)")
        }
        return false
    }

    /// Asks which resets an account holds. An answer that fails is logged and asked again in an hour;
    /// a provider that cannot be asked yet is asked at the next check.
    private func checkResets(of account: Account, at provider: any Provider) async {
        do {
            guard let held = try await provider.resets(of: account, as: accounts.client(of: provider.id)) else { return }
            await accounts.record(resets: held, for: account.id)
        } catch {
            await accounts.resetsNotTold(account.id)
            log("\(account.provider) \(account.label) resets check failed: \(error)")
        }
    }

    /// Uses the reset `id` that a person picked on an account. `ResetRefused` says it was not used; any
    /// other error leaves that unknown.
    public func use(reset id: String, provider: String, account label: String) async throws {
        guard let at = providers[provider], let (held, reset) = await accounts.reset(id, heldBy: label, at: provider) else {
            throw ResetRefused("the \(provider) account \(label) holds no reset \(id)")
        }
        let account: Account
        do { account = try await accounts.fresh(held.id, using: at) } catch { throw ResetRefused("\(label) could not renew its sign-in: \(error)") }
        try await use(reset, of: account, at: at)
    }

    /// Spends a reset an account holds. Whatever the provider answers, it is then asked how the account
    /// stands: its usage and the resets it holds.
    private func use(_ reset: Reset, of account: Account, at provider: any Provider) async throws {
        var failure: (any Error)?
        do { try await provider.use(reset, of: account, as: accounts.client(of: provider.id)) } catch { failure = error }
        await checkUsage(of: account, at: provider)
        await checkResets(of: account, at: provider)
        await accounts.usedReset(on: account.id, well: failure == nil || failure is ResetRefused)
        guard let failure else { return log("\(provider.id) \(account.label) used reset \(reset.id)") }
        await accounts.notTaken(reset, by: account.id)
        log("\(provider.id) \(account.label) reset \(reset.id) \(failure is ResetRefused ? "was not used" : "may have been used"): \(failure)")
        throw failure
    }

    /// Every one of these accounts refused. The account to send the request to again: one that is back by
    /// itself, or one a reset was just used on. What is known may be stale, so each is asked how it stands,
    /// and only those that answer are considered. A reset its provider refused in so many words was not
    /// spent, so the next is tried. A use whose outcome is not known, or that did not bring the account
    /// back, ends it and stops resets being used on that account unasked.
    private func refill(_ pool: [Account], for model: String?, at provider: any Provider) async -> Account? {
        var read: [Account] = []
        for account in pool {
            if let fresh = try? await accounts.fresh(account.id, using: provider), await checkUsage(of: fresh, at: provider) { read.append(fresh) }
        }
        while let back = await accounts.back(among: read, model: model) {
            switch back {
            case .open(let account): return account
            case .reset(let account, let reset):
                do { try await use(reset, of: account, at: provider) } catch is ResetRefused { continue } catch {}
                if case .open = await accounts.back(among: [account], model: model) { return account }
                await accounts.usedReset(on: account.id, well: false)
                log("\(provider.id) \(account.label) is not back after reset \(reset.id): no more are used on it unasked")
                return nil
            }
        }
        return nil
    }

    public func handle(_ request: HTTPRequest, _ writer: ResponseWriter) async throws {
        switch Route(target: request.target) {
        case nil:
            try await writer.send(404, text: "sluice: no such address")
        case .status:
            do {
                try await writer.send(200, contentType: "application/json", text: String(decoding: JSONEncoder().encode(status()), as: UTF8.self))
            } catch {
                try await writer.send(500, text: "sluice: \(error)")
            }
        case .account(let provider, let label):
            // By address an account is forgotten, or has a reset it holds used.
            if request.method == "POST", let id = Route.query("reset", in: request.target) {
                do {
                    try await use(reset: id, provider: provider, account: label)
                    return try await writer.send(200, text: "used")
                } catch let refusal as ResetRefused {
                    return try await writer.send(409, text: "sluice: the reset was not used: \(refusal)")
                } catch {
                    return try await writer.send(502, text: "sluice: the reset may have been used: \(error)")
                }
            }
            guard request.method == "DELETE" else { return try await writer.send(405, text: "sluice: an account is removed with DELETE, and a reset used with POST and ?reset=<id>") }
            do {
                guard try await accounts.remove(provider: provider, label: label) else { return try await writer.send(404, text: "sluice: no \(provider) account \(label)") }
                log("\(provider) \(label) removed")
                try await writer.send(200, text: "removed")
            } catch {
                try await writer.send(500, text: "sluice: \(error)")
            }
        case .login(let id, let profile):
            guard let provider = providers[id] else { return try await writer.send(404, text: "sluice: no provider \(id)") }
            do {
                if let profile, try !storage.config().names.contains(profile) { return try await writer.send(404, text: "sluice: no profile named \(profile)") }
            } catch {
                return try await writer.send(500, text: "sluice: \(error)")
            }
            if let port = provider.redirect?.port {
                do {
                    try await signIns.listen(on: port) {
                        let server = try Server(port: UInt16(port)) { [self] request, writer in
                            guard let code = Route.query("code", in: request.target), let state = Route.query("state", in: request.target) else { return try await writer.send(400, text: "sluice: the sign-in came back without a code") }
                            try await finishSignIn(code: code, state: state, writer)
                            await signIns.close(port: port)
                        }
                        try await server.start()
                        return server
                    }
                } catch {
                    return try await writer.send(500, text: "sluice: \(id) signs in on port \(port), which is in use: \(error.localizedDescription)")
                }
            }
            let (state, challenge) = await signIns.begin(provider: id, profile: profile)
            try await writer.redirect(to: provider.authorizeURL(redirectURI: provider.redirect?.absoluteString ?? redirectURI, state: state, challenge: challenge))
        case .callback(let code, let state):
            try await finishSignIn(code: code, state: state, writer)
        case .relay(let id, let pin, let target):
            guard let provider = providers[id] else { return try await writer.send(404, text: "sluice: no provider \(id)") }
            let conversation = provider.conversation(of: request), model = provider.model(of: request), asked = Date()
            // Under a new name the provider may tell of resets it would not tell of before.
            if let client = request.header("User-Agent").flatMap(provider.clientName), await accounts.seen(client: client, of: id) {
                Task {
                    for account in await accounts.all where account.provider == id {
                        if let fresh = try? await accounts.fresh(account.id, using: provider) { await checkResets(of: fresh, at: provider) }
                    }
                }
            }
            let candidates: [Account], profile: String, pool: [Account]
            do {
                (profile, candidates, pool) = try await accounts.candidates(provider: id, pin: pin, folder: request.callerFolder, conversation: conversation?.id, model: model)
            } catch {
                return try await writer.send(500, text: "sluice: \(error)")
            }
            // Work whose folder is not known is taken for the default profile's.
            if request.callerFolder == nil { Self.logger.notice("a \(id, privacy: .public) request came from a program whose folder could not be read") }
            guard !candidates.isEmpty else {
                let wanted = pin.map { "the \(provider.name) account \($0)" } ?? "a \(provider.name) account"
                return try await writer.send(403, text: "sluice: profile \(profile) does not have \(wanted), and work is only paid by its own profile's accounts. See: sluice status")
            }
            var queue = candidates[...], refilled = false
            while let candidate = queue.popFirst() {
                let isLast = queue.isEmpty
                let account: Account
                do {
                    account = try await accounts.fresh(candidate.id, using: provider)
                } catch {
                    log("\(id) \(candidate.label) could not renew: \(error)")
                    if isLast { return try await writer.send(502, text: "sluice: could not renew \(candidate.label): \(error)") }
                    continue
                }
                var outgoing = request
                outgoing.target = target
                provider.prepare(&outgoing, for: account)
                // `target` begins with "/" and the upstream is a fixed, valid URL.
                var call = URLRequest(url: URL(string: provider.upstream.absoluteString + target)!)
                call.httpMethod = outgoing.method
                for (name, value) in outgoing.headers where !Hop.request.contains(name.lowercased()) { call.setValue(value, forHTTPHeaderField: name) }
                if !outgoing.body.isEmpty { call.httpBody = outgoing.body }
                let response: HTTPURLResponse, body: AsyncThrowingStream<Data, any Error>
                do {
                    (response, body) = try await upstream.send(call)
                } catch {
                    // Every account shares the upstream host, so an unreachable one is not retried on another.
                    return try await writer.send(502, text: "sluice: could not reach \(provider.id): \(error.localizedDescription)")
                }
                let headers = response.allHeaderFields.compactMap { name, value in (name as? String).map { ($0, "\(value)") } }
                let reading = provider.reading(status: response.statusCode, headers: Dictionary(headers.map { ($0.0.lowercased(), $0.1) }) { $1 })
                await accounts.answered(account.id, reporting: reading.windows)
                log("\(id) \(account.label) \(request.method) \(target.prefix { $0 != "?" }) \(response.statusCode)\(reading.refused ? " spent" : "")")
                // The whole pool is out. An account that is back after all, or that a reset the pool holds
                // brings back where the user said to use them, is sent the request, once.
                if reading.refused, isLast, !refilled {
                    let back = await refills.one(for: "\(profile)/\(id)/\(pin ?? "")", refusedBy: account.id) { [self] in await refill(pool, for: model, at: provider) }
                    if let back {
                        refilled = true
                        queue = [back]
                        continue
                    }
                } else if reading.refused, !reading.windows.contains(where: { $0.used >= 1 }) {
                    // It refused over a limit its answers do not report, such as one model's own: it is asked
                    // how it stands, so that the next such request is not sent to it.
                    Task { await checkUsage(of: account, at: provider) }
                }
                if reading.refused, !isLast { continue }
                if let conversation, !reading.refused {
                    await accounts.served(conversation.id, by: account.id, cacheLifetime: conversation.cacheLifetime)
                }
                let accounts = accounts, folder = request.callerFolder
                let counted = Metered(base: body, count: provider.count) { spend in
                    Task { await accounts.spent(spend, by: account.id, for: profile, folder: folder, conversation: conversation?.id, since: asked) }
                }
                return try await writer.send(response.statusCode, headers: headers, body: counted)
            }
        }
    }

    /// The refills under way and just done, so that requests refused together use one reset between them,
    /// and a pool that stays out is not asked how it stands at every request.
    private actor Refills {
        private var running: [String: Task<Account?, Never>] = [:]
        private var last: [String: (at: Date, back: Account?)] = [:]

        /// The account that is back for the pool. For five minutes a refill's answer stands, except for a
        /// request refused by the very account it brought back: for that one the pool is asked again.
        func one(for pool: String, refusedBy account: String, _ refill: @escaping @Sendable () async -> Account?) async -> Account? {
            if let task = running[pool] { return await task.value }
            if let last = last[pool], Date().timeIntervalSince(last.at) < 300, last.back?.id != account { return last.back }
            let task = Task { await refill() }
            running[pool] = task
            let back = await task.value
            running[pool] = nil
            last[pool] = (Date(), back)
            return back
        }
    }

    private func finishSignIn(code: String, state: String, _ writer: ResponseWriter) async throws {
        guard let pending = await signIns.finish(state: state), let provider = providers[pending.provider] else {
            return try await writer.send(400, text: "sluice: this sign-in was not started here, or was already used")
        }
        do {
            let account = try await provider.signIn(code: code, state: state, redirectURI: provider.redirect?.absoluteString ?? redirectURI, verifier: pending.verifier)
            try await accounts.save(account)
            if let profile = pending.profile { try storage.change { try $0.move(account: account.label, to: profile) } }
            try await writer.send(200, text: "Signed in to \(provider.name) as \(account.label)\(pending.profile.map { ", for profile \($0)" } ?? ""). You can close this tab.")
        } catch {
            try await writer.send(502, text: "sluice: sign-in failed: \(error)")
        }
    }

    /// One line per relayed request, in the system log: `log stream --predicate 'subsystem == "dev.vikng.sluice"'`.
    private func log(_ line: String) {
        Self.logger.info("\(line, privacy: .public)")
    }

    private static let logger = Logger(subsystem: Sluice.id, category: "relay")
}
