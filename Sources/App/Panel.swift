import SluiceCore
import SwiftUI

/// What opens from the menu bar: each profile's pools, one per provider, and how much of each is used.
struct Panel: View {
    let problem: String
    let accounts: [AccountStatus]
    /// Every profile's name, the default first.
    let profiles: [String]
    /// By profile: the account each client is itself signed in as there, nil where it is signed out.
    let signIns: [String: [(provider: String, client: String, account: String?)]]
    /// What each provider's subscriptions are sold as, by its id.
    let titles: [String: String]
    let now: Date
    /// Whether the clients are set up to talk to Sluice, and how to change that.
    let routed: Bool
    let route: (Bool) -> Void
    /// Signs another account in at a provider, for a profile.
    let signIn: (_ provider: String, _ profile: String) -> Void
    let move: (AccountStatus, _ profile: String) -> Void
    let remove: (AccountStatus) -> Void
    let quit: () -> Void

    /// A profile has a pool where it has accounts, and a profile with no pool is not shown.
    private var sections: [(name: String, pools: [Pool])] {
        let providers = Set(accounts.map(\.provider)).sorted()
        return profiles.map { profile in
            (name: profile, pools: providers.compactMap { provider -> Pool? in
                let all = accounts.filter { $0.provider == provider }
                let own = all.filter { $0.profile == profile }.sorted { $0.label < $1.label }
                guard !own.isEmpty else { return nil }
                let signIn = signIns[profile]?.first { $0.provider == provider }
                return Pool(
                    provider: provider, title: titles[provider] ?? provider, accounts: own, client: signIn?.client ?? provider, identity: signIn?.account,
                    identityIsAnothers: signIn?.account.map { identity in all.contains { $0.label == identity } && !own.contains { $0.label == identity } } ?? false
                )
            })
        }
        .filter { !$0.pools.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !problem.isEmpty { Text(problem).font(.caption).foregroundStyle(.red) }
            if !routed {
                HStack {
                    Text("Claude Code and Codex are not going through Sluice.").font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Turn on") { route(true) }.controlSize(.small)
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            if accounts.isEmpty, problem.isEmpty { Text("No accounts yet. Sign one in from the menu below.").font(.callout).foregroundStyle(.secondary) }
            ForEach(sections, id: \.name) { section in
                VStack(alignment: .leading, spacing: 10) {
                    // One profile needs no name.
                    if sections.count > 1 {
                        Text(section.name.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).kerning(0.6)
                    }
                    ForEach(section.pools) { pool in
                        PoolView(
                            pool: pool, now: now, others: profiles.filter { $0 != section.name },
                            signIn: { signIn(pool.provider, section.name) }, move: move, remove: remove
                        )
                    }
                }
            }
            Divider()
            HStack {
                Text("Sluice \(Sluice.version)").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Menu {
                    // Every provider and profile, so a first account anywhere starts here.
                    ForEach(titles.sorted { $0.key < $1.key }, id: \.key) { provider, title in
                        if profiles.count > 1 {
                            Menu("Sign in to \(title)") { ForEach(profiles, id: \.self) { name in Button(name) { signIn(provider, name) } } }
                        } else {
                            Button("Sign in to \(title)") { signIn(provider, Config.defaultProfile) }
                        }
                    }
                    if routed {
                        Divider()
                        Button("Stop routing") { route(false) }.help("Clients started from now on talk to their own providers")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Button("Quit", action: quit).controlSize(.small).help("The clients go back to their own providers")
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

/// One profile's accounts at one provider: the accounts a request from that profile's work may be paid by.
private struct Pool: Identifiable {
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

private extension AccountStatus {
    var id: String { provider + ":" + label }
    /// The window that resets last, read as how much of the account is left; an earlier one as its pace.
    var budget: SluiceCore.Window? { windows.last }
    var weight: Double { Double(plan?.multiple ?? 1) }
}

private struct PoolView: View {
    let pool: Pool
    let now: Date
    /// The profiles an account here could move to.
    let others: [String]
    let signIn: () -> Void
    let move: (AccountStatus, String) -> Void
    let remove: (AccountStatus) -> Void

    /// When the pool next gets allowance back.
    private var nextReset: SluiceCore.Window? {
        pool.accounts.compactMap(\.budget).filter { $0.used > 0 }.min { $0.resetsAt < $1.resetsAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let mark = providerMark(pool.provider) {
                    Image(nsImage: mark).resizable().frame(width: 13, height: 13).foregroundStyle(.secondary)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                }
                Text(pool.title).font(.callout.weight(.semibold))
                Spacer()
                if let nextReset {
                    Text("next reset \(nextReset.resetText)").font(.caption).foregroundStyle(.secondary)
                }
                Button(action: signIn) { Image(systemName: "plus") }
                    .buttonStyle(.borderless).font(.caption).help("Sign in another \(pool.title) account for this profile")
            }
            VStack(alignment: .leading, spacing: 6) {
                PoolBar(accounts: pool.accounts)
                ForEach(pool.accounts, id: \.id) { account in
                    AccountRow(account: account, client: pool.identity == account.label ? pool.client : nil, now: now)
                        .contentShape(Rectangle())
                        .contextMenu {
                            if !others.isEmpty {
                                Menu("Move to") { ForEach(others, id: \.self) { name in Button(name) { move(account, name) } } }
                            }
                            Button("Remove…", role: .destructive) { remove(account) }
                        }
                }
                if let identity = pool.identity, !pool.accounts.contains(where: { $0.label == identity }) {
                    Label("\(pool.client) is signed in as \(identity)", systemImage: "person.crop.circle")
                        .font(.caption).foregroundStyle(pool.identityIsAnothers ? Color.orange : .secondary).lineLimit(1).truncationMode(.middle)
                        .help(pool.identityIsAnothers
                            ? "What \(pool.client) does outside Sluice here is this account's, and this account pays for another profile's work."
                            : "What \(pool.client) does outside Sluice here is this account's. It is not one of the accounts above.")
                }
            }
            .padding(.leading, 20)
        }
    }
}

/// The pool as one bar: a part for each account, as wide as its plan is large and as full as its budget is used.
private struct PoolBar: View {
    let accounts: [AccountStatus]

    var body: some View {
        GeometryReader { space in
            let room: Double = space.size.width - Double(accounts.count - 1) * 2
            let total: Double = accounts.map(\.weight).reduce(0, +)
            HStack(spacing: 2) {
                ForEach(accounts, id: \.id) { account in
                    let width: Double = max(4, room * account.weight / total)
                    Bar(used: account.budget?.used ?? 0)
                        .frame(width: width)
                        .opacity(account.problem == nil ? 1 : 0.45)
                        .help(account.label)
                }
            }
        }
        .frame(height: 5)
    }
}

private struct AccountRow: View {
    let account: AccountStatus
    /// The client that is itself signed in as this account in the profile, if one is.
    let client: String?
    let now: Date

    /// It answered a request within the last minute.
    private var serving: Bool { account.lastAnswered.map { now.timeIntervalSince($0) < 60 } ?? false }

    /// What keeps the account from serving, or soon will: a spent window, or a pace window nearly spent.
    private var note: (text: String, color: Color)? {
        if let spent = account.windows.last(where: { $0.used >= 1 }) { return ("\(spent.name) limit reached, back \(spent.resetText)", .red) }
        if let near = account.windows.dropLast().first(where: { $0.used >= 0.85 }) { return ("\(near.name) limit at \(near.percentText), resets \(near.resetText)", .orange) }
        return account.windows.isEmpty && account.problem == nil ? ("No usage reported", .secondary) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(account.label).font(.callout).lineLimit(1).truncationMode(.middle)
                if let client {
                    Image(systemName: "person.crop.circle.fill").font(.caption).foregroundStyle(.secondary)
                        .help("\(client) itself is signed in as this account in this profile. What \(client) does outside Sluice is this account's; its requests are paid by the whole pool.")
                }
                if serving { Circle().fill(.green).frame(width: 6, height: 6).help("Answering requests now") }
                Spacer(minLength: 4)
                if let plan = account.plan { Badge(text: plan.tier, symbol: plan.business ? "briefcase.fill" : nil).help(plan.name + (plan.price.map { ", $\($0) a month" } ?? "")) }
                if let budget = account.budget {
                    Text(budget.percentText).font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
                        .foregroundStyle(budget.used >= 1 ? Color.red : budget.used >= 0.85 ? .orange : .primary)
                }
            }
            .help(account.windows.map { "\($0.name) \($0.percentText), resets \($0.resetText)" }.joined(separator: "\n"))
            if let problem = account.problem {
                Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if let note {
                Text(note.text).font(.caption).foregroundStyle(note.color)
            }
        }
    }
}

private struct Bar: View {
    let used: Double

    var body: some View {
        GeometryReader { space in
            Capsule().fill(.quaternary)
            if used > 0 {
                Capsule().fill(used >= 1 ? Color.red : used >= 0.85 ? .orange : .accentColor)
                    .frame(width: max(space.size.height, space.size.width * min(used, 1)))
            }
        }
        .frame(height: 5)
    }
}

private struct Badge: View {
    let text: String
    let symbol: String?

    var body: some View {
        // A symbol inside the text takes the text's size and sits on its baseline.
        ((symbol.map { Text("\(Image(systemName: $0)) ").foregroundStyle(.secondary) } ?? Text("")) + Text(text))
            .lineLimit(1).fixedSize()
            .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
    }
}
