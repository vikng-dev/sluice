import Foundation

/// One account of a pool, as far as how long the pool lasts goes.
public struct Member: Sendable, Equatable {
    /// How large its allowance is beside the others'.
    public var weight: Double
    /// How much of its budget window is used; 0 when untouched.
    public var used: Double
    /// Nil while the window has not started.
    public var resetsAt: Date?

    public init(weight: Double, used: Double, resetsAt: Date?) {
        self.weight = weight
        self.used = used
        self.resetsAt = resetsAt
    }
}

/// How fast a pool is used and how long it lasts. Pure: the history and the time come in as arguments.
public enum Forecast {
    /// A budget window is taken to be a week long.
    static let week: TimeInterval = 7 * 86400

    /// How much an account's budget window rose over its samples, in order of time. A fall within one
    /// window is the provider rounding, not use given back, so only a new high counts; a new window
    /// counts from nothing.
    public static func rise(_ samples: [Sample]) -> Double {
        var rise = 0.0, high = 0.0, reset: Date?
        for (index, sample) in samples.enumerated() {
            guard let budget = sample.windows.max(by: { $0.resetsAt < $1.resetsAt }) else { continue }
            if budget.resetsAt != reset {
                reset = budget.resetsAt
                // What was used before the first sample was not used in this time.
                high = index == 0 ? budget.used : 0
            }
            if budget.used > high {
                rise += budget.used - high
                high = budget.used
            }
        }
        return rise
    }

    /// The share of a pool used per hour between `start` and `now`: each account's samples from that
    /// time, in order, and its weight. Nil when less than half an hour was watched.
    public static func burn(_ accounts: [(samples: [Sample], weight: Double)], from start: Date, to now: Date) -> Double? {
        let total = accounts.map(\.weight).reduce(0, +)
        guard let first = accounts.compactMap(\.samples.first?.at).min(), total > 0 else { return nil }
        let hours = now.timeIntervalSince(max(first, start)) / 3600
        guard hours >= 0.5 else { return nil }
        return accounts.map { rise($0.samples) * $0.weight }.reduce(0, +) / total / hours
    }

    /// When a pool used at `burn` (its share per hour) has nothing left, or nil when it lasts the week.
    /// It is used as the router uses it, the account that resets soonest first, and an account is whole
    /// again at its reset.
    public static func dry(_ members: [Member], burn: Double, now: Date) -> Date? {
        let total = members.map(\.weight).reduce(0, +)
        guard burn > 0, total > 0 else { return nil }
        var pool = members.map { (left: $0.weight / total * (1 - min($0.used, 1)), whole: $0.weight / total, reset: $0.resetsAt ?? .distantFuture) }
        var time = now
        while time < now + week {
            guard let next = pool.indices.filter({ pool[$0].left > 0 }).min(by: { pool[$0].reset < pool[$1].reset }) else { return time }
            let drained = time + pool[next].left / burn * 3600
            // Every reset is still to come: one that came was moved a week on.
            let reset = pool.map(\.reset).min() ?? .distantFuture
            if drained <= reset {
                pool[next].left = 0
                time = drained
            } else {
                pool[next].left -= burn * reset.timeIntervalSince(time) / 3600
                time = reset
                for index in pool.indices where pool[index].reset <= time {
                    pool[index].left = pool[index].whole
                    pool[index].reset = time + week
                }
            }
        }
        return nil
    }
}
