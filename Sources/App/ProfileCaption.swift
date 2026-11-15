import SluiceCore
import SwiftUI

/// Work a profile claims: what is done in a folder, or in a repository whose origin has an owner.
enum Claim: Hashable {
    case folder(String), owner(String)
}

/// A profile's name, color and claims, each changed where it is: a click on the name types a new one, a
/// click on the dot offers the colors, and a click on the count of its claims lays them out, each let go
/// by the × it shows under the pointer. The + that gives the profile an account or a claim shows when the
/// pointer is on it, and always on an empty one.
struct ProfileCaption: View {
    let name: String
    let empty: Bool
    @Environment(Running.self) private var running
    /// Nil for a profile the config says nothing about.
    private var profile: Profile? { running.config.profiles[name] }
    /// The default profile among others: it has whatever work none of them claims.
    private var takesTheRest: Bool { name == Config.defaultProfile && running.config.names.count > 1 }
    @State private var hovered = false
    @State private var picking = false
    /// Whether the claims are laid out, and not only counted.
    @State private var open = false
    /// Whether a repository owner is being typed for it.
    @State private var owning = false
    /// Whether the name is being typed. Kept apart from the text: a field that is going away writes its
    /// text once more, and that must not open it again.
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var typing: Bool

    private var claims: [Claim] { (profile?.folders ?? []).map(Claim.folder) + (profile?.owners ?? []).map(Claim.owner) }

    @Environment(\.armed) private var armed
    /// What its removal goes by while it waits to be confirmed.
    private var removal: String { "profile:\(name)" }

    /// The claims at a glance, beside the name: how many folders and how many owners.
    @ViewBuilder private var summary: some View {
        let folders = profile?.folders.count ?? 0, owners = profile?.owners.count ?? 0
        if takesTheRest { Text("everything else") }
        if folders > 0 { Label { Text("\(folders)") } icon: { Image(systemName: "folder") } }
        if owners > 0 { Label { Text("\(owners)") } icon: { OwnerMark() } }
        if claims.isEmpty, name != Config.defaultProfile { Text("no work yet") }
    }

