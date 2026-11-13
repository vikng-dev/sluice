import SluiceCore
import SwiftUI

/// What opens from the menu bar: each profile's pools, one per provider, and how much of each is used.
struct Panel: View {
    let problem: String
    let accounts: [AccountStatus]
    let config: Config
    /// By profile.
    let identities: [String: [Identity]]
    /// What each provider's subscriptions are sold as, by its id.
    let titles: [String: String]
    let now: Date
    let routed: Bool
    let route: (Bool) -> Void
    let signIn: (_ provider: String, _ profile: String) -> Void
    let move: (AccountStatus, _ profile: String) -> Void
    let remove: (AccountStatus) -> Void
    let rename: (_ profile: String, _ label: String) -> Void
    let tint: (_ profile: String, Tint?) -> Void
    /// Asks which folders, and claims them.
    let claimFolders: (_ profile: String) -> Void
    let claimOwner: (_ profile: String, _ owner: String) -> Void
    let unclaim: (_ profile: String, Claim) -> Void
    let quit: () -> Void

    private var profiles: [String] { config.names }
    @State private var carried: Carried?
    /// Where each profile and each account's row is in the panel.
    @State private var frames: [String: CGRect] = [:]

    /// The profile the carried account would land in: the one under the pointer, unless it is its own.
    private var target: String? {
        guard let carried else { return nil }
        return profiles.first { $0 != carried.account.profile && frames["profile:\($0)"]?.contains(carried.pointer) == true }
    }

    private var actions: RowActions {
        RowActions(remove: remove, carry: profiles.count > 1 ? { carry($0, client: $1, $2) } : nil, drop: drop, putBack: putBack)
    }

    private func carry(_ account: AccountStatus, client: String?, _ drag: DragGesture.Value) {
        // A drag that begins away from the row is the rest of one that was broken off.
        guard frames["row:\(account.id)"]?.contains(drag.startLocation) == true else { return }
        carried = Carried(account: account, client: client, translation: drag.translation, pointer: drag.location)
    }

