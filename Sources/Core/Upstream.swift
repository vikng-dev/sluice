import Foundation

/// Streams one request to a provider and its response back, chunk by chunk as it arrives.
final class Upstream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Exchange {
        var head: CheckedContinuation<HTTPURLResponse, any Error>?
        let body: AsyncThrowingStream<Data, any Error>.Continuation
    }

    private let lock = NSLock()
    private var exchanges: [Int: Exchange] = [:]
    private var session: URLSession!

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        // A model can think for minutes between bytes.
        configuration.timeoutIntervalForRequest = 900
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
        let (stream, body) = AsyncThrowingStream<Data, any Error>.makeStream()
        let task = session.dataTask(with: request)
        body.onTermination = { _ in task.cancel() }
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { head in
                lock.withLock { exchanges[task.taskIdentifier] = Exchange(head: head, body: body) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return (response, stream)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        let head = lock.withLock { () -> CheckedContinuation<HTTPURLResponse, any Error>? in
            defer { exchanges[dataTask.taskIdentifier]?.head = nil }
            return exchanges[dataTask.taskIdentifier]?.head
        }
        // Only http(s) URLs are ever requested, so the response is an HTTPURLResponse.
        head?.resume(returning: response as! HTTPURLResponse)
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { exchanges[dataTask.taskIdentifier] }?.body.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let exchange = lock.withLock({ exchanges.removeValue(forKey: task.taskIdentifier) }) else { return }
        exchange.head?.resume(throwing: error ?? URLError(.badServerResponse))
        exchange.body.finish(throwing: error)
    }

    /// A redirect is the client's to follow, so it is relayed, not taken.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
