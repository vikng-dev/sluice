import CryptoKit
import Foundation

/// What Core asks of a provider. Everything that names the provider's hosts, headers or bodies is behind it.
public protocol Provider: Sendable {
    /// The first path segment of the provider's local address, e.g. `claude`.
    var id: String { get }
    /// The command that runs this provider's client, e.g. `claude`.
    var client: String { get }
    /// Where the client keeps a profile, and the variable that tells it so; nil when it keeps one folder for all.
    func home(of profile: String) -> (variable: String, folder: URL)?
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
    /// What a response's status and headers (names lowercased) say about the account that answered.
    func reading(status: Int, headers: [String: String]) -> Reading
    /// The account's windows as the provider reports them when asked, which keeps an account that no
    /// request has gone through lately from showing what it last was.
    func usage(of account: Account) async throws -> [Window]
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

/// A file of the user's that Sluice could not read or may not change.
public struct UserFileError: Error, CustomStringConvertible {
    public let path: String
    public let reason: String
    public init(path: String, reason: String) { self.path = path; self.reason = reason }
    public var description: String { "\(path): \(reason)" }
}

/// A file of the user's that Sluice edits: absent is empty, and a write goes to the file a link points at.
public struct UserFile: Sendable {
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

/// The commands that stand in for the clients: each is a link to Sluice, which picks the profile for the
/// folder it is run in and then runs the real client. They work whether or not the relay is running.
public enum StandIns {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/sluice/bin")
    static let line = #"export PATH="$HOME/.config/sluice/bin:$PATH" # sluice"#

    /// The user's shell startup file, where the line that puts the stand-ins first on PATH goes.
    private static func startup() throws -> UserFile {
        let shell = URL(fileURLWithPath: String(cString: getpwuid(getuid()).pointee.pw_shell)).lastPathComponent
        guard ["zsh", "bash"].contains(shell) else {
            throw UserFileError(path: shell, reason: "Sluice does not know this shell's startup file; add this line to it yourself: \(line)")
        }
        return UserFile(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".\(shell)rc"))
    }

    private static func lines(of file: UserFile) throws -> [String] {
        String(decoding: try file.read() ?? Data(), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    public static func install(_ commands: [String], program: URL) throws {
        try remove(commands)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for command in commands { try FileManager.default.createSymbolicLink(at: folder.appending(path: command), withDestinationURL: program) }
        let file = try startup()
        var lines = try lines(of: file)
        if lines.last == "" { lines.removeLast() }
        try file.write(Data((lines + [line, ""]).joined(separator: "\n").utf8))
    }

    public static func remove(_ commands: [String]) throws {
        for command in commands where isInstalled(command) { try FileManager.default.removeItem(at: folder.appending(path: command)) }
        let file = try startup(), lines = try lines(of: file)
        if lines.contains(line) { try file.write(Data(lines.filter { $0 != line }.joined(separator: "\n").utf8)) }
    }

    public static func isInstalled(_ command: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: folder.appending(path: command).path)) != nil
    }

    /// The real `command`: the first one on `path` after the stand-ins' folder, so a wrapper ahead of
    /// the stand-in that hands on to it is not run again; anywhere on `path` when the folder is not on it.
    public static func real(_ command: String, path: String) -> String? {
        let folders = path.split(separator: ":").map { URL(fileURLWithPath: String($0)).standardizedFileURL.path }
        let own = folder.standardizedFileURL.path
        let after = folders.firstIndex(of: own).map { Array(folders[($0 + 1)...]) } ?? folders
        return after.filter { $0 != own }.map { $0 + "/" + command }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
