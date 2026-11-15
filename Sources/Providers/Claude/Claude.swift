import Foundation
import SluiceCore

/// Claude subscriptions, as Claude Code reaches them. Wire facts: docs/wire.md.
public struct Claude: Provider {
    public let id = "claude"
    public let name = "Claude"
    /// Fitted on 2026-11-14 (docs/wire.md, "Claude's meter"). Fable beside Opus is measured; Sonnet and
    /// Haiku are their list prices beside Opus's until they are. A point of the week was measured on a
    /// seat of five times the usage and on a plan of twenty; the basic plan is taken to hold a fifth of
    /// the first.
    public let formula: Formula? = Formula(
        output: 5, cacheWrite: 1.25, cacheRead: 0.025, models: ["fable": 3.3, "sonnet": 0.5, "haiku": 0.025],
        basic: 480_000, sizes: [20: 4_830_000]
    )
    public let client = "claude"
    public let upstream = URL(string: "https://api.anthropic.com")!
    public let redirect: URL? = nil

    /// Claude Code's public OAuth client, and the scopes it asks for.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let scopes = "user:profile user:inference"
    static let authorize = URL(string: "https://claude.ai/oauth/authorize")!
    static let token = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let usage = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let grants = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")!
    static let profile = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let oauthBeta = "oauth-2025-04-20"

    public init() {}

    public let home = (variable: "CLAUDE_CONFIG_DIR", folder: ".claude")

    /// Claude Code keeps its state beside its usual folder, and inside any other.
    private func state(of profile: String) -> UserFile {
        let folder = folder(of: profile)
        return UserFile((profile == Config.defaultProfile ? folder.deletingLastPathComponent() : folder).appending(path: ".claude.json"))
    }

    public func signedIn(in profile: String) throws -> String? {
        let state = state(of: profile)
        return try state.read().flatMap { try Self.account(inState: $0, path: state.path) }
    }

    public func folders(in profile: String) throws -> [String] {
        let state = state(of: profile)
        return try state.read().map { try Self.folders(inState: $0, path: state.path) } ?? []
    }

    private static func state(_ data: Data, path: String) throws -> [String: Any] {
        guard let all = data.object else {
            throw UserFileError(path: path, reason: "not the JSON object Claude Code's state should be")
        }
        return all
    }

    static func account(inState data: Data, path: String) throws -> String? {
        (try state(data, path: path)["oauthAccount"] as? [String: Any])?["emailAddress"] as? String
    }

    static func folders(inState data: Data, path: String) throws -> [String] {
        (try state(data, path: path)["projects"] as? [String: Any]).map { Array($0.keys) } ?? []
    }

    private func settings(of profile: String) -> UserFile {
        UserFile(folder(of: profile).appending(path: "settings.json"))
    }

    public func route(_ on: Bool, profiles: [String]) throws {
        for settings in profiles.map(settings) {
            // Nothing to take out of a file that is not there.
            if !on, try settings.read() == nil { continue }
            try settings.write(Self.pointed(try settings.read(), at: on ? address : nil, path: settings.path))
        }
    }

    public func isRouted(profiles: [String]) throws -> Bool {
        try profiles.map(settings).allSatisfy { try Self.environment(in: try $0.read(), path: $0.path).env["ANTHROPIC_BASE_URL"] as? String == address }
    }

