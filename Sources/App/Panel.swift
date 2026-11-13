import SluiceCore
import SwiftUI

/// What opens from the menu bar: every profile's accounts and how much of each allowance is used.
struct Panel: View {
    let state: String
    let problem: String
    let accounts: [AccountStatus]
    let now: Date
    /// Whether the clients are set up to talk to Sluice, and how to change that.
    let routed: Bool
    let route: (Bool) -> Void
    let quit: () -> Void

    private var profiles: [(name: String, accounts: [AccountStatus])] {
        Dictionary(grouping: accounts, by: \.profile)
            .map { (name: $0.key, accounts: $0.value.sorted { ($0.provider, $1.main ? 1 : 0, $0.label) < ($1.provider, $0.main ? 1 : 0, $1.label) }) }
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
                    Text(profile.name.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).kerning(0.6)
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
                    // The main account is the first of its provider and the one in heavier type.
                    Text(account.label).font(.callout.weight(account.main ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                        .help(account.main ? "Main account of this profile" : "")
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
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).imageScale(.small).foregroundStyle(.secondary) }
            Text(text).lineLimit(1).fixedSize()
        }
        .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
    }
}
