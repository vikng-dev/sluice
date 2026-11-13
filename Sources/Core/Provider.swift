import CryptoKit
import Foundation

/// What Core asks of a provider. Everything that names the provider's hosts, headers or bodies is behind it.
public protocol Provider: Sendable {
    /// The first path segment of the provider's local address, e.g. `claude`.
    var id: String { get }
    /// Makes the provider's client on this machine talk to `address`, or to the provider again,
    /// by editing the client's own settings.
    func route(_ on: Bool) throws
    func isRouted() throws -> Bool
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
    /// What a response's status and headers (names lowercased) say about the account that answered.
    func reading(status: Int, headers: [String: String]) -> Reading
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

    public var description: String {
        switch self {
        case .refused(let status, let code): "the provider refused (\(status)\(code.map { ", \($0)" } ?? ""))"
        case .invalidResponse: "the provider's answer could not be read"
        case .signedOut: "the account is no longer signed in"
        }
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

/// Sign-ins in flight: the PKCE verifier each browser round trip must come back to.
actor SignIns {
    private var pending: [String: (provider: String, verifier: String)] = [:]
    /// Listeners on providers' fixed redirect ports, by port, open while a sign-in there is in flight.
    private var listeners: [Int: Server] = [:]

    func listen(on port: Int, _ start: () async throws -> Server) async throws {
        if listeners[port] == nil { listeners[port] = try await start() }
    }

    func close(port: Int) {
        listeners.removeValue(forKey: port)?.stop()
    }

    func begin(provider: String) -> (state: String, challenge: String) {
        let verifier = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64URL
        let state = UUID().uuidString
        pending[state] = (provider, verifier)
        return (state, Data(SHA256.hash(data: Data(verifier.utf8))).base64URL)
    }

    func finish(state: String) -> (provider: String, verifier: String)? {
        pending.removeValue(forKey: state)
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public extension Provider {
    /// Where this provider's client reaches Sluice.
    var address: String { "http://localhost:\(Sluice.port)/\(id)" }
}

/// A client's settings file that Sluice could not read or may not change.
public struct ClientSettingsError: Error, CustomStringConvertible {
    public let path: String
    public let reason: String
    public init(path: String, reason: String) { self.path = path; self.reason = reason }
    public var description: String { "\(path): \(reason)" }
}

/// A client's settings file: absent is empty, and a write goes to the file a link points at.
public struct ClientSettings: Sendable {
    let file: URL
    public init(_ file: URL) { self.file = file.resolvingSymlinksInPath() }
    public var path: String { file.path }

    public func read() throws -> Data? {
        FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
    }

    public func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}
