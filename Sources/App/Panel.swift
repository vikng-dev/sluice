import SluiceCore
import SwiftUI

/// What opens from the menu bar: every profile's accounts and how much of each allowance is used.
struct Panel: View {
    let state: String
    let problem: String
    let accounts: [AccountStatus]
    /// By profile: the account each client is itself signed in as there, nil where it is signed out.
    let signIns: [String: [(client: String, account: String?)]]
    let now: Date
    /// Whether the clients are set up to talk to Sluice, and how to change that.
    let routed: Bool
    let route: (Bool) -> Void
    let quit: () -> Void

    private var profiles: [(name: String, accounts: [AccountStatus])] {
        Dictionary(grouping: accounts, by: \.profile)
            .map { (name: $0.key, accounts: $0.value.sorted { ($0.provider, $0.label) < ($1.provider, $1.label) }) }
            .sorted { ($0.name == Config.defaultProfile ? "" : $0.name) < ($1.name == Config.defaultProfile ? "" : $1.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sluice").font(.headline)
                Spacer()
                Text(state).font(.caption).foregroundStyle(.secondary)
            }
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
            if accounts.isEmpty { Text("No accounts yet. Run: sluice login").font(.callout).foregroundStyle(.secondary) }
            ForEach(profiles, id: \.name) { profile in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(profile.name.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).kerning(0.6)
                        Spacer()
                        ForEach(signIns[profile.name] ?? [], id: \.client) {
                            SignIn(client: $0.client, account: $0.account, pooled: profile.accounts.map(\.label))
                        }
                    }
                    ForEach(profile.accounts, id: \.id) { AccountRow(account: $0, now: now) }
                }
            }
            Divider()
            HStack {
                Text("Sluice \(Sluice.version)").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if routed {
                    Menu {
                        Button("Stop routing") { route(false) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Clients started from now on talk to their own providers")
                }
                Button("Quit", action: quit).controlSize(.small).help("The clients go back to their own providers")
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

private extension AccountStatus {
    var id: String { provider + ":" + label }
}

/// Whom a client is itself signed in as in a profile, which is not a setting of Sluice's but the client's own.
private struct SignIn: View {
    let client: String
    let account: String?
    /// The accounts whose usage the profile shares.
    let pooled: [String]

    private static let owns = "What it does outside Sluice (connectors, the browser, published pages) is this account's. The accounts below only share their usage."

    var body: some View {
        if let account {
            let shared = pooled.contains(account)
            Text("signed in as \(account)").font(.caption2).foregroundStyle(shared ? .secondary : Color.orange).lineLimit(1).truncationMode(.middle)
                .help("\(client) is signed in as \(account) in this profile. \(Self.owns)" + (shared ? "" : " Its own usage is not shared here: it is not one of this profile's accounts."))
        } else {
            Text("\(client) is not signed in").font(.caption2).foregroundStyle(.orange)
                .help("Run \(client) in this profile and use /login. Connectors, the browser and published pages need its own sign-in.")
        }
    }
}

private struct AccountRow: View {
    let account: AccountStatus
    let now: Date

    /// It answered a request within the last minute.
    private var serving: Bool { account.lastAnswered.map { now.timeIntervalSince($0) < 60 } ?? false }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if let mark = providerMark(account.provider) {
                Image(nsImage: mark).resizable().frame(width: 13, height: 13).foregroundStyle(.secondary)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                    .help(account.provider).accessibilityLabel(account.provider)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(account.label).font(.callout).lineLimit(1).truncationMode(.middle)
                    if serving { Circle().fill(.green).frame(width: 6, height: 6).help("Answering requests now") }
                    Spacer()
                    if providerMark(account.provider) == nil { Text(account.provider).font(.caption).foregroundStyle(.secondary) }
                    if let plan = account.plan { Badge(text: plan.tier, symbol: plan.business ? "briefcase.fill" : nil).help(plan.name) }
                }
                if let problem = account.problem {
                    Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                } else if account.windows.isEmpty {
                    Text("No usage reported").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(account.windows, id: \.name) { window in
                    HStack(spacing: 8) {
                        Text(window.name).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 20, alignment: .leading)
                        Bar(used: window.used)
                        Text(window.percentText).font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
                        Text(window.resetText).font(.caption).foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
                    }
                }
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
