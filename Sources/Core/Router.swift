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

public extension Window {
    /// How long a window of this name is. Providers name a window by its length ("5h", "7d", "90m"); a
    /// limit named otherwise, such as one model's own share of the week, has none to read.
    static func length(named name: String) -> TimeInterval? {
        guard let match = name.wholeMatch(of: /(\d+)([mhd])/), let count = Double(match.1) else { return nil }
        return count * (match.2 == "m" ? 60 : match.2 == "h" ? 3600 : 86400)
    }
}

/// An account as the router sees it: how full its limits are and the resets it holds, all still live.
struct Standing {
    var account: String
    var windows: [Window] = []
    /// The limits on a part of its use, each named for the model it limits.
    var scoped: [Window] = []
    var resets: [Reset] = []

    /// The limits a request for `model` draws on: every window, and a model's own limit where the model's
    /// name has the limit's in it.
    func limits(for model: String?) -> [Window] {
        windows + scoped.filter { model?.lowercased().contains($0.name) == true }
    }
}

/// Decides which account answers and which reset is used. An allowance and a reset are both lost at some
/// time if not used, and the most is had of them by using first what is lost soonest. Pure: time and
/// what the accounts stand at come in as arguments.
struct Router: Codable {
    private struct Hold: Codable {
        var account: String
        var warmUntil: Date
    }

    private var holds: [String: Hold] = [:]

    /// A reset lapsing within this long is used on whatever it refills, rather than lost.
    static let soon: TimeInterval = 6 * 3600
    /// A window shorter than this paces one sitting and is back within hours.
    static let sitting: TimeInterval = 86400

    /// The pool's accounts to try for a request, in order. Its unspent accounts: the one holding this
    /// conversation's warm cache first, then by when what each has left is lost. That is when its longest
    /// window resets, or sooner where a reset it holds lapses first, since that reset gives back what is
    /// used before then. Untouched accounts go last, so an idle window is not started early.
    /// With the whole pool spent, the account back soonest, so the client hears the provider's own refusal.
    func order(_ pool: [Standing], conversation: String?, model: String?, now: Date) -> [String] {
        func back(_ standing: Standing) -> Date? { standing.limits(for: model).filter { $0.used >= 1 }.map(\.resetsAt).max() }
        func lostAt(_ standing: Standing) -> Date {
            let drawn = Set(standing.limits(for: model).map(\.name))
            let lapses = standing.resets.filter { drawn.isEmpty || !drawn.isDisjoint(with: $0.refills) }.compactMap(\.expiresAt)
            return ([standing.windows.map(\.resetsAt).max() ?? .distantFuture] + lapses).min()!
        }

        let open = pool.filter { back($0) == nil }
        guard !open.isEmpty else { return pool.min { back($0)! < back($1)! }.map { [$0.account] } ?? [] }
        var ordered = open.enumerated().sorted { (lostAt($0.element), $0.offset) < (lostAt($1.element), $1.offset) }.map(\.element.account)
        if let conversation, let hold = holds[conversation], hold.warmUntil > now, let held = ordered.firstIndex(of: hold.account) {
            ordered.insert(ordered.remove(at: held), at: 0)
        }
        return ordered
    }

    /// For a pool whose every account refused a request for `model`: the reset to use and the account it
    /// is on. It refills every limit the account has spent. One that lapses before those come back is at
    /// its last chance and goes first; otherwise the one that refills the fewest limits, so that a wider
    /// one is kept for when it is needed; then the soonest to lapse, on the account out longest.
    /// A reset that refills an allowance of days is not spent to skip a sitting's wait.
    func refill(_ pool: [Standing], model: String?, now: Date) -> (account: String, reset: Reset)? {
        func paces(_ name: String) -> Bool { Window.length(named: name).map { $0 < Self.sitting } ?? false }
        let picks = pool.flatMap { standing -> [(account: String, reset: Reset, last: Bool, back: Date)] in
            let spent = standing.limits(for: model).filter { $0.used >= 1 }
            guard let back = spent.map(\.resetsAt).max() else { return [] }
            return standing.resets.compactMap { reset in
                guard reset.usable, spent.allSatisfy({ reset.refills.contains($0.name) }) else { return nil }
                let last = reset.expiresAt.map { $0 < back } ?? false
                guard last || spent.contains(where: { !paces($0.name) }) || reset.refills.allSatisfy(paces) else { return nil }
                return (standing.account, reset, last, back)
            }
        }
        return picks.min {
            ($0.last ? 0 : 1, $0.last ? 0 : $0.reset.refills.count, $0.reset.expiresAt ?? .distantFuture, $1.back)
                < ($1.last ? 0 : 1, $1.last ? 0 : $1.reset.refills.count, $1.reset.expiresAt ?? .distantFuture, $0.back)
        }.map { ($0.account, $0.reset) }
    }

    /// A reset of the account's to use with no request waiting. One that lapses before a spent limit it
    /// refills comes back will never refill more, and is used at once; one within `soon` of lapsing is
    /// used on whatever it refills that is used at all. Its provider takes neither while the account has
    /// spent a limit the reset does not refill.
    func due(_ standing: Standing, now: Date) -> Reset? {
        let limits = standing.windows + standing.scoped, spent = limits.filter { $0.used >= 1 }
        return standing.resets.filter { reset in
            guard reset.usable, let lapses = reset.expiresAt, spent.allSatisfy({ reset.refills.contains($0.name) }) else { return false }
            return spent.contains { lapses < $0.resetsAt }
                || lapses.timeIntervalSince(now) <= Self.soon && limits.contains { $0.used > 0 && reset.refills.contains($0.name) }
        }
        .min { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
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
