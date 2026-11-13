import Foundation

/// One of an account's usage windows, as its provider last reported it.
public struct Window: Sendable, Codable, Equatable {
    public var name: String
    /// 0 is untouched, 1 is spent.
    public var used: Double
    public var resetsAt: Date

    public init(name: String, used: Double, resetsAt: Date) {
        self.name = name
        self.used = used
        self.resetsAt = resetsAt
    }
}

public extension Window {
    /// When the window resets, as a person reads it: the time when that is today, or the weekday and time.
    var resetText: String {
        let resetsAt = settled.resetsAt
        return resetsAt.formatted(Calendar.current.isDateInToday(resetsAt) ? Date.FormatStyle(date: .omitted, time: .shortened) : Date.FormatStyle().weekday(.abbreviated).hour().minute())
    }

    /// How long until the window resets, in its two largest units and without one that is nought:
    /// "4d 20h", "1d", "3h 5m", "12m".
    func leftText(now: Date) -> String {
        let minutes = max(0, Int((resetsAt.timeIntervalSince(now) / 60).rounded()))
        let (days, hours) = (minutes / 1440, minutes / 60 % 24)
        let parts = days > 0 ? [(days, "d"), (hours, "h")] : hours > 0 ? [(hours, "h"), (minutes % 60, "m")] : [(minutes, "m")]
        return parts.enumerated().filter { $0.offset == 0 || $0.element.0 > 0 }.map { "\($0.element.0)\($0.element.1)" }.joined(separator: " ")
    }

    var percentText: String { "\(Int((used * 100).rounded()))%" }
}

/// Decides which account answers. Pure: time and usage come in as arguments.
struct Router: Codable {
    private struct Hold: Codable {
        var account: String
        var warmUntil: Date
    }

    private var holds: [String: Hold] = [:]

    /// The pool's accounts to try, in order. Its unspent accounts: the one holding this conversation's warm cache first, then by whose longest
    /// window resets soonest, untouched accounts last so an idle window is not started early.
    /// With the whole pool spent, the account back soonest, so the client hears the provider's own refusal.
    func order(_ pool: [Account], conversation: String?, usage: [String: [Window]], now: Date) -> [Account] {
        func live(_ account: Account) -> [Window] { (usage[account.id] ?? []).filter { $0.resetsAt > now } }
        func spentUntil(_ account: Account) -> Date? { live(account).filter { $0.used >= 1 }.map(\.resetsAt).max() }
        func horizon(_ account: Account) -> Date { live(account).map(\.resetsAt).max() ?? .distantFuture }

        let open = pool.filter { spentUntil($0) == nil }
        guard !open.isEmpty else { return pool.min { spentUntil($0)! < spentUntil($1)! }.map { [$0] } ?? [] }
        var ordered = open.enumerated().sorted { (horizon($0.element), $0.offset) < (horizon($1.element), $1.offset) }.map(\.element)
        if let conversation, let hold = holds[conversation], hold.warmUntil > now, let held = ordered.firstIndex(where: { $0.id == hold.account }) {
            ordered.insert(ordered.remove(at: held), at: 0)
        }
        return ordered
    }

    /// `account` answered `conversation`, whose prompt cache now lives there for `lifetime`.
    mutating func served(_ conversation: String, by account: String, cacheLifetime lifetime: TimeInterval, now: Date) {
        holds = holds.filter { $0.value.warmUntil > now }
        holds[conversation] = Hold(account: account, warmUntil: now.addingTimeInterval(lifetime))
    }

    func warmConversations(on account: String, now: Date) -> Int {
        holds.values.count { $0.account == account && $0.warmUntil > now }
    }
}
