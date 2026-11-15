import Foundation

/// What Core asks of a provider. Everything that names the provider's hosts, headers or bodies is behind it.
public protocol Provider: Sendable {
    /// The first path segment of the provider's local address, e.g. `claude`.
    var id: String { get }
    /// What its subscriptions are sold as, e.g. `Claude`.
    var name: String { get }
    /// The command that runs this provider's client, e.g. `claude`.
    var client: String { get }
    /// The variable that tells the client where it keeps a profile, and its usual folder under home, e.g. `.claude`.
    var home: (variable: String, folder: String) { get }
    /// The account the client is itself signed in as in a profile, as the client records it; nil when it is
    /// signed out there. What the client does outside the relay is this account's, whichever account serves
    /// its requests.
    func signedIn(in profile: String) throws -> String?
    /// The folders the client has worked in in a profile, as the client records them.
    func folders(in profile: String) throws -> [String]
    /// Makes the provider's client talk to `address` in each profile, or to the provider again,
    /// by editing the client's own settings.
    func route(_ on: Bool, profiles: [String]) throws
    func isRouted(profiles: [String]) throws -> Bool
    /// Where a relayed request's path is appended.
    var upstream: URL { get }
    /// Where the provider's sign-in must land when its OAuth client is registered to one fixed address;
    /// nil when any local address will do. Sluice listens there for the length of a sign-in.
    var redirect: URL? { get }
    func authorizeURL(redirectURI: String, state: String, challenge: String) -> URL
    func signIn(code: String, state: String, redirectURI: String, verifier: String) async throws -> Account
    /// The account with renewed tokens.
    func refresh(_ account: Account) async throws -> Account
    /// Makes a client's request the account's own: its credential, and any identity the body carries.
    func prepare(_ request: inout HTTPRequest, for account: Account)
    /// The conversation a request belongs to, and how long its prompt cache lives after this request.
    /// Nil for a request that belongs to none.
    func conversation(of request: HTTPRequest) -> (id: String, cacheLifetime: TimeInterval)?
    /// The model a request asks for; nil where it asks for none. A limit on one model's use is named so
    /// that the model's name has the limit's in it.
    func model(of request: HTTPRequest) -> String?
    /// What a response's status and headers (names lowercased) say about the account that answered.
    func reading(status: Int, headers: [String: String]) -> Reading
    /// Reads into `spend` what one event of an answer says it cost: the JSON of a stream's event, or of an
    /// answer in one piece. Asked only of events that have a `usage` key.
    func count(_ event: Data, into spend: inout Spend)
    /// What the provider says about the account when asked, which keeps an account that no request
    /// has gone through lately from showing what it last was.
    func usage(of account: Account) async throws -> Usage
    /// How the provider's own client names itself to it, read from the User-Agent of a relayed request.
    /// Nil when the request is not that client's, or the provider tells any caller the same.
    func clientName(from agent: String) -> String?
    /// The resets the account holds. A provider that tells only its own client is asked under `client`,
    /// the name its client last gave; nil when it cannot be asked without one.
    func resets(of account: Account, as client: String?) async throws -> [Reset]?
    /// Spends a reset now, which cannot be taken back.
    func use(_ reset: Reset, of account: Account, as client: String?) async throws
    /// How its meter counts tokens; nil while that has not been fitted, and its accounts are then sized
    /// by their plans alone.
    var formula: Formula? { get }
}

/// A reset an account holds: its provider's leave to have some of its limits whole again before their time.
public struct Reset: Codable, Sendable, Equatable {
    /// The provider's own name for it.
    public var id: String
    /// The limits it refills, by the names the account's windows and scoped limits go by.
    public var refills: [String]
    /// How many times it can still be used.
    public var left: Int
    /// Nil for one that does not lapse.
    public var expiresAt: Date?
    /// Whether the provider would take it now.
    public var usable: Bool
    /// When the provider said it would take it again, for one it will not take now; nil when it named no time.
    public var usableAfter: Date?

