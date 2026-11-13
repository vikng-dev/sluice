import Foundation

/// Which reset is used without the user being asked. Pure: limits, resets and time come in as arguments.
enum Refill {
    /// An account by the limits it has now and the resets it holds.
    struct Holder {
        var account: String
        var limits: [Window]
        var resets: [Reset]
    }

    /// A reset lapsing within this long is used rather than lost.
    static let soon: TimeInterval = 6 * 3600

    /// For a pool that is out: a reset that refills every limit an account has spent. Of those, the one
    /// that refills the fewest limits, so that none is spent on what was not used; then the soonest to
    /// lapse; then on the account that would otherwise be out longest.
    static func forSpent(_ pool: [Holder], now: Date) -> (account: String, reset: Reset)? {
        let picks = pool.flatMap { holder -> [(account: String, reset: Reset, back: Date)] in
            let spent = holder.limits.filter { $0.used >= 1 }
            guard let back = spent.map(\.resetsAt).max() else { return [] }
            return holder.resets.filter { reset in reset.usable && spent.allSatisfy { reset.refills.contains($0.name) } }.map { (holder.account, $0, back) }
        }
        return picks.min {
            ($0.reset.refills.count, $0.reset.expiresAt ?? .distantFuture, $1.back) < ($1.reset.refills.count, $1.reset.expiresAt ?? .distantFuture, $0.back)
        }.map { ($0.account, $0.reset) }
    }

    /// A reset of the account's that lapses soon and would refill something it has used.
    static func lapsing(_ holder: Holder, now: Date) -> Reset? {
        let used = holder.limits.filter { $0.used > 0 }.map(\.name)
        return holder.resets.first { reset in
            reset.usable && reset.expiresAt.map { $0.timeIntervalSince(now) <= soon } == true && reset.refills.contains { used.contains($0) }
        }
    }
}
