import SluiceCore
import SwiftUI

/// One profile's accounts at one provider: the accounts a request from that profile's work may be paid by.
struct Pool: Identifiable {
    let profile: String
    let provider: String
    let title: String
    let accounts: [AccountStatus]
    /// The provider's client, and the account it is itself signed in as in the profile.
    let client: String
    let identity: String?
    /// The identity is an account that pays for another profile's work.
    let identityIsAnothers: Bool
    var id: String { provider }
}

extension AccountStatus {
    var id: String { provider + ":" + label }
    var budget: SluiceCore.Window? { windows.budget }
}

extension [AccountStatus] {
    /// How much of a pool of these is used: each account's budget, by its size. An account
    /// that cannot serve has nothing to give, so it counts as used up.
    var used: Double {
        let total = map(\.size).reduce(0, +)
        return total > 0 ? map { $0.size * ($0.problem == nil ? Swift.min($0.budget?.used ?? 0, 1) : 1) }.reduce(0, +) / total : 0
    }

    /// The share of a pool of these used per hour over the last day, as the readings say.
    func burn(_ samples: [Sample], now: Date) -> Double? {
        let day = now.addingTimeInterval(-86400)
        return Forecast.burn(map { account in (samples.filter { $0.provider == account.provider && $0.account == account.label && $0.at >= day }, account.size) }, from: day, to: now)
    }
}

struct PoolView: View {
    let pool: Pool
    let now: Date
    /// The account being carried, whose row stays behind dimmed.
    let carried: String?
    let actions: RowActions
    @Environment(Running.self) private var running
    @State private var hovered = false

    private var starred: Bool { running.config.profiles[pool.profile]?.starred.contains(pool.provider) == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                PoolTitle(provider: pool.provider, title: pool.title)
                Button { running.star(pool.profile, pool.provider, !starred) } label: { Image(systemName: starred ? "star.fill" : "star").font(.caption).contentTransition(.symbolEffect(.replace)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(starred ? "Shown in the menu bar. Click to take it out" : "Show how much of this pool is used in the menu bar")
                    .opacity(hovered ? 1 : 0)
                    .moves(.easeOut(duration: 0.12), with: hovered).moves(.snappy(duration: 0.2), with: starred)
                Spacer()
                Share(used: pool.accounts.used, worded: true)
            }
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            VStack(alignment: .leading, spacing: 9) {
                ForEach(pool.accounts, id: \.id) { account in
                    AccountRow(account: account, client: pool.identity == account.label ? pool.client : nil, now: now, actions: actions)
                        .opacity(carried == account.id ? 0.3 : 1)
                        .framed("row:\(account.id)")
                }
                if let identity = pool.identity, !pool.accounts.contains(where: { $0.label == identity }) {
                    Label("\(pool.client) is signed in as \(identity)", systemImage: "person.crop.circle")
                        .font(.caption).foregroundStyle(pool.identityIsAnothers ? Color.orange : .secondary).lineLimit(1).truncationMode(.middle)
                        .help(pool.identityIsAnothers
                            ? "What \(pool.client) does outside Sluice here is this account's, and this account pays for another profile's work."
                            : "What \(pool.client) does outside Sluice here is this account's. It is not one of the accounts above.")
                        .padding(.leading, AccountRow.gutter)
                }
            }
        }
    }
}

/// How an account's row is carried by its handle. The copy that follows the pointer has none, and nothing can be done to it.
struct RowActions {
    let carry: (AccountStatus, _ client: String?, DragGesture.Value) -> Void
    let drop: () -> Void
    let putBack: () -> Void
}

/// One account of a pool: who it is on a line, and under it the limit that stops it next, or every limit
/// it has once opened.
struct AccountRow: View {
    let account: AccountStatus
    /// The client that is itself signed in as this account in the profile, if one is.
    let client: String?
    let now: Date
    /// Nil on the copy that follows the pointer.
    let actions: RowActions?
    @Environment(Running.self) private var running
    @State private var hovered = false
    /// True for as long as the handle is held, however the hold ends.
    @GestureState private var held = false

    /// The room left of every row, under the provider's mark, where the handle shows.
    static let gutter: Double = 20
    /// The room for a share and for a clock, so that they line up down the rows.
    static let share: Double = 34
    static let clock: Double = 52

    /// How many answers are coming through it now; nil when none is and none was within the last minute.
    private var level: Int? {
        let streaming = running.streaming[account.id] ?? 0
        return streaming > 0 || account.lastAnswered.map { now.timeIntervalSince($0) < 60 } == true ? streaming : nil
    }

