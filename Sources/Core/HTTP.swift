import Foundation

public struct HTTPRequest: Sendable {
    public var method: String
    /// Path and query, as sent.
    public var target: String
    public var headers: [(name: String, value: String)]
    public var body: Data
    /// The working folder of the program that sent this, when it could be told.
    public var callerFolder: String? = nil

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Whether a program on this machine sent this, not a web page. A page can reach a local port, so:
    /// the host must be a loopback name (a rebound DNS name is not), a browser's `Origin` is refused,
    /// and of a browser's own requests only a navigation passes, which is how a sign-in comes and goes.
    var isLocalCaller: Bool {
        let host = header("Host")?.split(separator: ":").first.map(String.init)
        return ["localhost", "127.0.0.1"].contains(host) && header("Origin") == nil && [nil, "navigate"].contains(header("Sec-Fetch-Mode"))
    }

    public mutating func setHeader(_ name: String, _ value: String) {
        headers.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        headers.append((name, value))
    }
}

public enum HTTPError: Error, Equatable {
    case malformed, headTooLarge, lengthRequired, bodyTooLarge, notLocal

    var status: Int {
        switch self {
        case .malformed: 400
        case .headTooLarge: 431
        case .lengthRequired: 411
        case .bodyTooLarge: 413
        case .notLocal: 403
        }
    }
}

enum HTTPHead {
    static let terminator = Data("\r\n\r\n".utf8)
    static let maxHead = 64 << 10
    static let maxBody = 256 << 20

    /// Parses a request head (without its terminator) into a request with an empty body and the body's length.
    static func parse(_ head: Data) throws(HTTPError) -> (request: HTTPRequest, bodyLength: Int) {
        guard let text = String(data: head, encoding: .utf8) else { throw .malformed }
        var lines = text.components(separatedBy: "\r\n")[...]
        let start = lines.removeFirst().split(separator: " ")
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { throw .malformed }
        var request = HTTPRequest(method: String(start[0]), target: String(start[1]), headers: [], body: Data())
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw .malformed }
            request.headers.append((String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        guard request.header("Transfer-Encoding") == nil else { throw .lengthRequired }
        guard let length = request.header("Content-Length") else { return (request, 0) }
        guard let bodyLength = Int(length), bodyLength >= 0 else { throw .malformed }
        guard bodyLength <= maxBody else { throw .bodyTooLarge }
        return (request, bodyLength)
    }
}

/// Headers that describe one connection or one encoding of the body, so never cross the relay.
enum Hop {
    static let request: Set<String> = ["host", "connection", "keep-alive", "content-length", "transfer-encoding", "accept-encoding", "upgrade", "te"]
    static let response: Set<String> = ["connection", "keep-alive", "content-length", "transfer-encoding", "content-encoding"]
}