    /// The settings with Claude Code's `statusLine` running `program` with `words`, or with nil no longer.
    /// A command the user had there is handed to `program` as one quoted word after `StatusLine.own`, and
    /// is the line again once Sluice's is taken out.
    static func lined(_ settings: Data?, by program: String?, words: String, path: String) throws -> Data {
        var all = try environment(in: settings, path: path).all
        var line = all["statusLine"] as? [String: Any]
        var own = line?["command"] as? String
        // Sluice's own is its quoted path and then its words.
        if let command = own, let ours = command.range(of: "' \(words)") {
            let rest = command[ours.upperBound...], marker = " \(StatusLine.own) '"
            own = rest.hasPrefix(marker) ? rest.dropFirst(marker.count).dropLast().replacingOccurrences(of: #"'\''"#, with: "'") : nil
        }
        if let program {
            line = line ?? ["type": "command"]
            func quoted(_ word: String) -> String { "'\(word.replacingOccurrences(of: "'", with: #"'\''"#))'" }
            line?["command"] = "\(quoted(program)) \(words)" + (own.map { " \(StatusLine.own) \(quoted($0))" } ?? "")
        } else if let own {
            line?["command"] = own
        } else {
            line = nil
        }
        all["statusLine"] = line
        return try written(all)
    }

    /// The settings with `env.ANTHROPIC_BASE_URL` set to `address`, or removed; everything else is kept.
    /// Claude Code keeps its own sign-in, which the relay replaces on each request: the features it runs
    /// outside the relay need that sign-in to be a real one.
    static func pointed(_ settings: Data?, at address: String?, path: String) throws -> Data {
        var (all, env) = try environment(in: settings, path: path)
        env["ANTHROPIC_BASE_URL"] = address
        all["env"] = env.isEmpty ? nil : env
        return try written(all)
    }

    private static func written(_ settings: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
    }

    private static func environment(in settings: Data?, path: String) throws -> (all: [String: Any], env: [String: Any]) {
        guard let settings else { return ([:], [:]) }
        guard let all = settings.object, let env = all["env"] as? [String: Any]? else {
            throw UserFileError(path: path, reason: "not the JSON object Claude Code's settings should be")
        }
        return (all, env ?? [:])
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
        let (status, body) = try await HTTPCall.send("GET", Self.profile, headers: Self.headers(grant.access_token))
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

    /// A stream's first event has the answer's model and what was read, nested under `message`; a later
    /// one, and an answer in one piece, say what they count at the top. Each number is the total so far.
    public func count(_ event: Data, into spend: inout Spend) {
        guard let all = event.object else { return }
        let message = all["message"] as? [String: Any] ?? all
        if let model = message["model"] as? String { spend.model = model }
        guard let usage = message["usage"] as? [String: Any] else { return }
        if let tokens = usage["input_tokens"] as? Int { spend.input = tokens }
        if let tokens = usage["cache_read_input_tokens"] as? Int { spend.cacheRead = tokens }
        if let tokens = usage["cache_creation_input_tokens"] as? Int { spend.cacheWrite = tokens }
        if let tokens = (usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int { spend.cacheWriteHour = tokens }
        if let speed = usage["speed"] as? String, speed != "standard" { spend.speed = speed }
        if let tokens = usage["output_tokens"] as? Int { spend.output = tokens }
    }

    public func model(of request: HTTPRequest) -> String? {
        JSONScan.topLevelValue(of: "model", in: request.body).flatMap { try? JSONDecoder().decode(String.self, from: request.body.subdata(in: $0)) }
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

    /// The windows come from one address and the plan from another; both must answer.
    public func usage(of account: Account) async throws -> Usage {
        let headers = Self.headers(account.accessToken)
        async let usage = HTTPCall.send("GET", Self.usage, headers: headers)
        async let profile = HTTPCall.send("GET", Self.profile, headers: headers)
        for status in try await [usage.0, profile.0] where status != 200 {
            throw ProviderError.answered(status)
        }
        return try await Usage(plan: Self.plan(inProfile: profile.1), windows: Self.windows(inUsage: usage.1), scoped: Self.scoped(inUsage: usage.1))
    }

    /// The plan in a profile. The tier's name ends in the multiple (`default_claude_max_20x`), and a Team
    /// seat is on the same tiers as a person. Prices are claude.com/pricing on 2026-11-13, where a seat
    /// with five times the usage is a Premium one. The basic plans were not captured: `claude_pro` is
    /// OpenUsage's reading (35e88e9), and a basic tier is assumed to name no multiple.
    static func plan(inProfile body: Data) -> Plan? {
        guard let organization = body.object?["organization"] as? [String: Any],
              let kind = organization["organization_type"] as? String else { return nil }
        let named = (organization["rate_limit_tier"] as? String)?.firstMatch(of: /_(\d+)x$/).flatMap { Int($0.1) }
        let multiple = named ?? (["claude_pro", "claude_team"].contains(kind) ? 1 : nil)
        let price: Int? = switch (kind, multiple) {
        case ("claude_pro", 1): 20
        case ("claude_max", 5): 100
        case ("claude_max", 20): 200
        case ("claude_team", 1): 25
        case ("claude_team", 5): 125
        default: nil
        }
        return Plan(
            name: organization["plan_display_name"] as? String ?? String(kind.trimmingPrefix("claude_")).capitalized,
            multiple: multiple, business: ["claude_team", "claude_enterprise"].contains(kind), price: price
        )
    }

    /// The windows in a usage answer. One the account does not have, or has not started, has no reset.
    static func windows(inUsage body: Data) throws -> [Window] {
        guard let usage = body.object else { throw ProviderError.invalidResponse }
        return [("five_hour", "5h"), ("seven_day", "7d")].compactMap { key, name in
            guard let window = usage[key] as? [String: Any], let used = window["utilization"] as? Double,
                  let reset = (window["resets_at"] as? String).flatMap(Date.init(wire:)) else { return nil }
            return Window(name: name, used: used / 100, resetsAt: reset)
        }
    }

    /// Resets are told to Claude Code alone, by its name and version (docs/wire.md), so they are asked for
    /// under the version the client itself last came through the relay with.
    public func clientName(from agent: String) -> String? {
        agent.firstMatch(of: /^claude-cli\/[0-9.]+/).map { "\($0.0) (external, cli)" }
    }

    /// What a call outside the relay is made with, as Claude Code where it names itself.
    private static func headers(_ token: String, as client: String? = nil) -> [String: String] {
        ["Authorization": "Bearer \(token)", "anthropic-beta": oauthBeta].merging(client.map { ["User-Agent": $0] } ?? [:]) { $1 }
    }

    public func resets(of account: Account, as client: String?) async throws -> [Reset]? {
        guard let client else { return nil }
        let (status, body) = try await HTTPCall.send("GET", Self.grants, headers: Self.headers(account.accessToken, as: client))
        guard status == 200 else { throw ProviderError.answered(status) }
        return try Self.resets(inUsage: body)
    }

    /// The resets in a usage answer that was asked for them.
    static func resets(inUsage body: Data) throws -> [Reset] {
        guard let held = body.object?["cedar_ember"] as? [String: Any] else { throw ProviderError.invalidResponse }
        guard held["eligible"] as? Bool == true else { return [] }
        let names = ["five_hour": "5h", "seven_day": "7d", "seven_day_overage_included": "fable"]
        // After a reset is used the account's others wait out a cooldown, which the answer times as a whole.
        let cooldown = (held["cooldown_until"] as? String).flatMap(Date.init(wire:))
        return (held["grants"] as? [[String: Any]] ?? []).compactMap { grant -> Reset? in
            guard let id = grant["id"] as? String, let left = grant["resets_left"] as? Int, left > 0 else { return nil }
            return Reset(
                id: id, refills: (grant["clears"] as? [String] ?? []).map { names[$0] ?? $0 }, left: left,
                expiresAt: (grant["ends_at"] as? String).flatMap(Date.init(wire:)), usable: grant["usable_now"] as? Bool == true && grant["paused"] as? Bool != true,
                usableAfter: grant["unavailable_reason"] as? String == "cooldown" ? cooldown : nil
            )
        }
    }

    public func use(_ reset: Reset, of account: Account, as client: String?) async throws {
        guard let client, let organization = account.organization else { throw ResetRefused("Claude Code has not come through Sluice yet, and a reset is used in its name") }
        // A fixed host and an id the provider gave.
        let address = URL(string: "https://api.anthropic.com/api/organizations/\(organization)/reset_rate_limits")!
        let (status, body) = try await HTTPCall.send("POST", address, headers: Self.headers(account.accessToken, as: client), json: ["program": "cedar_ember", "grant_id": reset.id, "request_id": UUID().uuidString])
        guard status == 200 else { throw ProviderError.answered(status) }
        if let refusal = try Self.refusal(inClaim: body) { throw refusal }
    }

    /// Why a claim's answer says the reset was not used; nil when it was. An answer in a word not known
    /// here is an error and not a refusal: whether the reset was spent is then not known.
    static func refusal(inClaim body: Data) throws -> ResetRefused? {
        guard let answer = body.object, let result = answer["result"] as? String else { throw ProviderError.invalidResponse }
        switch result == "unavailable" ? answer["reason"] as? String ?? result : result {
        case "reset", "already_used": return nil
        case "not_limited": return ResetRefused("nothing of the account is used yet")
        case "not_next_grant": return ResetRefused("the provider wants another of the account's resets used first")
        case "cooldown", "paused", "low_priority_active": return ResetRefused("the provider does not take a reset from the account just now")
        case "no_grant", "unknown_grant", "ineligible": return ResetRefused("the account no longer holds that reset")
        case let other: throw ProviderError.refused(status: 200, code: other)
        }
    }

    /// A model's own share of the week in a usage answer, named as the answer names the model.
    static func scoped(inUsage body: Data) -> [Window] {
        let limits = body.object?["limits"] as? [[String: Any]] ?? []
        return limits.compactMap { limit in
            guard limit["kind"] as? String == "weekly_scoped", let used = limit["percent"] as? Double,
                  let model = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String,
                  let reset = (limit["resets_at"] as? String).flatMap(Date.init(wire:)) else { return nil }
            return Window(name: model.lowercased(), used: used / 100, resetsAt: reset)
        }
    }

    private func grant(_ fields: [String: String]) async throws -> Grant {
        let (status, body) = try await HTTPCall.send("POST", Self.token, json: fields)
        guard status == 200 else {
            let error = body.object?["error"]
            throw ProviderError.refused(status: status, code: error as? String ?? (error as? [String: Any])?["type"] as? String)
        }
        guard let grant = try? JSONDecoder().decode(Grant.self, from: body) else { throw ProviderError.invalidResponse }
        return grant
    }
}

/// Claude Code runs the command its settings name under `statusLine` (seen in 2.1.325) and shows what it prints.
extension Claude: StatusShowing {
    public func showStatus(by program: URL?, profiles: [String]) throws {
        for settings in profiles.map(settings) {
            let now = try settings.read()
            if program == nil, now == nil { continue }
            try settings.write(Self.lined(now, by: program?.path, words: statusArguments, path: settings.path))
        }
    }
}
