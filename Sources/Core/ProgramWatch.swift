import Foundation

/// A running program's view of its own file, so that it can act when an upgrade replaces the file
/// or an uninstall removes it. Files are told apart by the number the file system gives them.
public struct ProgramWatch {
    public enum Verdict: Equatable {
        case stay
        /// A different file is in place: start again from it.
        case restart
        /// The file is gone for good: there is nothing to run again.
        case leave
    }

    /// How long a missing file may be on its way back; an upgrade moves the old one out before the new one in.
    public static let patience: TimeInterval = 60

    private let launched: UInt64?
    private var missingSince: Date?

    public init(launched: UInt64?) {
        self.launched = launched
    }

    /// `found` is the file there now, nil when there is none.
    public mutating func verdict(found: UInt64?, now: Date) -> Verdict {
        guard let found else {
            let since = missingSince ?? now
            missingSince = since
            return now.timeIntervalSince(since) >= Self.patience ? .leave : .stay
        }
        missingSince = nil
        return found == launched ? .stay : .restart
    }
}