    /// Let go over another profile, the account moves there; anywhere else, it goes back.
    private func drop() {
        guard let carried else { return }
        guard let target else { return putBack() }
        move(carried.account, target)
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
        let providers = Set(accounts.map(\.provider)).sorted()
        return profiles.map { profile in
            (name: profile, pools: providers.compactMap { provider -> Pool? in
                let all = accounts.filter { $0.provider == provider }
                let own = all.filter { $0.profile == profile }.sorted { $0.label < $1.label }
                guard !own.isEmpty else { return nil }
                let identity = identities[profile]?.first { $0.provider == provider }
                return Pool(
                    provider: provider, title: titles[provider] ?? provider, accounts: own, client: identity?.client ?? provider, identity: identity?.account,
                    identityIsAnothers: identity?.account.map { account in all.contains { $0.label == account } && !own.contains { $0.label == account } } ?? false
                )
            })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !problem.isEmpty { Text(problem).font(.caption).foregroundStyle(.red) }
            if !routed {
                HStack {
                    Text("Claude Code and Codex are not going through Sluice.").font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Turn on") { route(true) }.controlSize(.small)
                }
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach(sections, id: \.name) { section in
                VStack(alignment: .leading, spacing: 6) {
                    ProfileCaption(
                        name: section.name, profile: config.profiles[section.name],
                        takesTheRest: section.name == Config.defaultProfile && profiles.count > 1, empty: section.pools.isEmpty, titles: titles,
                        signIn: { signIn($0, section.name) }, rename: { rename(section.name, $0) }, setTint: { tint(section.name, $0) },
                        claimFolders: { claimFolders(section.name) }, claimOwner: { claimOwner(section.name, $0) }, unclaim: { unclaim(section.name, $0) }
                    )
                    .padding(.horizontal, 10)
                    VStack(alignment: .leading, spacing: 10) {
                        if section.pools.isEmpty { Text("No accounts").font(.callout).foregroundStyle(.secondary) }
                        ForEach(section.pools) { PoolView(pool: $0, now: now, carried: carried?.account.id, actions: actions) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    // A profile's accounts sit on a card under its name. While an account is carried, the
                    // profiles it could go to are outlined, and the one under it is filled.
                    .background(target == section.name ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        if let carried, carried.account.profile != section.name {
                            RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                    }
                }
                .padding(.top, 4)
                .framed("profile:\(section.name)")
            }
            HStack {
                Text("Sluice \(Sluice.version)").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if routed {
                    Menu { Button("Stop routing") { route(false) } } label: { Image(systemName: "ellipsis") }
                        .bare()
                        .help("Clients started from now on talk to their own providers")
                }
                Button("Quit", action: quit).controlSize(.small).help("The clients go back to their own providers")
            }
            .padding(.horizontal, 6).padding(.top, 2)
        }
        .padding(10)
        .frame(width: 352)
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
private struct Frames: PreferenceKey {
    static let space = "panel"
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

private extension View {
    func framed(_ key: String) -> some View {
        background(GeometryReader { Color.clear.preference(key: Frames.self, value: [key: $0.frame(in: .named(Frames.space))]) })
    }
}

private extension Menu {
    /// A menu that is only its symbol.
    @MainActor func bare() -> some View { menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize() }
}

/// What can be done to an account's row. The copy that follows the pointer has none.
private struct RowActions {
    let remove: (AccountStatus) -> Void
    /// Nil when there is no other profile to carry it to.
    let carry: ((AccountStatus, _ client: String?, DragGesture.Value) -> Void)?
    let drop: () -> Void
    let putBack: () -> Void
}

/// Work a profile claims: what is done in a folder, or in a repository whose origin has an owner.
enum Claim: Hashable {
    case folder(String), owner(String)
}

/// A profile's name, color and claims, each changed where it is: a click on the name types a new one, a
/// click on the dot offers the colors, and a click on the count of its claims lays them out, each let go
/// by the × it shows under the pointer. The +
/// that gives the profile an account or a claim shows when the pointer is on it, and always on an empty one.
private struct ProfileCaption: View {
    let name: String
    /// Nil for a profile the config says nothing about.
    let profile: Profile?
    /// The default profile among others: it has whatever work none of them claims.
    let takesTheRest: Bool
    let empty: Bool
    let titles: [String: String]
    let signIn: (_ provider: String) -> Void
    let rename: (_ label: String) -> Void
    let setTint: (Tint?) -> Void
    let claimFolders: () -> Void
    let claimOwner: (String) -> Void
    let unclaim: (Claim) -> Void
    @State private var hovered = false
    @State private var picking = false
    /// Whether the claims are laid out, and not only counted.
    @State private var open = false
    /// What is being typed: the label, or an owner to claim. Kept apart from the text: a field that is
    /// going away writes its text once more, and that must not open it again.
    @State private var typed: Typed?
    @State private var draft = ""
    @FocusState private var typing: Bool

    private enum Typed { case label, owner }

    private var claims: [Claim] { (profile?.folders ?? []).map(Claim.folder) + (profile?.owners ?? []).map(Claim.owner) }

    /// The claims in a few words, beside the name.
    private var summary: String {
        func count(_ items: [String]?, _ one: String) -> String? {
            items.flatMap { $0.isEmpty ? nil : "\($0.count) \(one)\($0.count == 1 ? "" : "s")" }
        }
        let said = [takesTheRest ? "everything else" : nil, count(profile?.folders, "folder"), count(profile?.owners, "owner")].compactMap { $0 }
        return said.isEmpty && name != Config.defaultProfile ? "no work yet" : said.joined(separator: ", ")
    }

    private func dot(_ tint: Tint?, size: Double) -> some View {
        Circle().fill(tint?.color ?? Color.secondary.opacity(0.4)).frame(width: size, height: size)
    }

    private func type(_ what: Typed, from text: String) {
        draft = text
        typed = what
    }

    /// An unchanged label is not written, and neither is an owner with no name.
    private func keep() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        switch typed {
        case .label: if draft != profile?.label ?? "" { rename(draft) }
        case .owner: if !text.isEmpty { claimOwner(text) }
        case nil: break
        }
        typed = nil
    }

    private func field(_ placeholder: String) -> some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain).focused($typing)
            .onAppear { typing = true }
            .onSubmit(keep)
            .onExitCommand { typed = nil }
            .onChange(of: typing) { _, typing in if !typing { keep() } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Button { picking.toggle() } label: { dot(profile?.color, size: 7).frame(width: 11, height: 11).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("Change its color")
                if picking {
                    ForEach([nil] + Tint.allCases.map(Optional.some), id: \.self) { option in
                        Button {
                            setTint(option)
                            picking = false
                        } label: {
                            dot(option, size: 11).overlay { if option == profile?.color { Circle().strokeBorder(.primary.opacity(0.6), lineWidth: 1.5) } }
                        }
                        .buttonStyle(.plain).help(option?.rawValue.capitalized ?? "No color")
                    }
                } else if typed == .label {
                    field(name).font(.caption.weight(.semibold))
                } else {
                    Text(profile?.label ?? name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                        .onTapGesture { type(.label, from: profile?.label ?? "") }
                        .help("Click to change what this profile is shown as")
                    if claims.isEmpty {
                        Text(summary).font(.caption2).foregroundStyle(.tertiary)
                    } else {
                        Button { open.toggle() } label: {
                            HStack(spacing: 3) {
                                Text(summary)
                                Image(systemName: "chevron.right").imageScale(.small).rotationEffect(.degrees(open ? 90 : 0))
                            }
                            .font(.caption2).foregroundStyle(.tertiary).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help("The work that belongs to this profile")
                    }
                }
                Spacer()
                Menu {
                    ForEach(titles.sorted { $0.key < $1.key }, id: \.key) { provider, title in
                        Button { signIn(provider) } label: {
                            Label { Text("Add a \(title) account") } icon: { providerMark(provider).map(Image.init(nsImage:)) }
                        }
                    }
                    Divider()
                    Button(action: claimFolders) { Label("Add folders…", systemImage: "folder") }
                    Button { type(.owner, from: "") } label: { Label("Add a repository owner", systemImage: "at") }
                } label: {
                    Image(systemName: "plus")
                }
                .bare()
                .help("Add an account, or work that belongs to this profile")
                .opacity(hovered || empty ? 1 : 0)
            }
            if open && !claims.isEmpty || typed == .owner {
                Flow {
                    ForEach(claims, id: \.self) { claim in ClaimChip(claim: claim) { unclaim(claim) } }
                    if typed == .owner {
                        HStack(spacing: 3) {
                            Image(systemName: "at")
                            field("owner").frame(width: 110)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        // The panel closes when it stops being the key window, and is the same view when it opens again.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            keep()
            picking = false
            open = false
        }
    }
}

/// One claim. Under the pointer its mark turns into the × that lets it go.
private struct ClaimChip: View {
    let claim: Claim
    let remove: () -> Void
    @State private var hovered = false

    private var look: (mark: String, text: String, help: String) {
        switch claim {
        case .folder(let folder): ("folder", folder, "Work in \(folder) belongs to this profile")
        case .owner(let owner): ("at", owner, "Work in a repository whose origin is \(owner)'s belongs to this profile")
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Button(action: remove) { Image(systemName: hovered ? "xmark" : look.mark).frame(width: 11) }
                .buttonStyle(.plain).disabled(!hovered).help("Let it go: this work is then another profile's")
            Text(look.text).lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .frame(maxWidth: 240)
        .onHover { hovered = $0 }
        .help(look.help)
    }
}

/// Lays its views out in rows, starting a new one when the next does not fit.
private struct Flow: Layout {
    private let gap = 4.0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        place(subviews, in: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, point) in zip(subviews, place(subviews, in: bounds.width).points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func place(_ subviews: Subviews, in width: Double) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = [], x = 0.0, y = 0.0, row = 0.0, widest = 0.0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += row + gap
                row = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + gap
            row = max(row, size.height)
            widest = max(widest, x - gap)
        }
        return (points, CGSize(width: widest, height: y + row))
    }
}

extension Tint {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        }
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
    /// The account being carried, whose row stays behind dimmed.
    let carried: String?
    let actions: RowActions

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
            }
            VStack(alignment: .leading, spacing: 6) {
                PoolBar(accounts: pool.accounts).padding(.leading, AccountRow.gutter)
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
    /// Nil on the copy that follows the pointer.
    let actions: RowActions?
    @State private var hovered = false
    /// True for as long as the handle is held, however the hold ends.
    @GestureState private var held = false

    /// The room left of every row, under the provider's mark, where the handle shows.
    static let gutter: Double = 20

    /// It answered a request within the last minute.
    private var serving: Bool { account.lastAnswered.map { now.timeIntervalSince($0) < 60 } ?? false }

    /// What keeps the account from serving, or soon will: a spent window, or a pace window nearly spent.
    private var note: (text: String, color: Color)? {
        if let spent = account.windows.last(where: { $0.used >= 1 }) { return ("\(spent.name) limit reached, back \(spent.resetText)", .red) }
        if let near = account.windows.dropLast().first(where: { $0.used >= 0.85 }) { return ("\(near.name) limit at \(near.percentText), resets \(near.resetText)", .orange) }
        return account.windows.isEmpty && account.problem == nil ? ("No usage reported", .secondary) : nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Image(systemName: "line.3.horizontal").font(.caption).foregroundStyle(.secondary)
                .frame(width: Self.gutter, height: 16, alignment: .leading)
                .contentShape(Rectangle())
                .opacity(actions == nil || (hovered && actions?.carry != nil) ? 1 : 0)
                .gesture(actions?.carry.map { carry in
                    DragGesture(minimumDistance: 1, coordinateSpace: .named(Frames.space))
                        .updating($held) { _, held, _ in held = true }
                        .onChanged { carry(account, client, $0) }
                        .onEnded { _ in actions?.drop() }
                })
                // A hold that is broken off never ends, so letting go is not heard; the hold being over is.
                .onChange(of: held) { _, held in if !held { actions?.putBack() } }
                .help("Drag onto another profile to move this account there")
            details
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(account.label).font(.callout).lineLimit(1).truncationMode(.middle)
                if let client {
                    Image(systemName: "person.crop.circle.fill").font(.caption).foregroundStyle(.secondary)
                        .help("\(client) itself is signed in as this account in this profile. What \(client) does outside Sluice is this account's; its requests are paid by the whole pool.")
                }
                if serving { Circle().fill(.green).frame(width: 6, height: 6).help("Answering requests now") }
                if let actions {
                    Menu { Button("Remove…", role: .destructive) { actions.remove(account) } } label: { Image(systemName: "ellipsis") }
                        .bare()
                        .opacity(hovered ? 1 : 0)
                }
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
