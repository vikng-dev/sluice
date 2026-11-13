import Foundation

/// What an account's windows read at one moment. Each is a line of `readings.jsonl`, which only grows:
/// how full a window was is not something a provider can be asked again.
public struct Sample: Codable, Sendable, Equatable {
    public var at: Date
    public var provider: String
    public var account: String
    public var windows: [Window]
}

/// What one answer cost the account that gave it, as its provider counted it: the tokens read new, read
/// from the cache, written to it, and written out.
public struct Spend: Codable, Sendable, Equatable {
    public var model: String?
    public var input = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public var output = 0

    public init() {}
}

/// A request an account answered, and for whose work. Each that cost anything is a line of
/// `requests.jsonl`. Like a reading it is numbers, and never what was asked or answered.
public struct Served: Codable, Sendable, Equatable {
    public var at: Date
    public var provider: String
    public var account: String
    public var profile: String
    public var spend: Spend
}

extension Window {
    /// The same reset is reported a second or so apart from one answer to the next.
    var settled: Window {
        Window(name: name, used: used, resetsAt: Date(timeIntervalSinceReferenceDate: (resetsAt.timeIntervalSinceReferenceDate / 60).rounded() * 60))
    }
}

/// Adds a line to a history file, which is made on the first.
func append(_ entry: some Encodable, to file: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let line = try encoder.encode(entry) + Data("\n".utf8)
    if !FileManager.default.fileExists(atPath: file.path) {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try line.write(to: file)
    }
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
}

/// Reads what an answer cost out of its body as it passes, an event at a time: a stream says it in
/// events, each a line, and an answer in one piece is one event. It keeps the count and nothing else.
struct Meter {
    /// Reads one event's JSON into the count. Asked only of events that speak of usage.
    let count: @Sendable (Data, inout Spend) -> Void
    private(set) var spend = Spend()
    private var line = Data()

    init(count: @escaping @Sendable (Data, inout Spend) -> Void) {
        self.count = count
    }

    mutating func read(_ chunk: Data) {
        var rest = chunk[...]
        while let end = rest.firstIndex(of: UInt8(ascii: "\n")) {
            line.append(rest[..<end])
            event()
            rest = rest[rest.index(after: end)...]
        }
        line.append(rest)
    }

    /// The body is over, and what is left of it is its last event.
    mutating func finish() {
        event()
    }

    private mutating func event() {
        defer { line.removeAll(keepingCapacity: true) }
        // A quote inside a JSON string is escaped, so this is only ever a key.
        guard let start = line.firstIndex(of: UInt8(ascii: "{")), line.range(of: Data(#""usage""#.utf8)) != nil else { return }
        count(Data(line[start...]), &spend)
    }
}

/// A response body that is counted as it passes. What it cost is told once, when the body has been
/// read or is let go of unread: an answer cut short was paid for as far as it got.
struct Metered<Base: AsyncSequence>: AsyncSequence where Base.Element == Data {
    typealias Element = Data
    let base: Base
    let count: @Sendable (Data, inout Spend) -> Void
    let done: @Sendable (Spend) -> Void

    func makeAsyncIterator() -> Iterator {
        Iterator(base: base.makeAsyncIterator(), meter: Meter(count: count), done: done)
    }

    final class Iterator: AsyncIteratorProtocol {
        private var base: Base.AsyncIterator
        private var meter: Meter
        private let done: @Sendable (Spend) -> Void

        init(base: Base.AsyncIterator, meter: Meter, done: @escaping @Sendable (Spend) -> Void) {
            self.base = base
            self.meter = meter
            self.done = done
        }

        func next() async throws -> Data? {
            guard let chunk = try await base.next() else { return nil }
            meter.read(chunk)
            return chunk
        }

        deinit {
            meter.finish()
            done(meter.spend)
        }
    }
}
