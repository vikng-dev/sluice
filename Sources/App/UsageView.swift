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

/// The last seven days of use: how much of each profile's pools each day used and how long they last at
/// the rate they are going, then when the work was done and where it went.
struct UsageView: View {
    let now: Date
    @Environment(Running.self) private var running

    var body: some View {
        let accounts = running.accounts, config = running.config, history = running.history
        let today = Calendar.current.startOfDay(for: now)
        let days = (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0 - 6, to: today) }
        let requests = history.requests.filter { $0.at >= days[0] }, samples = history.samples.filter { $0.at >= days[0] }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(config.names, id: \.self) { profile in
                let pools = Dictionary(grouping: accounts.filter { $0.profile == profile }, by: \.provider).sorted { $0.key < $1.key }
                if !pools.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Dot(tint: config.profiles[profile]?.color).frame(width: 11)
                            Text(config.shown(profile)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(pools, id: \.key) { provider, pool in
                                PoolUsage(title: running.titles[provider] ?? provider, provider: provider, pool: pool.sorted { $0.label < $1.label }, samples: samples, days: days, now: now)
                            }
                        }
                        .card()
                    }
                    .padding(.top, 4)
                }
            }
            if requests.isEmpty {
                Text("No requests counted yet").font(.callout).foregroundStyle(.secondary).card()
            } else {
                Hours(requests: requests, days: days).card()
                VStack(alignment: .leading, spacing: 12) {
                    Shares(title: "Folders", parts: requests.map { ($0.folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unknown", $0.folder ?? "", $0.tokens) })
                    Shares(title: "Models", parts: requests.map { ($0.spend.model ?? "unknown", "", $0.tokens) })
                }
                .card()
            }
        }
    }
}

/// One pool over the days: how much of it each day used, a bar in the colours of the accounts that gave
/// it, against the pace that uses it all; over them how fast it is going now, and when that runs it dry.
private struct PoolUsage: View {
    let title: String
    let provider: String
    let pool: [AccountStatus]
    let samples: [Sample]
    let days: [Date]
    let now: Date

    private static let tints: [Color] = [.blue, .orange, .green, .purple, .pink, .teal]
    private static let height = 56.0

    private func samples(of account: AccountStatus) -> [Sample] {
        samples.filter { $0.provider == account.provider && $0.account == account.label }
    }

    private func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }

    var body: some View {
        let total = pool.map(\.size).reduce(0, +)
        // Each account with its colour and the share of the pool it gave each day.
        let parts = pool.enumerated().map { index, account in
            (label: account.label, tint: Self.tints[index % Self.tints.count], days: Dictionary(
                Forecast.rises(samples(of: account)).map { (Calendar.current.startOfDay(for: $0.at), $0.by * account.size / total) }, uniquingKeysWith: +
            ))
        }
        let top = max(days.map { day in parts.map { $0.days[day] ?? 0 }.reduce(0, +) }.max() ?? 0, 2 * Forecast.pace)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                PoolTitle(provider: provider, title: title)
                Spacer()
                if let burn = pool.burn(samples, now: now) {
                    let members = pool.map { Member(size: $0.size, used: $0.budget?.used ?? 0, resetsAt: $0.budget?.resetsAt) }
                    if let dry = Forecast.dry(members, burn: burn, now: now) {
                        HStack(spacing: 3) {
                            Text("dry").font(.caption).foregroundStyle(dry <= now ? Color.red : .orange)
                            if dry > now { Clock(at: dry, now: now) }
                        }
                        .help("At this rate the pool has nothing left then, counting what comes back at each reset")
                    }
                    Text("\(percent(burn * 24))/day").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .help("How much of the pool was used over the last 24 hours")
                }
            }
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(days, id: \.self) { day in
                    let spent = parts.map { $0.days[day] ?? 0 }, all = spent.reduce(0, +)
                    VStack(spacing: 4) {
                        VStack(spacing: 0) {
                            ForEach(Array(parts.indices.reversed()), id: \.self) { index in
                                let height = Self.height * spent[index] / top
                                // A gap parts it from the one it stands on.
                                Rectangle().fill(parts[index].tint).frame(height: max(height - (index > 0 ? 1.5 : 0), 0)).padding(.bottom, index > 0 && height > 1.5 ? 1.5 : 0)
                            }
                        }
                        .frame(width: 18)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3))
                        .frame(height: Self.height, alignment: .bottom)
                        Text(day.formatted(.dateTime.weekday(.narrow))).font(.caption2).foregroundStyle(day == days.last ? .secondary : .tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .tip {
                        Readout(about: day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)), figure: percent(all), unit: "\((all / Forecast.pace).formatted(.number.precision(.fractionLength(1))))× pace")
                        if parts.count > 1 {
                            ForEach(parts.indices, id: \.self) { index in
                                HStack(spacing: 6) {
                                    Capsule().fill(parts[index].tint).frame(width: 10, height: 3)
                                    Text(parts[index].label).font(.caption).foregroundStyle(.secondary)
                                    Spacer(minLength: 12)
                                    Text(percent(spent[index])).font(.caption.monospacedDigit())
                                }
                            }
                        }
                    }
                }
            }
            .overlay(alignment: .top) {
                Pace().offset(y: Self.height * (1 - Forecast.pace / top))
                Rectangle().fill(Color.primary.opacity(0.15)).frame(height: 1).offset(y: Self.height)
            }
            if parts.count > 1 {
                Flow {
                    ForEach(parts.indices, id: \.self) { index in
                        HStack(spacing: 5) {
                            Capsule().fill(parts[index].tint).frame(width: 10, height: 3)
                            Text(parts[index].label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.trailing, 8)
                    }
                }
            }
        }
    }
}

