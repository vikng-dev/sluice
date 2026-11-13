import Foundation
import SluiceCore

/// ChatGPT subscriptions, as the Codex CLI reaches them. Wire facts: docs/wire.md.
public struct Codex: Provider {
    public let id = "codex"
    public let name = "ChatGPT"
    public let client = "codex"
    public let upstream = URL(string: "https://chatgpt.com/backend-api/codex")!
    /// The Codex CLI's OAuth client accepts only this address.
    public let redirect: URL? = URL(string: "http://localhost:1455/auth/callback")

    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let authorize = URL(string: "https://auth.openai.com/oauth/authorize")!
    static let token = URL(string: "https://auth.openai.com/oauth/token")!
    static let usage = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let resets = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!

    public init() {}

    /// Codex keeps its sessions, memories, tool sign-ins and its own sign-in in one folder, so each profile has its own.
    public func home(of profile: String) -> (variable: String, folder: URL)? {
        ("CODEX_HOME", Config.folder(".codex", of: profile))
    }

    public func signedIn(in profile: String) throws -> String? {
        let file = UserFile(home(of: profile)!.folder.appending(path: "auth.json"))
        guard let data = try file.read() else { return nil }
        return try Self.account(inSignIn: data, path: file.path)
    }

    /// A sign-in by API key holds no tokens and is nobody's subscription.
    static func account(inSignIn data: Data, path: String) throws -> String? {
        guard let all = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UserFileError(path: path, reason: "not the JSON object Codex's sign-in should be")
        }
        return ((all["tokens"] as? [String: Any])?["id_token"] as? String).flatMap(claims)?["email"] as? String
    }

    public func folders(in profile: String) throws -> [String] {
        try settings(of: profile).read().map { Self.folders(inSettings: String(decoding: $0, as: UTF8.self)) } ?? []
    }

    /// Each folder Codex was told to trust or not has a table of its own, named by the folder.
    static func folders(inSettings text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[projects."), line.hasSuffix("]") else { return nil }
            return String(line.dropFirst(10).dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
    }

    /// Codex's user config in a profile. A project's own config cannot name a provider.
    private func settings(of profile: String) -> UserFile {
        UserFile(home(of: profile)!.folder.appending(path: "config.toml"))
    }

    public func route(_ on: Bool, profiles: [String]) throws {
        for settings in profiles.map(settings) {
            // Nothing to take out of a file that is not there.
            if !on, try settings.read() == nil { continue }
            try settings.write(Data(Self.pointed(try Self.text(settings), at: on ? address : nil, path: settings.path).utf8))
        }
    }

    public func isRouted(profiles: [String]) throws -> Bool {
        try profiles.map(settings).allSatisfy {
            let lines = try Self.text($0).split(separator: "\n")
            return lines.contains(Substring(Self.choice)) && lines.contains(Substring(Self.entry(address)[2]))
        }
    }

    private static func text(_ settings: UserFile) throws -> String {
        String(decoding: try settings.read() ?? Data(), as: UTF8.self)
    }

    static let choice = #"model_provider = "sluice""#
    static func entry(_ address: String) -> [String] {
        ["[model_providers.sluice]", #"name = "Sluice""#, #"base_url = "\#(address)""#, #"wire_api = "responses""#]
    }

    /// The config with Sluice as the model provider at `address`, or with Sluice's lines taken out.
    /// The choice of provider is a top-level key, so it goes first; the entry is a table, so it goes last.
    static func pointed(_ config: String, at address: String?, path: String) throws -> String {
        var lines = config.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeAll { $0 == choice }
        if let start = lines.firstIndex(of: entry("")[0]) {
            let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("[") } ?? lines.endIndex
            lines.removeSubrange(start..<end)
        }
        while lines.last == "" { lines.removeLast() }
        guard let address else { return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n" }
        guard !lines.prefix(while: { !$0.hasPrefix("[") }).contains(where: { $0.hasPrefix("model_provider") }) else {
            throw UserFileError(path: path, reason: "already chooses a model provider; remove that line to route Codex through Sluice")
        }
        return ([choice] + lines + [""] + entry(address)).joined(separator: "\n") + "\n"
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

    /// The stream's last event has the answer whole, with its model and what it cost. The tokens read
    /// from the cache and written to it are counted among those read, and are taken out of them here.
    public func count(_ event: Data, into spend: inout Spend) {
        guard let all = try? JSONSerialization.jsonObject(with: event) as? [String: Any] else { return }
        let response = all["response"] as? [String: Any] ?? all
        guard let usage = response["usage"] as? [String: Any] else { return }
        spend.model = response["model"] as? String ?? spend.model
        let details = usage["input_tokens_details"] as? [String: Any]
        spend.cacheRead = details?["cached_tokens"] as? Int ?? 0
        spend.cacheWrite = details?["cache_write_tokens"] as? Int ?? 0
        spend.input = max(0, (usage["input_tokens"] as? Int ?? 0) - spend.cacheRead - spend.cacheWrite)
        spend.output = usage["output_tokens"] as? Int ?? 0
    }

    public func model(of request: HTTPRequest) -> String? {
        JSONScan.topLevelValue(of: "model", in: request.body).flatMap { try? JSONDecoder().decode(String.self, from: request.body.subdata(in: $0)) }
    }

    public func reading(status: Int, headers: [String: String]) -> Reading {
        let windows = ["primary", "secondary"].compactMap { slot -> Window? in
            func field(_ name: String) -> Double? { headers["x-codex-\(slot)-\(name)"].flatMap(Double.init) }
            // An unused slot reports a zero-minute window with no reset.
            guard let minutes = field("window-minutes"), minutes > 0, let used = field("used-percent"), let reset = field("reset-at") else { return nil }
            return Window(name: Self.name(minutes: minutes), used: used / 100, resetsAt: Date(timeIntervalSince1970: reset))
        }
        return Reading(windows: windows, refused: status == 429)
    }

    private struct Grant: Decodable {
        var access_token: String
        var refresh_token: String?
        var id_token: String?
    }

    static func name(minutes: Double) -> String {
        switch minutes { case 300: "5h"; case 10080: "7d"; default: "\(Int(minutes))m" }
    }

    public func usage(of account: Account) async throws -> Usage {
        let (status, body) = try await HTTPCall.send("GET", Self.usage, headers: ["Authorization": "Bearer \(account.accessToken)", "chatgpt-account-id": account.subject])
        guard status == 200 else { throw status == 401 ? ProviderError.signedOut : ProviderError.refused(status: status, code: nil) }
        return try Self.usage(in: body)
    }

    private func headers(_ account: Account) -> [String: String] {
        ["Authorization": "Bearer \(account.accessToken)", "chatgpt-account-id": account.subject]
    }

    public func clientName(from agent: String) -> String? { nil }

    /// The list says which resets are held, and the usage answer how many of them would be taken now.
    public func resets(of account: Account, as client: String?) async throws -> [Reset]? {
        async let list = HTTPCall.send("GET", Self.resets, headers: headers(account))
        async let usage = HTTPCall.send("GET", Self.usage, headers: headers(account))
        for status in try await [list.0, usage.0] where status != 200 {
            throw status == 401 ? ProviderError.signedOut : ProviderError.refused(status: status, code: nil)
        }
        return try await Self.resets(inList: list.1, usage: usage.1)
    }

    static func resets(inList list: Data, usage: Data) throws -> [Reset] {
        guard let credits = (try? JSONSerialization.jsonObject(with: list) as? [String: Any])?["credits"] as? [[String: Any]] else { throw ProviderError.invalidResponse }
        let counts = (try? JSONSerialization.jsonObject(with: usage) as? [String: Any])?["rate_limit_reset_credits"] as? [String: Any]
        let usable = counts?["applicable_available_count"] as? Int ?? 0
        let time = ISO8601DateFormatter()
        time.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return credits.filter { $0["status"] as? String == "available" }.enumerated().compactMap { index, credit in
            // The one kind of reset refills every window the plan has.
            (credit["id"] as? String).map { Reset(id: $0, refills: ["5h", "7d"], expiresAt: (credit["expires_at"] as? String).flatMap(time.date), usable: index < usable) }
        }
    }

    public func use(_ reset: Reset, of account: Account, as client: String?) async throws {
        let (status, body) = try await HTTPCall.send("POST", Self.resets.appending(path: "consume"), headers: headers(account), json: ["redeem_request_id": UUID().uuidString, "credit_id": reset.id])
        guard status == 200 else { throw status == 401 ? ProviderError.signedOut : ProviderError.refused(status: status, code: nil) }
        if let refusal = try Self.refusal(inClaim: body) { throw refusal }
    }

    /// Why a claim's answer says the reset was not used; nil when it was.
    static func refusal(inClaim body: Data) throws -> ResetRefused? {
        guard let code = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["code"] as? String else { throw ProviderError.invalidResponse }
        switch code {
        case "reset", "already_redeemed": return nil
        case "nothing_to_reset": return ResetRefused("too little of the account is used yet")
        case "no_credit": return ResetRefused("the account no longer holds that reset")
        default: throw ProviderError.refused(status: 200, code: code)
        }
    }

    /// The plans by `plan_type`. `prolite` was captured; the other names are OpenUsage's reading (35e88e9).
    /// Multiples are of Plus, or of a Standard seat, as published; prices are those of 2026-11-13.
    static let plans = [
        "go": Plan(name: "Go", multiple: nil, business: false, price: 8),
        "plus": Plan(name: "Plus", multiple: 1, business: false, price: 20),
        "prolite": Plan(name: "Pro", multiple: 5, business: false, price: 100),
        "pro": Plan(name: "Pro", multiple: 20, business: false, price: 200),
        "promax": Plan(name: "Pro", multiple: nil, business: false, price: 500),
        "team": Plan(name: "Business", multiple: 1, business: true, price: 25),
        "self_serve_business_prolite": Plan(name: "Business", multiple: 5, business: true, price: 125),
    ]

    /// What a usage answer says: the plan, which when not listed keeps its own word with underscores
    /// read as spaces, and the windows; a slot the plan does not have is null.
    static func usage(in body: Data) throws -> Usage {
        guard let answer = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let limit = answer["rate_limit"] as? [String: Any] else { throw ProviderError.invalidResponse }
        let plan = (answer["plan_type"] as? String).map { plans[$0] ?? Plan(name: $0.replacing("_", with: " ").capitalized, multiple: nil, business: false, price: nil) }
        return Usage(plan: plan, windows: ["primary_window", "secondary_window"].compactMap { slot in
            guard let window = limit[slot] as? [String: Any], let used = window["used_percent"] as? Double,
                  let seconds = window["limit_window_seconds"] as? Double, let reset = window["reset_at"] as? Double else { return nil }
            return Window(name: name(minutes: seconds / 60), used: used / 100, resetsAt: Date(timeIntervalSince1970: reset))
        })
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
