import Foundation
import SluiceCore

/// Claude subscriptions, as Claude Code reaches them. Wire facts: docs/wire.md.
public struct Claude: Provider {
    public let id = "claude"
    public let client = "claude"
    public let upstream = URL(string: "https://api.anthropic.com")!
    public let redirect: URL? = nil

    /// Claude Code's public OAuth client, and the scopes it asks for.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let scopes = "user:profile user:inference"
    static let authorize = URL(string: "https://claude.ai/oauth/authorize")!
    static let token = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let profile = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let oauthBeta = "oauth-2025-04-20"

    public init() {}

    public func pointing(_ arguments: [String], at address: String) -> (environment: [String: String], arguments: [String]) {
        (["ANTHROPIC_BASE_URL": address], arguments)
    }

    public func authorizeURL(redirectURI: String, state: String, challenge: String) -> URL {
        var components = URLComponents(url: Self.authorize, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            "code": "true", "client_id": Self.clientID, "response_type": "code", "redirect_uri": redirectURI,
            "scope": Self.scopes, "code_challenge": challenge, "code_challenge_method": "S256", "state": state,
        ].map(URLQueryItem.init)
        return components.url!
    }

    public func signIn(code: String, state: String, redirectURI: String, verifier: String) async throws -> Account {
        let grant = try await grant([
            "grant_type": "authorization_code", "client_id": Self.clientID, "code": code, "state": state,
            "redirect_uri": redirectURI, "code_verifier": verifier,
        ])
        guard let refreshToken = grant.refresh_token else { throw ProviderError.invalidResponse }
        let (status, body) = try await HTTPCall.send("GET", Self.profile, headers: ["Authorization": "Bearer \(grant.access_token)", "anthropic-beta": Self.oauthBeta])
        guard status == 200 else { throw ProviderError.refused(status: status, code: nil) }
        guard let profile = try? JSONDecoder().decode(Profile.self, from: body) else { throw ProviderError.invalidResponse }
        return Account(
            provider: id, subject: profile.account.uuid, organization: profile.organization?.uuid, label: profile.account.email,
            accessToken: grant.access_token, refreshToken: refreshToken, expiresAt: Date().addingTimeInterval(grant.expires_in)
        )
    }

    public func refresh(_ account: Account) async throws -> Account {
        let grant = try await grant(["grant_type": "refresh_token", "refresh_token": account.refreshToken, "client_id": Self.clientID, "scope": Self.scopes])
        var renewed = account
        renewed.accessToken = grant.access_token
        // A renewal that sends no new refresh token leaves the old one valid.
        renewed.refreshToken = grant.refresh_token ?? account.refreshToken
        renewed.expiresAt = Date().addingTimeInterval(grant.expires_in)
        return renewed
    }

    public func prepare(_ request: inout HTTPRequest, for account: Account) {
        request.setHeader("Authorization", "Bearer \(account.accessToken)")
        // `metadata.user_id` is a JSON string naming the client's own login; requests without it
        // (the hello probe, a client that sends none) have nothing to swap.
        let marker = Data(#"account_uuid\":\""#.utf8)
        guard let metadata = JSONScan.topLevelValue(of: "metadata", in: request.body),
              let found = request.body.range(of: marker, in: metadata),
              let end = request.body[found.upperBound..<metadata.upperBound].firstIndex(of: UInt8(ascii: "\\"))
        else { return }
        request.body.replaceSubrange(found.upperBound..<end, with: Data(account.subject.utf8))
        request.setHeader("Content-Length", String(request.body.count))
    }

    public func conversation(of request: HTTPRequest) -> (id: String, cacheLifetime: TimeInterval)? {
        guard let session = request.header("X-Claude-Code-Session-Id") else { return nil }
        // Quotes inside a JSON string are escaped, so this matches only a real cache marker.
        let hour = request.body.range(of: Data(#""ttl":"1h""#.utf8)) != nil
        return (session, hour ? 3600 : 300)
    }

    public func reading(status: Int, headers: [String: String]) -> Reading {
        func field(_ window: String, _ name: String) -> String? { headers["anthropic-ratelimit-unified-\(window)-\(name)"] }
        let windows = ["5h", "7d"].compactMap { name -> Window? in
            guard let reset = field(name, "reset").flatMap(TimeInterval.init) else { return nil }
            let rejected = field(name, "status") == "rejected"
            guard let used = field(name, "utilization").flatMap(Double.init) ?? (rejected ? 1 : nil) else { return nil }
            return Window(name: name, used: rejected ? max(used, 1) : used, resetsAt: Date(timeIntervalSince1970: reset))
        }
        // `7d_oi` is a per-model weekly window: spent, it refuses this request without closing the account.
        let refused = status == 429 && ["5h", "7d", "7d_oi"].contains { field($0, "status") == "rejected" }
        return Reading(windows: windows, refused: refused)
    }

    private struct Grant: Decodable {
        var access_token: String
        var refresh_token: String?
        var expires_in: TimeInterval
    }

    private struct Profile: Decodable {
        struct Account: Decodable { var uuid: String; var email: String }
        struct Organization: Decodable { var uuid: String }
        var account: Account
        var organization: Organization?
    }

    private func grant(_ fields: [String: String]) async throws -> Grant {
        let (status, body) = try await HTTPCall.send("POST", Self.token, json: fields)
        guard status == 200 else {
            let error = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"]
            throw ProviderError.refused(status: status, code: error as? String ?? (error as? [String: Any])?["type"] as? String)
        }
        guard let grant = try? JSONDecoder().decode(Grant.self, from: body) else { throw ProviderError.invalidResponse }
        return grant
    }
}
