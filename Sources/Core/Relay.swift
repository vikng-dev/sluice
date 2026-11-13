import Foundation

/// A local address, read as a route. The grammar:
/// `/login/<provider>`, `/callback?code=…&state=…`, `/status`, and
/// `/<provider>[/pin/<account>]/<the provider's own path and query>`.
enum Route: Equatable {
    case login(provider: String)
    case callback(code: String, state: String)
    case status
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
        case ("login", _):
            rest = rest.dropFirst()
            let provider = String(segment())
            guard !provider.isEmpty, rest.isEmpty else { return nil }
            self = .login(provider: provider)
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

    public init(providers: [any Provider], vault: Vault, port: UInt16) throws {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        accounts = try Accounts(vault: vault)
        redirectURI = "http://localhost:\(port)/callback"
    }

    public func handle(_ request: HTTPRequest, _ writer: ResponseWriter) async throws {
        switch Route(target: request.target) {
        case nil:
            try await writer.send(404, text: "sluice: no such address")
        case .status:
            let rows = await accounts.all.map { ["provider": $0.provider, "label": $0.label] }
            try await writer.send(200, contentType: "application/json", text: String(decoding: JSONEncoder().encode(rows), as: UTF8.self))
        case .login(let id):
            guard let provider = providers[id] else { return try await writer.send(404, text: "sluice: no provider \(id)") }
            let (state, challenge) = await signIns.begin(provider: id)
            try await writer.redirect(to: provider.authorizeURL(redirectURI: redirectURI, state: state, challenge: challenge))
        case .callback(let code, let state):
            guard let pending = await signIns.finish(state: state), let provider = providers[pending.provider] else {
                return try await writer.send(400, text: "sluice: this sign-in was not started here, or was already used")
            }
            do {
                let account = try await provider.signIn(code: code, state: state, redirectURI: redirectURI, verifier: pending.verifier)
                try await accounts.save(account)
                try await writer.send(200, text: "Signed in to \(provider.id) as \(account.label). You can close this tab.")
            } catch {
                try await writer.send(502, text: "sluice: sign-in failed: \(error)")
            }
        case .relay(let id, let pin, let target):
            guard let provider = providers[id] else { return try await writer.send(404, text: "sluice: no provider \(id)") }
            guard let picked = await accounts.pick(provider: id, pin: pin) else {
                return try await writer.send(503, text: "sluice: no \(pin ?? id) account is signed in; open http://localhost:\(redirectURI.split(separator: ":")[2].prefix { $0 != "/" })/login/\(id)")
            }
            let account: Account
            do {
                account = try await accounts.fresh(picked.id, using: provider)
            } catch {
                return try await writer.send(502, text: "sluice: could not renew \(picked.label): \(error)")
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
                return try await writer.send(502, text: "sluice: could not reach \(provider.id): \(error.localizedDescription)")
            }
            FileHandle.standardError.write(Data("\(id) \(account.label) \(request.method) \(target.prefix { $0 != "?" }) \(response.statusCode)\n".utf8))
            let headers = response.allHeaderFields.compactMap { name, value in (name as? String).map { ($0, "\(value)") } }
            try await writer.send(response.statusCode, headers: headers, body: body)
        }
    }
}
