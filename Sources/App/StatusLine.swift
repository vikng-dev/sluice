import SluiceCore
import SluiceProviders
import SwiftUI

extension StatusLine.Pool {
    /// One profile's pool as it stands, with what its last day of readings says of today and of how long it lasts.
    init(_ accounts: [AccountStatus], profile: String, config: Config, samples: [Sample], now: Date) {
        let total = accounts.map(\.size).reduce(0, +), today = Calendar.current.startOfDay(for: now)
        let burn = accounts.burn(samples, now: now)
        self.init(
            profile: config.shown(profile), tint: config.profiles[profile]?.color, used: accounts.used,
            resetsAt: accounts.compactMap(\.budget?.resetsAt).min(),
            dry: burn.flatMap { accounts.dry(burn: $0, now: now) },
            account: accounts.filter { $0.lastAnswered != nil }.max { $0.lastAnswered! < $1.lastAnswered! }?.label,
            today: total > 0 ? accounts.map { account in
                Forecast.rises(account.samples(in: samples)).filter { $0.at >= today }.map(\.by).reduce(0, +) * account.size / total
            }.reduce(0, +) : nil
        )
    }
}

private extension Tint {
    /// Its colour among a terminal's 256.
    var terminal: Int {
        switch self {
        case .pink: 212
        case .purple: 141
        case .indigo: 105
        case .blue: 75
        case .aqua: 81
        case .teal: 44
        case .sand: 180
        case .slate: 110
        }
    }
}

extension StatusLine.Tone {
    fileprivate var terminal: Int? {
        switch self {
        case .plain: nil
        case .dim: 245
        case .faint: 238
        case .fill: 33
        case .warning: 208
        case .critical: 196
        case .tint(let tint): tint?.terminal ?? 245
        }
    }

    var color: Color {
        switch self {
        case .plain: .primary
        case .dim: .secondary
        case .faint: Color.primary.opacity(0.25)
        case .fill: .blue
        case .warning: .orange
        case .critical: .red
        case .tint(let tint): tint?.color ?? .secondary
        }
    }
}

/// The line as a terminal shows it.
func terminalText(_ line: [[StatusLine.Run]]) -> String {
    line.map { $0.map { run in run.tone.terminal.map { "\u{1B}[38;5;\($0)m\(run.text)\u{1B}[0m" } ?? run.text }.joined() }.joined(separator: StatusLine.separator)
}

extension StatusLine.Item {
    var about: (title: String, says: String) {
        switch self {
        case .profile: ("Profile", "The profile's name, after a dot in its color")
        case .bar: ("Bar", "How much of the pool is used, as a bar")
        case .share: ("Share", "How much of the pool is used, as a number")
        case .reset: ("Reset", "How long until any of the pool comes back")
        case .dry: ("Dry", "When the pool runs out at the rate it is going; nothing while it lasts")
        case .account: ("Account", "The account that answered last")
        case .today: ("Today", "Today's use, against the pace that uses the pool up in a week")
        }
    }
}
