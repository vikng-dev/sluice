import Foundation

/// The line a client shows under its prompt: what Sluice says there of the pool that pays for the client's work.
public enum StatusLine {
    /// One thing the line can say. Which are said, and in what order, is the user's.
    public enum Item: String, Codable, Sendable, CaseIterable {
        case profile, bar, share, reset, dry, account, today
    }

    /// What is said until the user picks.
    public static let usual: [Item] = [.profile, .bar, .share, .reset, .dry]

    /// How a part of the line is to look, which is for whatever shows it to turn into color.
    public enum Tone: Sendable, Equatable {
        case plain, dim, faint, fill, warning, critical
        case tint(Tint?)
    }

    public typealias Run = (text: String, tone: Tone)

    /// What the line is about: one profile's pool at one provider.
    public struct Pool: Sendable {
        public var profile: String
        public var tint: Tint?
        public var used: Double
        /// The soonest that any of it comes back; nil while no week has started.
        public var resetsAt: Date?
        /// When it has nothing left at the rate it is going; nil when it lasts.
        public var dry: Date?
        /// The account that answered last.
        public var account: String?
        /// The share of it used today; nil where that is not known.
        public var today: Double?

        public init(profile: String, tint: Tint?, used: Double, resetsAt: Date?, dry: Date?, account: String?, today: Double?) {
            (self.profile, self.tint, self.used, self.resetsAt, self.dry, self.account, self.today) = (profile, tint, used, resetsAt, dry, account, today)
        }
    }

    /// The tone that warns of a share nearly or wholly gone; nil while there is room.
    public static func alarm(_ used: Double) -> Tone? { used >= 1 ? .critical : used >= 0.85 ? .warning : nil }

    /// What each item says of the pool, in the order given. An item with nothing to say is left out.
    public static func runs(_ items: [Item], of pool: Pool, now: Date) -> [[Run]] {
        func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }
        return items.compactMap { item -> [Run]? in
            switch item {
            case .profile: return [("● ", .tint(pool.tint)), (pool.profile, .plain)]
            case .bar:
                let filled = Int((min(pool.used, 1) * 8).rounded())
                return [(String(repeating: "━", count: filled), alarm(pool.used) ?? .fill), (String(repeating: "━", count: 8 - filled), .faint)]
            case .share: return [(percent(pool.used), alarm(pool.used) ?? .plain)]
            case .reset: return pool.resetsAt.map { [($0.leftText(now: now), .dim)] }
            case .dry: return pool.dry.map { $0 <= now ? [("dry", .critical)] : [("dry ", .warning), ($0.leftText(now: now, units: 1), .dim)] }
            case .account: return pool.account.map { [($0, .dim)] }
            case .today: return pool.today.map { [("today ", .dim), (percent($0), .plain), (" of \(percent(Forecast.pace))", .dim)] }
            }
        }
    }
}

/// A provider whose client shows a line under its prompt that a command of the user's writes.
public protocol StatusShowing: Provider {
    /// Has the client run `program` for that line in each profile, or with nil no longer. A line the
    /// user set there themselves is left as it is: the profiles where one was are returned.
    @discardableResult func showStatus(by program: URL?, profiles: [String]) throws -> [String]
}

public extension StatusShowing {
    /// What Sluice is run with to write this provider's line.
    var statusArguments: String { "statusline \(id)" }
}