    public init(id: String, refills: [String], left: Int = 1, expiresAt: Date?, usable: Bool, usableAfter: Date? = nil) {
        self.id = id
        self.refills = refills
        self.left = left
        self.expiresAt = expiresAt
        self.usable = usable
        self.usableAfter = usableAfter
    }
}

/// A reset the provider did not take, in words that say why.
public struct ResetRefused: Error, CustomStringConvertible, Equatable {
    public let description: String

    public init(_ description: String) { self.description = description }
}

/// Whom a provider's client is itself signed in as in one profile; `account` is nil where it is signed out.
public struct Identity: Sendable {
    public var provider: String
    public var client: String
    public var account: String?

    public init(provider: String, client: String, account: String?) {
        self.provider = provider
        self.client = client
        self.account = account
    }
}

public struct Usage: Sendable, Equatable {
    /// Nil when the provider names no plan.
    public var plan: Plan?
    public var windows: [Window]
    /// The limits on a part of the account's use, such as one model's own share of the week.
    public var scoped: [Window]

    public init(plan: Plan?, windows: [Window], scoped: [Window] = []) {
        self.plan = plan
        self.windows = windows
        self.scoped = scoped
    }
}

/// The tier an account is on. What the tier promises, not what the account is seen to get.
public struct Plan: Sendable, Codable, Equatable {
    /// The provider's name for it.
    public var name: String
    /// Its usage as a multiple of the provider's basic plan of the same kind; nil when none is published.
    public var multiple: Int?
    /// Sold by the seat to an organization, not to a person.
    public var business: Bool
    /// Dollars a month at list price; nil when not known.
    public var price: Int?

    public init(name: String, multiple: Int?, business: Bool, price: Int?) {
        self.name = name
        self.multiple = multiple
        self.business = business
        self.price = price
    }

    /// The tier in a few characters: the multiple where there is one, the name where there is not.
    public var tier: String { multiple.map { "\($0)x" } ?? name }
}

public struct Reading: Sendable, Equatable {
    /// The windows this response reported; a window it did not mention is unchanged.
    public var windows: [Window]
    /// The account refused because an allowance is spent, so another account may serve the request.
    public var refused: Bool

    public init(windows: [Window], refused: Bool) {
        self.windows = windows
        self.refused = refused
    }
}

public enum ProviderError: Error, CustomStringConvertible {
    /// The provider answered a sign-in or renewal with this status and error code.
    case refused(status: Int, code: String?)
    case invalidResponse
    case signedOut

    /// What an answer other than 200 means: the sign-in is gone, or the provider refused.
    public static func answered(_ status: Int) -> ProviderError { status == 401 ? .signedOut : .refused(status: status, code: nil) }

    public var description: String {
        switch self {
        case .refused(let status, let code): "the provider refused (\(status)\(code.map { ", \($0)" } ?? ""))"
        case .invalidResponse: "the provider's answer could not be read"
        case .signedOut: "the account is no longer signed in"
        }
    }
}

public extension Date {
    /// A time as the providers write it: ISO 8601, with fractions of a second or without.
    init?(wire text: String) {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let time = precise.date(from: text) ?? ISO8601DateFormatter().date(from: text) else { return nil }
        self = time
    }
}

public enum HTTPCall {
    private static let session = URLSession(configuration: .ephemeral)

    public static func send(_ method: String, _ url: URL, headers: [String: String] = [:], json: [String: String]? = nil, form: [String: String]? = nil) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(json)
        }
        if let form {
            var fields = URLComponents()
            fields.queryItems = form.map(URLQueryItem.init)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            // `percentEncodedQuery` leaves "+" alone, which a form reads as a space.
            request.httpBody = Data((fields.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        }
        let (body, response) = try await session.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, body)
    }
}

public extension Provider {
    /// Where this provider's client reaches Sluice.
    var address: String { "\(Sluice.address)/\(id)" }

    /// Where its client keeps a profile: its usual folder in the default, and beside it `<usual>-<name>` in another.
    func folder(of profile: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: profile == Config.defaultProfile ? home.folder : "\(home.folder)-\(profile)")
    }
}
