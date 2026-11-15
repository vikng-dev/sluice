import SluiceCore
import SwiftUI

/// What opens from the menu bar: each profile's pools, one per provider, and how much of each is used.
struct Panel: View {
    let now: Date
    @Environment(Running.self) private var running

    private var profiles: [String] { running.config.names }
    /// Which of the panel's two views is shown: the accounts, or their use over time.
    @AppStorage("showsUse") private var showsUse = false
    @Namespace private var views
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var carried: Carried?
    @State private var armed: String?
    /// The account let go on the place for a new profile, which is now being named for it.
    @State private var founder: AccountStatus?
    /// Where each profile, each account's row and the place for a new profile is in the panel.
    @State private var frames: [String: CGRect] = [:]

    /// The profile the carried account would land in: the one under the pointer, unless it is its own.
    private var target: String? {
        guard let carried else { return nil }
        return profiles.first { $0 != carried.account.profile && frames["profile:\($0)"]?.contains(carried.pointer) == true }
    }

    /// Whether the carried account is over the place for a new profile.
    private var overNew: Bool {
        carried.map { frames["new"]?.contains($0.pointer) == true } ?? false
    }

    private var actions: RowActions {
        RowActions(carry: { carry($0, client: $1, $2) }, drop: drop, putBack: putBack)
    }

    private func carry(_ account: AccountStatus, client: String?, _ drag: DragGesture.Value) {
        // A drag that begins away from the row is the rest of one that was broken off.
        guard frames["row:\(account.id)"]?.contains(drag.startLocation) == true else { return }
        carried = Carried(account: account, client: client, translation: drag.translation, pointer: drag.location)
    }

    /// Let go over another profile, the account moves there; over the place for a new one, a profile is
    /// named for it; anywhere else, it goes back.
    private func drop() {
        guard let carried else { return }
        if overNew {
            founder = carried.account
            return putBack()
        }
        guard let target else { return putBack() }
        running.move(carried.account, to: target)
        self.carried = nil
    }

    /// The account settles where it was. This is also how a carry ends that was broken off and not let go,
    /// as by a click of the other button.
    private func putBack() {
        guard carried != nil else { return }
        withAnimation(.spring(duration: 0.25)) { carried?.translation = .zero } completion: { carried = nil }
    }

    /// Every profile, with a pool at each provider it has accounts at.
    private var sections: [(name: String, pools: [Pool])] {
        let providers = Set(running.accounts.map(\.provider)).sorted()
        return profiles.map { profile in
            (name: profile, pools: providers.compactMap { provider -> Pool? in
                let all = running.accounts.filter { $0.provider == provider }
                let own = all.filter { $0.profile == profile }.sorted { $0.label < $1.label }
                guard !own.isEmpty else { return nil }
                let identity = running.identities[profile]?.first { $0.provider == provider }
                return Pool(
                    profile: profile, provider: provider, title: running.titles[provider] ?? provider, accounts: own, client: identity?.client ?? provider, identity: identity?.account,
                    identityIsAnothers: identity?.account.map { account in all.contains { $0.label == account } && !own.contains { $0.label == account } } ?? false
                )
            })
        }
    }

