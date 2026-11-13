import Foundation
import SluiceCore

/// ChatGPT subscriptions, as the Codex CLI reaches them. Wire facts: docs/wire.md.
public struct Codex: Provider {
    public let id = "codex"
    public let client = "codex"
    public let upstream = URL(string: "https://chatgpt.com/backend-api/codex")!
    /// The Codex CLI's OAuth client accepts only this address.
    public let redirect: URL? = URL(string: "http://localhost:1455/auth/callback")

    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let authorize = URL(string: "https://auth.openai.com/oauth/authorize")!
    static let token = URL(string: "https://auth.openai.com/oauth/token")!

    public init() {}

    /// A model provider entry passed as config overrides, so the user's own config file is untouched.
    /// They go last, where every subcommand accepts them; ahead of a subcommand they are dropped
    /// whenever the subcommand has overrides of its own. A bare `--` ends the options, so they go before it.
    public func pointing(_ arguments: [String], at address: String) -> (environment: [String: String], arguments: [String]) {
        let overrides = ["-c", #"model_provider="sluice""#, "-c", #"model_providers.sluice={name="sluice",base_url="\#(address)",wire_api="responses"}"#]
        let end = arguments.firstIndex(of: "--") ?? arguments.endIndex
        return ([:], arguments[..<end] + overrides + arguments[end...])
    }

    public func authorizeURL(redirectURI: String, state: String, challenge: String) -> URL {
        var components = URLComponents(url: Self.authorize, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            "response_type": "code", "client_id": Self.clientID, "redirect_uri": redirectURI,
            "scope": "openid profile email offline_access", "code_challenge": challenge, "code_challenge_method": "S256",
            "state": state, "codex_cli_simplified_flow": "true", "id_token_add_organizations": "true",
        ].map(URLQueryItem.init)
        return components.url!
    }

    public func signIn(code: String, state: String, redirectURI: String, verifier: String) async throws -> Account {
        let grant = try await grant(["grant_type": "authorization_code", "client_id": Self.clientID, "code": code, "code_verifier": verifier, "redirect_uri": redirectURI])
        guard let refreshToken = grant.refresh_token,
              let subject = (Self.claims(grant.access_token)?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String,
              let email = grant.id_token.flatMap(Self.claims)?["email"] as? String,
              let expiresAt = Self.expiry(grant.access_token)
        else { throw ProviderError.invalidResponse }
        return Account(provider: id, subject: subject, organization: nil, label: email, accessToken: grant.access_token, refreshToken: refreshToken, expiresAt: expiresAt)
    }

    public func refresh(_ account: Account) async throws -> Account {
        let grant = try await grant(["grant_type": "refresh_token", "refresh_token": account.refreshToken, "client_id": Self.clientID])
        guard let expiresAt = Self.expiry(grant.access_token) else { throw ProviderError.invalidResponse }
        var renewed = account
        renewed.accessToken = grant.access_token
        // The refresh token rotates on most renewals; one that sends none leaves the old one valid.
        renewed.refreshToken = grant.refresh_token ?? account.refreshToken
        renewed.expiresAt = expiresAt
        return renewed
    }

    public func prepare(_ request: inout HTTPRequest, for account: Account) {
        request.setHeader("Authorization", "Bearer \(account.accessToken)")
        request.setHeader("chatgpt-account-id", account.subject)
    }

    public func conversation(of request: HTTPRequest) -> (id: String, cacheLifetime: TimeInterval)? {
        request.header("session-id").map { ($0, 1800) }
    }

    public func reading(status: Int, headers: [String: String]) -> Reading {
        let windows = ["primary", "secondary"].compactMap { slot -> Window? in
            func field(_ name: String) -> Double? { headers["x-codex-\(slot)-\(name)"].flatMap(Double.init) }
            // An unused slot reports a zero-minute window with no reset.
            guard let minutes = field("window-minutes"), minutes > 0, let used = field("used-percent"), let reset = field("reset-at") else { return nil }
            let name = switch minutes { case 300: "5h"; case 10080: "7d"; default: "\(Int(minutes))m" }
            return Window(name: name, used: used / 100, resetsAt: Date(timeIntervalSince1970: reset))
        }
        return Reading(windows: windows, refused: status == 429)
    }

    private struct Grant: Decodable {
        var access_token: String
        var refresh_token: String?
        var id_token: String?
    }

    private func grant(_ fields: [String: String]) async throws -> Grant {
        let (status, body) = try await HTTPCall.send("POST", Self.token, form: fields)
        guard status == 200 else {
            let error = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"]
            throw ProviderError.refused(status: status, code: error as? String ?? (error as? [String: Any])?["code"] as? String)
        }
        guard let grant = try? JSONDecoder().decode(Grant.self, from: body) else { throw ProviderError.invalidResponse }
        return grant
    }

    /// The payload of a JWT, unverified: it is read for what the provider said, not trusted as proof.
    static func claims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        return Data(base64Encoded: payload).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func expiry(_ jwt: String) -> Date? {
        (claims(jwt)?["exp"] as? TimeInterval).map(Date.init(timeIntervalSince1970:))
    }
}
