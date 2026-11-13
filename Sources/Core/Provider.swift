import CryptoKit
import Foundation

/// What Core asks of a provider. Everything that names the provider's hosts, headers or bodies is behind it.
public protocol Provider: Sendable {
    /// The first path segment of the provider's local address, e.g. `claude`.
    var id: String { get }
    /// Where a relayed request's path is appended.
    var upstream: URL { get }
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

    public static func send(_ method: String, _ url: URL, headers: [String: String] = [:], json: [String: String]? = nil) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(json)
        }
        let (body, response) = try await session.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, body)
    }
}

/// Sign-ins in flight: the PKCE verifier each browser round trip must come back to.
actor SignIns {
    private var pending: [String: (provider: String, verifier: String)] = [:]

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
