import Foundation

/// What an account's windows read at one moment. Each is a line of the history, which only grows: how
/// full a window was is not something a provider can be asked again. It holds numbers and never a prompt.
public struct Sample: Codable, Sendable, Equatable {
    public var at: Date
    public var provider: String
    public var account: String
    public var windows: [Window]
}

extension Window {
    /// The same reset is reported a second or so apart from one answer to the next.
    var settled: Window {
        Window(name: name, used: used, resetsAt: Date(timeIntervalSinceReferenceDate: (resetsAt.timeIntervalSinceReferenceDate / 60).rounded() * 60))
    }
}

/// Adds a line to the history file, which is made on the first.
func append(_ sample: Sample, to file: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let line = try encoder.encode(sample) + Data("\n".utf8)
    if !FileManager.default.fileExists(atPath: file.path) {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try line.write(to: file)
    }
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
}
