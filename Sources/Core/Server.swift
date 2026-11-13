import Foundation
import Network

public typealias Handler = @Sendable (HTTPRequest, ResponseWriter) async throws -> Void

/// An HTTP/1.1 server on loopback: keep-alive, bodies framed by Content-Length in, chunked out.
public final class Server: Sendable {
    private let listener: NWListener

    public init(port: UInt16, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            Task {
                await Self.serve(Peer(connection: connection), handler)
                connection.cancel()
            }
        }
    }

    /// Returns once the port is bound; throws when it cannot be.
    public func start() async throws {
        let listener = listener
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    ready.resume()
                case .failed(let error), .waiting(let error):
                    listener.stateUpdateHandler = nil
                    listener.cancel()
                    ready.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }

    public func stop() {
        listener.cancel()
    }

    private static func serve(_ peer: Peer, _ handler: Handler) async {
        var buffer = Data()
        do {
            while let request = try await peer.request(&buffer) {
                try await handler(request, ResponseWriter(peer: peer, method: request.method))
            }
        } catch let error as HTTPError {
            try? await ResponseWriter(peer: peer, method: "").send(error.status, text: "sluice: \(error)")
        } catch {
            // The client went away or the upstream broke mid-body: closing the connection tells the client.
        }
    }
}

struct Peer: Sendable {
    let connection: NWConnection

    /// The next bytes, or nil once the client has closed.
    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { next in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, _, error in
                if let error { next.resume(throwing: error) } else { next.resume(returning: data.flatMap { $0.isEmpty ? nil : $0 }) }
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (sent: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { sent.resume(throwing: error) } else { sent.resume() }
            })
        }
    }

    /// The next request on this connection, or nil when the client closed between requests.
    /// `buffer` carries bytes read past one request into the next.
    func request(_ buffer: inout Data) async throws -> HTTPRequest? {
        var headEnd = buffer.range(of: HTTPHead.terminator)
        while headEnd == nil {
            guard buffer.count <= HTTPHead.maxHead else { throw HTTPError.headTooLarge }
            guard let more = try await receive() else {
                if buffer.isEmpty { return nil }
                throw HTTPError.malformed
            }
            buffer.append(more)
            headEnd = buffer.range(of: HTTPHead.terminator)
        }
        var (request, bodyLength) = try HTTPHead.parse(buffer[..<headEnd!.lowerBound])
        buffer = Data(buffer[headEnd!.upperBound...])
        while buffer.count < bodyLength {
            guard let more = try await receive() else { throw HTTPError.malformed }
            buffer.append(more)
        }
        request.body = Data(buffer.prefix(bodyLength))
        buffer = Data(buffer.dropFirst(bodyLength))
        return request
    }
}

public struct ResponseWriter: Sendable {
    let peer: Peer
    let method: String

    public func send<Body: AsyncSequence>(_ status: Int, headers: [(String, String)], body: Body) async throws where Body.Element == Data {
        // HEAD, 204 and 304 responses have no body by definition.
        let bodiless = method == "HEAD" || status == 204 || status == 304
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\n"
        for (name, value) in headers where !Hop.response.contains(name.lowercased()) { head += "\(name): \(value)\r\n" }
        head += bodiless ? "\r\n" : "Transfer-Encoding: chunked\r\n\r\n"
        try await peer.send(Data(head.utf8))
        if bodiless { return }
        for try await chunk in body where !chunk.isEmpty {
            try await peer.send(Data("\(String(chunk.count, radix: 16))\r\n".utf8) + chunk + Data("\r\n".utf8))
        }
        try await peer.send(Data("0\r\n\r\n".utf8))
    }

    public func send(_ status: Int, contentType: String = "text/plain; charset=utf-8", text: String) async throws {
        let body = AsyncStream<Data> { $0.yield(Data(text.utf8)); $0.finish() }
        try await send(status, headers: [("Content-Type", contentType)], body: body)
    }

    public func redirect(to url: URL) async throws {
        try await send(302, headers: [("Location", url.absoluteString)], body: AsyncStream<Data> { $0.finish() })
    }
}
