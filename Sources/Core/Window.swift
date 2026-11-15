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
    var percentText: String { used.percentText }
}

extension Date {
    /// To the minute: the same reset is reported a second or so apart from one answer to the next.
    var settled: Date { Date(timeIntervalSinceReferenceDate: (timeIntervalSinceReferenceDate / 60).rounded() * 60) }
}

public extension Date {
    /// A time to come, as a person reads it: the time when that is today, or the weekday and time.
    var timeText: String {
        settled.formatted(Calendar.current.isDateInToday(settled) ? Date.FormatStyle(date: .omitted, time: .shortened) : Date.FormatStyle().weekday(.abbreviated).hour().minute())
    }

    /// How long until it, in its largest units, two unless told one, and without a second that is nought:
    /// "4d 20h", "1d", "3h 5m", "12m"; in one, "4d".
    func leftText(now: Date, units: Int = 2) -> String {
        let minutes = max(0, Int((timeIntervalSince(now) / 60).rounded()))
        let (days, hours) = (minutes / 1440, minutes / 60 % 24)
        let parts = days > 0 ? [(days, "d"), (hours, "h")] : hours > 0 ? [(hours, "h"), (minutes % 60, "m")] : [(minutes, "m")]
        return parts.prefix(units).enumerated().filter { $0.offset == 0 || $0.element.0 > 0 }.map { "\($0.element.0)\($0.element.1)" }.joined(separator: " ")
    }
}

public extension [Window] {
    /// The window that resets last, read as how much of the account is left.
    var budget: Window? { self.max { $0.resetsAt < $1.resetsAt } }
}

public extension Window {
    /// How long a window of this name is. Providers name a window by its length ("5h", "7d", "90m"); a
    /// limit named otherwise, such as one model's own share of the week, has none to read.
    static func length(named name: String) -> TimeInterval? {
        guard let match = name.wholeMatch(of: /(\d+)([mhd])/), let count = Double(match.1) else { return nil }
        return count * (match.2 == "m" ? 60 : match.2 == "h" ? 3600 : 86400)
    }
}

extension Window {
    var settled: Window { Window(name: name, used: used, resetsAt: resetsAt.settled) }
}

public extension Double {
    /// A share as a whole percentage.
    var percentText: String { "\(Int((self * 100).rounded()))%" }
}