    /// Open, the row lists every limit the account has and the resets it holds.
    @State private var opened = false

    /// The resets it holds. Those that differ only in name are one, which uses the first of them.
    private var holds: [(reset: Reset, count: Int)] {
        account.resets.reduce(into: []) { lines, reset in
            if let same = lines.firstIndex(where: { ($0.reset.refills, $0.reset.expiresAt, $0.reset.usable) == (reset.refills, reset.expiresAt, reset.usable) }) {
                lines[same].count += reset.left
            } else {
                lines.append((reset, reset.left))
            }
        }
    }

    /// The budget, then the shorter windows, then the limits on a part of its use.
    private var limits: [SluiceCore.Window] { account.windows.sorted { $0.resetsAt > $1.resetsAt } + account.scoped }

    /// The limits under the name: the one that stops it next, and opened, the others after it.
    private var shown: [SluiceCore.Window] {
        guard let tightest else { return [] }
        return [tightest] + (opened ? limits.filter { $0.name != tightest.name } : [])
    }

    /// What stops the account next: its budget, unless another of its limits is fuller and near its end.
    private var tightest: SluiceCore.Window? {
        guard let budget = account.budget else { return nil }
        return limits.filter { $0.name != budget.name && $0.used > budget.used && $0.used >= 0.7 }.max { $0.used < $1.used } ?? budget
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Image(systemName: "line.3.horizontal").font(.caption).foregroundStyle(.secondary)
                .frame(width: Self.gutter, height: 16, alignment: .leading)
                .contentShape(Rectangle())
                .opacity(actions == nil || hovered ? 1 : 0)
                // Where the handle is not showing, an account that is answering says so.
                .overlay(alignment: .leading) {
                    if let level, actions != nil { Playing(level: level).id(level).opacity(hovered ? 0 : 1) }
                }
                .moves(.easeOut(duration: 0.12), with: hovered)
                .gesture(actions.map { actions in
                    DragGesture(minimumDistance: 1, coordinateSpace: .named(Frames.space))
                        .updating($held) { _, held, _ in held = true }
                        .onChanged { actions.carry(account, client, $0) }
                        .onEnded { _ in actions.drop() }
                })
                // A hold that is broken off never ends, so letting go is not heard; the hold being over is.
                .onChange(of: held) { _, held in if !held { actions?.putBack() } }
                .help("Drag onto another profile to move this account there, or onto New profile to make one for it")
            details
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        // A row that opens says so under the pointer. Drawn behind it and past its edges, it takes no room.
        .background {
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)).padding(.horizontal, -6).padding(.vertical, -4)
                .opacity(hovered && opens && actions != nil ? 1 : 0)
                .moves(.easeOut(duration: 0.12), with: hovered)
        }
    }

    /// A click on who it is or on its bar opens the row, and closes it again.
    private var opens: Bool { limits.count > 1 || !holds.isEmpty }

    @Environment(\.armed) private var armed
    private var removing: Bool { armed.wrappedValue == "remove:\(account.id)" }

    private func open() {
        if opens { opened.toggle() }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(account.label).font(.callout).lineLimit(1).truncationMode(.middle)
                    .strikethrough(removing).foregroundStyle(removing ? .secondary : .primary)
                if let client {
                    Image(systemName: "person.crop.circle.fill").font(.caption).foregroundStyle(.secondary)
                        .help("\(client) itself is signed in as this account in this profile. What \(client) does outside Sluice is this account's; its requests are paid by the whole pool.")
                }
                if actions != nil {
                    if removing {
                        Confirm { running.remove(account) }
                            .help("Sluice forgets this sign-in and stops using the account. Signing it in again needs the browser")
                    } else {
                        Button { armed.wrappedValue = "remove:\(account.id)" } label: { Image(systemName: "trash").font(.caption) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove this account")
                            .opacity(hovered ? 1 : 0)
                            .moves(.easeOut(duration: 0.12), with: hovered)
                    }
                }
                Spacer(minLength: 4)
                if let plan = account.plan {
                    // A symbol inside the text takes the text's size and sits on its baseline.
                    ((plan.business ? Text("\(Image(systemName: "briefcase.fill")) ") : Text("")) + Text(plan.tier))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        .help(plan.name + (plan.price.map { ", $\($0) a month" } ?? ""))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .moves(.snappy(duration: 0.18), with: removing)
            if let problem = account.problem {
                Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if shown.isEmpty {
                Text("unused").font(.caption).foregroundStyle(.tertiary).help("Nothing was used in its current windows, or its provider has not said")
            } else {
                ForEach(shown, id: \.name) { limit in
                    HStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Text(limit.title).font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                            Bar(used: limit.used)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(perform: open)
                        .help(!opens ? "" : opened ? "Click for the one that stops it next" : "Click for every limit it has")
                        Share(used: limit.used).frame(width: Self.share, alignment: .trailing)
                        Clock(at: limit.resetsAt, now: now).frame(width: Self.clock, alignment: .trailing)
                    }
                    .fadesIn(limit.name != tightest?.name)
                }
            }
            if opened, !holds.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Resets").font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                    Flow {
                        ForEach(holds, id: \.reset.id) { reset, count in
                            let using = "reset:\(account.id):\(reset.id)"
                            HStack(spacing: 4) {
                                Button { armed.wrappedValue = using } label: {
                                    HStack(spacing: 4) {
                                        Text(reset.kind(for: account) + (count > 1 ? " ×\(count)" : "")).fontWeight(.semibold)
                                        if let expires = reset.expiresAt { Text(expires.leftText(now: now, units: 1)).opacity(0.7) }
                                    }
                                    .font(.caption2.monospacedDigit()).lineLimit(1).fixedSize()
                                    .foregroundStyle(reset.usable ? Color.green : Color.secondary)
                                    .padding(.horizontal, 7).padding(.vertical, 2).background(reset.usable ? Color.green.opacity(0.16) : Color.primary.opacity(0.06), in: Capsule())
                                    .overlay { if armed.wrappedValue == using { Capsule().strokeBorder(Color.red.opacity(0.8), lineWidth: 1) } }
                                }
                                .buttonStyle(.plain).disabled(!reset.usable || actions == nil)
                                .help(reset.usable ? "Use it: what it refills is whole again at once. It lapses in the time shown" : "Its provider would not take it now")
                                if armed.wrappedValue == using {
                                    Confirm(ready: reset.usable) { running.useReset(reset, of: account) }
                                }
                            }
                        }
                    }
                    .moves(.snappy(duration: 0.18), with: armed.wrappedValue)
                }
                .fadesIn()
                .padding(.top, 2)
            }
        }
    }
}