/// When the work was done: the tokens of each hour of the last seven days.
private struct Hours: View {
    let requests: [Served]
    let days: [Date]

    var body: some View {
        let calendar = Calendar.current
        let cells = Dictionary(grouping: requests) { calendar.dateInterval(of: .hour, for: $0.at)?.start ?? $0.at }.mapValues { $0.map(\.tokens).reduce(0, +) }
        let most = Double(cells.values.max() ?? 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Hours").font(.callout.weight(.semibold))
                Spacer()
                Text("\(requests.map(\.tokens).reduce(0, +).compact) tokens").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            // A cell's part of the grid reaches its neighbours', so that the pointer is always on one.
            VStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    HStack(spacing: 0) {
                        Text(day.formatted(.dateTime.weekday(.narrow))).font(.caption2).foregroundStyle(.tertiary).frame(width: 12, alignment: .leading)
                        ForEach(0..<24, id: \.self) { hour in
                            let start = calendar.date(byAdding: .hour, value: hour, to: day) ?? day
                            let tokens = cells[start] ?? 0
                            RoundedRectangle(cornerRadius: 2)
                                .fill(tokens > 0 ? Color.accentColor.opacity(0.25 + 0.75 * Double(tokens) / most) : Color.primary.opacity(0.06))
                                .frame(height: 9).padding(1)
                                .tip { Readout(about: start.formatted(.dateTime.weekday(.abbreviated).hour(.twoDigits(amPM: .omitted)).minute()), figure: tokens.compact, unit: "tokens") }
                        }
                    }
                }
                HStack(spacing: 0) {
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
            .sorted { $0.tokens > $1.tokens }
        let most = Double(totals.first?.tokens ?? 1), all = Double(totals.map(\.tokens).reduce(0, +))
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.callout.weight(.semibold)).padding(.bottom, 2)
            ForEach(totals.prefix(5), id: \.name) { part in
                HStack(spacing: 8) {
                    Text(part.name).font(.caption).lineLimit(1).truncationMode(.middle).frame(width: 130, alignment: .leading)
                    GeometryReader { space in
                        Capsule().fill(Color.accentColor).frame(width: max(3, space.size.width * Double(part.tokens) / most))
                    }
                    .frame(height: 5)
                    Text(part.tokens.compact).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                }
                .padding(.vertical, 2)
                .tip { Readout(about: part.about.isEmpty ? part.name : part.about, figure: (Double(part.tokens) / all).formatted(.percent.precision(.fractionLength(0))), unit: "of the tokens") }
            }
        }
    }
}
