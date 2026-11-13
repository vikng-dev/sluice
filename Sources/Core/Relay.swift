import Foundation
import os

/// A local address, read as a route. The grammar:
/// `/login/<provider>`, `/callback?code=…&state=…`, `/status`, `/accounts/<provider>/<account>`, and
/// `/<provider>[/pin/<account>]/<the provider's own path and query>`. Without a pin in the address,
/// the caller's folder decides the profile: see `Config.profile`.
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
            let items = URLComponents(string: target)?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            guard let code = value("code"), let state = value("state") else { return nil }
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
            self = .login(provider: provider, profile: URLComponents(string: target)?.queryItems?.first { $0.name == "profile" }?.value)
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
}

public final class Relay: Sendable {
    private let providers: [String: any Provider]
    private let accounts: Accounts
    private let signIns = SignIns()
    private let upstream = Upstream()
    private let redirectURI: String

    public init(providers: [any Provider], storage: Storage, port: UInt16) throws {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        accounts = try Accounts(storage: storage)
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
            let fresh: Account
            do {
                fresh = try await accounts.fresh(account.id, using: provider)
            } catch {
                await accounts.failed(account.id, "Could not renew its sign-in: \(error)")
                continue
            }
            do {
                try await accounts.record(provider.usage(of: fresh), for: account.id)
            } catch ProviderError.signedOut {
                await accounts.failed(account.id, "Signed out. Run: sluice login \(account.provider)")
            } catch {
                log("\(account.provider) \(account.label) usage check failed: \(error)")
            }
        }
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
            // The one thing asked of an account by address is to forget it.
            guard request.method == "DELETE" else { return try await writer.send(405, text: "sluice: an account is removed with DELETE") }
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
                if let profile, try await !accounts.profiles().contains(profile) { return try await writer.send(404, text: "sluice: no profile named \(profile)") }
            } catch {
                return try await writer.send(500, text: "sluice: \(error)")
            }
            if let port = provider.redirect?.port {
                do {
                    try await signIns.listen(on: port) {
                        let server = try Server(port: UInt16(port)) { [self] request, writer in
                            let items = URLComponents(string: request.target)?.queryItems ?? []
                            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
                            guard let code = value("code"), let state = value("state") else { return try await writer.send(400, text: "sluice: the sign-in came back without a code") }
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
            let conversation = provider.conversation(of: request)
            let candidates: [Account], profile: String
            do {
                (profile, candidates) = try await accounts.candidates(provider: id, pin: pin, folder: request.callerFolder, conversation: conversation?.id)
            } catch {
                return try await writer.send(500, text: "sluice: \(error)")
            }
            // Work whose folder is not known is taken for the default profile's.
            if request.callerFolder == nil { Self.logger.notice("a \(id, privacy: .public) request came from a program whose folder could not be read") }
            guard !candidates.isEmpty else {
                let wanted = pin.map { "the \(provider.name) account \($0)" } ?? "a \(provider.name) account"
                return try await writer.send(403, text: "sluice: profile \(profile) does not have \(wanted), and work is only paid by its own profile's accounts. See: sluice status")
            }
            for (index, candidate) in candidates.enumerated() {
                let isLast = index == candidates.count - 1
                let account: Account
                do {
                    account = try await accounts.fresh(candidate.id, using: provider)
                } catch {
                    log("\(id) \(candidate.label) could not renew: \(error)")
                    await accounts.failed(candidate.id, "Could not renew its sign-in: \(error)")
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
                if reading.refused, !isLast { continue }
                if let conversation, !reading.refused {
                    await accounts.served(conversation.id, by: account.id, cacheLifetime: conversation.cacheLifetime)
                }
                return try await writer.send(response.statusCode, headers: headers, body: body)
            }
        }
    }

    private func finishSignIn(code: String, state: String, _ writer: ResponseWriter) async throws {
        guard let pending = await signIns.finish(state: state), let provider = providers[pending.provider] else {
            return try await writer.send(400, text: "sluice: this sign-in was not started here, or was already used")
        }
        do {
            let account = try await provider.signIn(code: code, state: state, redirectURI: provider.redirect?.absoluteString ?? redirectURI, verifier: pending.verifier)
            try await accounts.save(account)
            if let profile = pending.profile { try await accounts.move(account.label, to: profile) }
            try await writer.send(200, text: "Signed in to \(provider.name) as \(account.label)\(pending.profile.map { ", for profile \($0)" } ?? ""). You can close this tab.")
        } catch {
            try await writer.send(502, text: "sluice: sign-in failed: \(error)")
        }
    }

    /// One line per relayed request, in the system log: `log stream --predicate 'subsystem == "dev.vikng.sluice"'`.
    private func log(_ line: String) {
        Self.logger.info("\(line, privacy: .public)")
    }

    private static let logger = Logger(subsystem: "dev.vikng.sluice", category: "relay")
}