extension SluiceCore.Window {
    /// What a limit is called where an account's limits are listed: a window by its length, and a limit
    /// on a part of the account's use by the name its provider gave.
    var title: String { Self.title(named: name) }

    /// Short, a window other than the week goes by its provider's name for it: "5h".
    static func title(named name: String, short: Bool = false) -> String {
        guard let length = length(named: name) else { return name.capitalized }
        let minutes = Int(length / 60)
        return minutes == 7 * 1440 ? "Week" : short ? name : minutes % 1440 == 0 ? "\(minutes / 1440)-day" : minutes % 60 == 0 ? "\(minutes / 60)-hour" : "\(minutes)-minute"
    }
}

extension Reset {
    /// What it is called for the account that holds it: full when it refills every limit the account
    /// has, and otherwise by the limits it does refill.
    func kind(for account: AccountStatus) -> String {
        let has = Set((account.windows + account.scoped).map(\.name))
        if !has.isEmpty, has.isSubset(of: refills) { return "Full" }
        return refills.map { SluiceCore.Window.title(named: $0, short: true) }.joined(separator: " + ")
    }
}

/// A level meter of three bars: they rise and fall while answers come through the account, higher and
/// faster the more of them there are, and stand low and still when it has only just answered. Made anew
/// for each level, so that it moves as that level does from the start.
private struct Playing: View {
    let level: Int
    @State private var up = false
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        // One answer fills a little over half of it, and four fill it.
        let top = min(0.4 + 0.15 * Double(level), 1)
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array([0.5, 0.34, 0.44].enumerated()), id: \.offset) { bar, beat in
                Capsule().fill(.green).frame(width: 2, height: 10)
                    .scaleEffect(y: level == 0 ? 0.3 : still ? [0.5, 0.9, 0.6][bar] * top : up ? top : 0.3, anchor: .bottom)
                    .moves(.easeInOut(duration: beat / (0.7 + 0.15 * Double(min(level, 4)))).repeatForever(autoreverses: true), with: up)
            }
        }
        .onAppear { up = level > 0 }
    }
}

private struct Bar: View {
    let used: Double

    var body: some View {
        GeometryReader { space in
            Capsule().fill(.quaternary)
            if used > 0 {
                Capsule().fill(Share.warning(used) ?? .accentColor)
                    .frame(width: max(space.size.height, space.size.width * min(used, 1)))
            }
        }
        .frame(height: 4)
        .moves(.smooth(duration: 0.45), with: used)
    }
}