    var body: some View {
        let autoResets = running.config.autoResets
        VStack(alignment: .leading, spacing: 8) {
            // The panel's first line, which stays where it is whatever is under it: the two views, then what the app
            // does by itself and its own menu.
            HStack(alignment: .top, spacing: 8) {
                HStack(spacing: 2) {
                    ForEach([(false, "rectangle.stack", "Accounts"), (true, "chart.xyaxis.line", "Use over time")], id: \.0) { use, symbol, name in
                        Button { showsUse = use } label: {
                            Image(systemName: symbol).font(.caption).frame(width: 24, height: 16)
                                .background {
                                    // One highlight, which slides to the view chosen.
                                    if showsUse == use { RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.12)).matchedGeometryEffect(id: "chosen", in: views) }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).foregroundStyle(showsUse == use ? .primary : .secondary).help(name)
                    }
                }
                .moves(.snappy(duration: 0.2), with: showsUse)
                if showsUse { Text("Last 7 days").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).frame(height: 16) }
                Spacer()
                Button { running.autoReset(!autoResets) } label: {
                    Image(systemName: autoResets ? "bolt.fill" : "bolt").font(.caption).contentTransition(.symbolEffect(.replace))
                        .frame(width: 24, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(autoResets ? Color.green : .secondary)
                .moves(.snappy(duration: 0.2), with: autoResets)
                .help(autoResets ? "Resets are used for you: when a pool is out, or one is about to lapse. Click to use them only yourself" : "Use resets for me: when a pool is out, or one is about to lapse")
                Menu {
                    Text("Sluice \(Sluice.version)")
                    Divider()
                    if running.routed { Button("Stop routing") { running.route(false) } }
                    Button("Quit Sluice", action: running.quit)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .bare().frame(height: 16)
                .help("Stop routing sends clients started from now on to their own providers; quitting sends them all")
            }
            .padding(.horizontal, 10)
            if !running.said.isEmpty { Text(running.said).font(.caption).foregroundStyle(.red) }
            if !running.routed {
                HStack {
                    Text("Claude Code and Codex are not going through Sluice.").font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Turn on") { running.route(true) }.controlSize(.small)
                }
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            if showsUse { UsageView(now: now) }
            ForEach(showsUse ? [] : sections, id: \.name) { section in
                VStack(alignment: .leading, spacing: 6) {
                    ProfileCaption(name: section.name, empty: section.pools.isEmpty).padding(.horizontal, 10)
                    VStack(alignment: .leading, spacing: 10) {
                        if section.pools.isEmpty { Text("No accounts").font(.callout).foregroundStyle(.secondary) }
                        ForEach(section.pools) { pool in
                            PoolView(pool: pool, now: now, carried: carried?.account.id, actions: actions)
                        }
                    }
                    // A profile's accounts sit on a card under its name. While an account is carried, the
                    // profiles it could go to are outlined, and the one under it is filled.
                    .card(target == section.name ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                    .moves(.easeOut(duration: 0.12), with: target == section.name)
                    .outlined(carried.map { $0.account.profile != section.name } ?? false)
                }
                .padding(.top, 4)
                .framed("profile:\(section.name)")
            }
            if !showsUse {
                NewProfile(founder: $founder, carrying: carried != nil, targeted: overNew)
                    .framed("new")
                    .padding(.horizontal, 10).padding(.top, 4)
            }
        }
        .padding(10)
        .frame(width: 392)
        .contentShape(Rectangle())
        .onTapGesture { armed = nil }
        .environment(\.armed, $armed)
        .symbolEffectsRemoved(still)
        .sensoryFeedback(.alignment, trigger: target)
        // The panel was opened: what it shows is asked for again where it has grown old.
        .task(id: showsUse) { if showsUse { running.loadHistory() } }
        .task { running.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            running.refresh()
            if showsUse { running.loadHistory() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in armed = nil }
        .onPreferenceChange(Frames.self) { frames = $0 }
        .coordinateSpace(name: Frames.space)
        // The carried account's row, lifted off the panel and following the pointer.
        .overlay(alignment: .topLeading) {
            if let carried, let frame = frames["row:\(carried.account.id)"] {
                AccountRow(account: carried.account, client: carried.client, now: now, actions: nil)
                    .padding(.vertical, 5).padding(.trailing, 8)
                    .frame(width: frame.width + 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                    .position(x: frame.midX + 4 + carried.translation.width, y: frame.midY + carried.translation.height)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// An account lifted by its handle, on its way to another profile.
private struct Carried {
    let account: AccountStatus
    /// The client marked on its row, kept on the lifted copy.
    let client: String?
    var translation: CGSize
    /// In the panel's space.
    var pointer: CGPoint
}

/// Where views are in the panel, by a key each gives itself.
struct Frames: PreferenceKey {
    static let space = "panel"
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

extension View {
    func framed(_ key: String) -> some View {
        background(GeometryReader { Color.clear.preference(key: Frames.self, value: [key: $0.frame(in: .named(Frames.space))]) })
    }
}
