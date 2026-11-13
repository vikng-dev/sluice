import Charts
import SluiceCore
import SwiftUI

/// The histories as read from disk: every reading and every answered request, oldest first.
struct History: Sendable {
    var samples: [Sample] = []
    var requests: [Served] = []
}

extension Served {
    var tokens: Int { spend.input + spend.cacheRead + spend.cacheWrite + spend.output }
}

private extension Int {
    /// As few figures as say it: 6.9M.
    var compact: String { formatted(.number.notation(.compactName)) }
}

private extension View {
    func card() -> some View {
        frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The last week of use: each profile's accounts over time with how fast each pool is going and how long it
/// lasts, then when the work was done and where it went.
struct UsageView: View {
    let accounts: [AccountStatus]
    let config: Config
    let titles: [String: String]
    let history: History
    let now: Date

    private var since: Date { now.addingTimeInterval(-7 * 86400) }

    var body: some View {
        let requests = history.requests.filter { $0.at >= since }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(config.names, id: \.self) { profile in
                let pools = Dictionary(grouping: accounts.filter { $0.profile == profile }, by: \.provider).sorted { $0.key < $1.key }
                if !pools.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Circle().fill(config.profiles[profile]?.color?.color ?? Color.secondary.opacity(0.4)).frame(width: 7, height: 7).frame(width: 11)
                            Text(config.shown(profile)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        ProfileUsage(
                            pools: pools.map { ($0.key, $0.value.sorted { $0.label < $1.label }) }, titles: titles,
                            samples: history.samples.filter { $0.at >= since }, requests: requests, since: since, now: now
                        )
                        .card()
                    }
                    .padding(.top, 4)
                }
            }
            if requests.isEmpty {
                Text("No requests counted yet").font(.callout).foregroundStyle(.secondary).card()
            } else {
                Hours(requests: requests, now: now).card()
                VStack(alignment: .leading, spacing: 12) {
                    Shares(title: "Folders", parts: requests.map { ($0.folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unknown", $0.folder ?? "The caller's folder could not be read", $0.tokens) })
                    Shares(title: "Models", parts: requests.map { ($0.spend.model ?? "unknown", "", $0.tokens) })
                }
                .card()
            }
        }
    }
}

/// One profile over the week: every account's week as a line on one chart, then for each pool how fast it
/// is going and how long it lasts, and what each of its accounts has given for a point of its week.
private struct ProfileUsage: View {
    let pools: [(provider: String, accounts: [AccountStatus])]
    let titles: [String: String]
    let samples: [Sample]
    let requests: [Served]
    let since: Date
    let now: Date

    private static let tints: [Color] = [.blue, .orange, .green, .purple, .pink, .teal]

    /// Every account of the profile with the colour of its line.
    private var lines: [(account: AccountStatus, tint: Color)] {
        pools.flatMap(\.accounts).enumerated().map { ($1, Self.tints[$0 % Self.tints.count]) }
    }

    private func samples(of account: AccountStatus) -> [Sample] {
        samples.filter { $0.provider == account.provider && $0.account == account.label }
    }

    /// The pool's share used per hour over the last day.
    private func burn(of pool: [AccountStatus]) -> Double? {
        let day = now.addingTimeInterval(-86400)
        return Forecast.burn(pool.map { account in (samples(of: account).filter { $0.at >= day }, account.weight) }, from: day, to: now)
    }

    /// An account's week as points: each reading, and what it reads now.
    private func line(of account: AccountStatus) -> [(at: Date, used: Double)] {
        samples(of: account).compactMap { sample in sample.windows.budget.map { (sample.at, $0.used) } }
            + (account.budget.map { [(now, $0.used)] } ?? [])
    }

    /// The tokens the account answered with for each point its week rose, once it has risen a point.
    private func given(by account: AccountStatus) -> Int? {
        let points = Forecast.rise(samples(of: account)) * 100
        let tokens = requests.filter { $0.provider == account.provider && $0.account == account.label }.map(\.tokens).reduce(0, +)
        return points >= 1 && tokens > 0 ? Int(Double(tokens) / points) : nil
    }

    var body: some View {
        // Two accounts may go by one address, at a provider where a person and an organisation share it.
        let lines = lines, tints = Dictionary(lines.map { ($0.account.id, $0.tint) }) { first, _ in first }
        VStack(alignment: .leading, spacing: 10) {
            Chart {
                ForEach(lines, id: \.account.id) { account, tint in
                    ForEach(Array(line(of: account).enumerated()), id: \.offset) { _, point in
                        LineMark(x: .value("Time", point.at), y: .value("Used", point.used * 100), series: .value("Account", account.id))
                            .interpolationMethod(.stepEnd)
                            .foregroundStyle(tint)
                    }
                }
            }
            .chartXScale(domain: since...now)
            .chartYScale(domain: 0...100)
            .chartXAxis { AxisMarks(values: .stride(by: .day)) { AxisGridLine(); AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
            .chartYAxis { AxisMarks(values: [0, 50, 100]) { AxisGridLine(); AxisValueLabel() } }
            .chartLegend(.hidden)
            .frame(height: 84)
            ForEach(pools, id: \.provider) { provider, pool in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        if let mark = providerMark(provider) {
                            Image(nsImage: mark).resizable().frame(width: 13, height: 13).foregroundStyle(.secondary)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                        }
                        Text(titles[provider] ?? provider).font(.callout.weight(.semibold))
                        Spacer()
                        if let burn = burn(of: pool) {
                            Text("\((burn * 100).formatted(.number.precision(.fractionLength(1))))%/h").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .help("How much of the pool was used per hour over the last day")
                            let members = pool.map { Member(weight: $0.weight, used: $0.budget?.used ?? 0, resetsAt: $0.budget?.resetsAt) }
                            if let dry = Forecast.dry(members, burn: burn, now: now) {
                                HStack(spacing: 3) {
                                    Text("dry").font(.caption).foregroundStyle(dry <= now ? Color.red : .orange)
                                    if dry > now { Clock(window: Window(name: "", used: 1, resetsAt: dry), now: now) }
                                }
                                .help("At this rate the pool has nothing left then, counting what comes back at each reset")
                            } else {
                                Text("holds").font(.caption).foregroundStyle(.secondary).help("At this rate the pool lasts the week")
                            }
                        } else {
                            Text("watching").font(.caption).foregroundStyle(.tertiary).help("Not watched long enough to say how fast it is going")
                        }
                    }
                    ForEach(pool, id: \.id) { account in
                        HStack(spacing: 6) {
                            Capsule().fill(tints[account.id] ?? .secondary).frame(width: 10, height: 3)
                            Text(account.label).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if let given = given(by: account) {
                                Text("\(given.compact) / 1%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .help("Tokens it answered with through Sluice for each point of its week. Rough until it has risen a few points, and low where the account is also used outside Sluice.")
                            }
                        }
                    }
                }
            }
        }
    }
}

/// When the work was done: the tokens of each hour of the last seven days.
private struct Hours: View {
    let requests: [Served]
    let now: Date

    var body: some View {
        let calendar = Calendar.current, today = calendar.startOfDay(for: now)
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0 - 6, to: today) }
        let cells = Dictionary(grouping: requests) { calendar.dateInterval(of: .hour, for: $0.at)?.start ?? $0.at }.mapValues { $0.map(\.tokens).reduce(0, +) }
        let most = Double(cells.values.max() ?? 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Hours").font(.callout.weight(.semibold))
                Spacer()
                Text("\(requests.map(\.tokens).reduce(0, +).compact) tokens").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            VStack(spacing: 2) {
                ForEach(days, id: \.self) { day in
                    HStack(spacing: 2) {
                        Text(day.formatted(.dateTime.weekday(.narrow))).font(.caption2).foregroundStyle(.tertiary).frame(width: 12, alignment: .leading)
                        ForEach(0..<24, id: \.self) { hour in
                            let start = calendar.date(byAdding: .hour, value: hour, to: day) ?? day
                            let tokens = cells[start] ?? 0
                            RoundedRectangle(cornerRadius: 2)
                                .fill(tokens > 0 ? Color.accentColor.opacity(0.25 + 0.75 * Double(tokens) / most) : Color.primary.opacity(0.06))
                                .frame(height: 9)
                                .help("\(start.formatted(.dateTime.weekday(.abbreviated).hour())): \(tokens.compact)")
                        }
                    }
                }
                HStack(spacing: 2) {
                    Text("").frame(width: 12)
                    ForEach([0, 6, 12, 18], id: \.self) { Text("\($0)").font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
        }
    }
}

/// Where the work went: the five largest of some kind, by tokens.
private struct Shares: View {
    let title: String
    /// What each request is counted under, what to say about that, and its tokens.
    let parts: [(name: String, about: String, tokens: Int)]

    var body: some View {
        let totals = Dictionary(grouping: parts, by: \.name).map { (name: $0.key, about: $0.value[0].about, tokens: $0.value.map(\.tokens).reduce(0, +)) }
            .sorted { $0.tokens > $1.tokens }.prefix(5)
        let most = Double(totals.first?.tokens ?? 1)
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.semibold))
            ForEach(totals, id: \.name) { part in
                HStack(spacing: 8) {
                    Text(part.name).font(.caption).lineLimit(1).truncationMode(.middle).frame(width: 130, alignment: .leading).help(part.about)
                    GeometryReader { space in
                        Capsule().fill(Color.accentColor).frame(width: max(3, space.size.width * Double(part.tokens) / most))
                    }
                    .frame(height: 5)
                    Text(part.tokens.compact).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                }
            }
        }
    }
}