    /// An unchanged label is not written, so leaving the field writes nothing.
    private func keep() {
        guard editing else { return }
        editing = false
        if draft != profile?.label ?? "" { running.rename(name, to: draft) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Button { picking.toggle() } label: { Dot(tint: profile?.color).frame(width: 11, height: 11).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("Change its color")
                if picking {
                    ForEach([nil] + Tint.allCases.map(Optional.some), id: \.self) { option in
                        Button {
                            running.tint(name, option)
                            picking = false
                        } label: {
                            Dot(tint: option, size: 11).overlay { if option == profile?.color { Circle().strokeBorder(.primary.opacity(0.6), lineWidth: 1.5) } }
                        }
                        .buttonStyle(.plain).help(option?.rawValue.capitalized ?? "No color")
                    }
                } else if editing {
                    TextField(name, text: $draft)
                        .textFieldStyle(.plain).font(.caption.weight(.semibold)).focused($typing)
                        .onAppear { typing = true }
                        .onSubmit(keep)
                        .onExitCommand { editing = false }
                        .onChange(of: typing) { _, typing in if !typing { keep() } }
                } else {
                    Text(profile?.label ?? name).font(.caption.weight(.semibold)).foregroundStyle(.secondary).strikethrough(armed.wrappedValue == removal)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            draft = profile?.label ?? ""
                            editing = true
                        }
                        .help("Click to change what this profile is shown as")
                    Button { open.toggle() } label: {
                        HStack(spacing: 6) {
                            summary.labelStyle(Tight())
                            if !claims.isEmpty { Image(systemName: "chevron.right").imageScale(.small).rotationEffect(.degrees(open ? 90 : 0)) }
                        }
                        .font(.caption2).foregroundStyle(.tertiary).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(claims.isEmpty).help("The work that belongs to this profile")
                }
                Spacer()
                Menu {
                    ForEach(running.titles.sorted { $0.key < $1.key }, id: \.key) { provider, title in
                        Button { running.signIn(provider: provider, profile: name) } label: {
                            Label { Text("Add a \(title) account") } icon: { providerMark(provider).map(Image.init(nsImage:)) }
                        }
                    }
                    Divider()
                    Button { running.claimFolders(for: name) } label: { Label("Add folders…", systemImage: "folder") }
                    Button { owning = true } label: { Label { Text("Add a repository owner") } icon: { githubMark().map(Image.init(nsImage:)) } }
                    // The default profile always exists.
                    if name != Config.defaultProfile {
                        Divider()
                        Button(role: .destructive) { armed.wrappedValue = removal } label: { Label("Remove this profile", systemImage: "trash") }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .bare()
                .help("Add an account, or work that belongs to this profile")
                .opacity(armed.wrappedValue == removal ? 0 : hovered || empty ? 1 : 0)
                .moves(.easeOut(duration: 0.12), with: hovered)
                .overlay(alignment: .trailing) {
                    if armed.wrappedValue == removal {
                        Confirm { running.removeProfile(name) }
                            .help("Its accounts and the work it claims go to the default profile. Its client folders are left as they are")
                    }
                }
                .moves(.snappy(duration: 0.18), with: armed.wrappedValue == removal)
            }
            if owning { OwnerField(profile: name) { owning = false } }
            if open, !claims.isEmpty {
                Flow { ForEach(claims, id: \.self) { claim in ClaimChip(claim: claim) { running.unclaim(claim, from: name) } } }.font(.caption2)
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

/// Where the next profile would be. A click types what it is to be shown as, and the check after the
/// name makes it; one half typed and walked away from is not made. An account let go here gets a profile
/// of its own: the name is offered from its address, and the check makes the profile with the account in it.
struct NewProfile: View {
    @Binding var founder: AccountStatus?
    /// Whether an account is being carried, and whether it is over this.
    let carrying: Bool
    let targeted: Bool
    @Environment(Running.self) private var running
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var typing: Bool

    private func type(_ text: String) {
        draft = text
        editing = true
    }

    private func leave() {
        editing = false
        founder = nil
    }

    private var named: Bool { !draft.trimmingCharacters(in: .whitespaces).isEmpty }

    private func make() {
        guard editing, named else { return }
        running.addProfile(shownAs: draft, with: founder)
        leave()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "plus").imageScale(.small).frame(width: 11, height: 16)
                if editing {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(.primary).focused($typing)
                        .frame(width: 150)
                        .onAppear { typing = true }
                        .onSubmit(make)
                        .onExitCommand(perform: leave)
                        .onChange(of: typing) { _, typing in if !typing { leave() } }
                    Confirm(undoable: true, ready: named, act: make, back: leave)
                } else {
                    Text(carrying ? "New profile for this account" : "New profile").font(.caption.weight(.semibold))
                }
                Spacer()
            }
            if editing, let founder {
                Text("\(founder.label) moves into it").font(.caption2).padding(.leading, 17)
            }
        }
        .foregroundStyle(carrying ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
        // While an account is carried this is a place to let it go, as large as it is easy to hit.
        .padding(carrying ? 10 : 0)
        .background(Color.accentColor.opacity(targeted ? 0.18 : 0), in: RoundedRectangle(cornerRadius: 10))
        .outlined(carrying)
        .padding(.leading, carrying ? -10 : 0)
        .contentShape(Rectangle())
        .onTapGesture { if !editing { type("") } }
        // The name offered is the address's own: what comes after the @, without its ending.
        .onChange(of: founder?.id) {
            guard let founder else { return }
            type(founder.label.split(separator: "@").dropFirst().first?.split(separator: ".").first.map(String.init) ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in leave() }
    }
}

/// One claim. Under the pointer its mark turns into the × that lets it go.
private struct ClaimChip: View {
    let claim: Claim
    let remove: () -> Void
    @State private var hovered = false

    private var look: (text: String, help: String) {
        switch claim {
        case .folder(let folder): (folder, "Work in \(folder) belongs to this profile")
        case .owner(let owner): (owner, "Work in a repository whose origin is \(owner)'s belongs to this profile")
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Button(action: remove) {
                Group {
                    if hovered { Image(systemName: "xmark") } else if case .owner = claim { OwnerMark() } else { Image(systemName: "folder") }
                }
                .frame(width: 11)
            }
                .buttonStyle(.plain).disabled(!hovered).help("Let it go: this work is then another profile's")
            Text(look.text).lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.vertical, 3).background(Color.primary.opacity(0.06), in: Capsule())
        .frame(maxWidth: 240)
        .onHover { hovered = $0 }
        .help(look.help)
    }
}

/// A mark and its number, close together.
private struct Tight: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon
            configuration.title
        }
    }
}

/// What marks a repository's owner: GitHub's mark, or failing the drawing an @.
struct OwnerMark: View {
    var body: some View {
        if let mark = githubMark() { Image(nsImage: mark).resizable().frame(width: 10, height: 10) } else { Image(systemName: "at") }
    }
}
