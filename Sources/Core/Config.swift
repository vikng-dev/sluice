import Foundation

/// The colors a profile can be told apart by.
/// A profile's colour, one of a soft scale. None of them is a colour that means something elsewhere:
/// red, orange and green are kept for how a limit stands.
public enum Tint: String, Codable, Sendable, CaseIterable {
    case pink, purple, indigo, blue, aqua, teal, sand, slate
}

/// One separate setup: the accounts whose usage it pools, and the work that belongs to it.
public struct Profile: Codable, Sendable, Equatable {
    /// What the user calls it, where its name in the config is not what they want to read.
    public internal(set) var label: String?
    public internal(set) var color: Tint?
    /// The providers whose pool here is shown in the menu bar.
    public internal(set) var starred: [String] = []
    /// The accounts that serve its relayed requests.
    public internal(set) var accounts: [String] = []
    /// Folders (`~` allowed) whose work belongs to this profile.
    public internal(set) var folders: [String] = []
    /// Owners, as in a repository's origin remote, whose repositories belong to this profile.
    public internal(set) var owners: [String] = []

    init() {}

    public init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        label = try keys.decodeIfPresent(String.self, forKey: .label)
        // A colour the scale no longer has, as a config from an older Sluice may name, is no colour.
        color = try keys.decodeIfPresent(String.self, forKey: .color).flatMap(Tint.init)
        starred = try keys.decodeIfPresent([String].self, forKey: .starred) ?? []
        accounts = try keys.decodeIfPresent([String].self, forKey: .accounts) ?? []
        folders = try keys.decodeIfPresent([String].self, forKey: .folders) ?? []
        owners = try keys.decodeIfPresent([String].self, forKey: .owners) ?? []
    }

    /// Only what is set is written, as a person would write it.
    public func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: CodingKeys.self)
        try keys.encodeIfPresent(label, forKey: .label)
        try keys.encodeIfPresent(color, forKey: .color)
        if !starred.isEmpty { try keys.encode(starred, forKey: .starred) }
        if !accounts.isEmpty { try keys.encode(accounts, forKey: .accounts) }
        if !folders.isEmpty { try keys.encode(folders, forKey: .folders) }
        if !owners.isEmpty { try keys.encode(owners, forKey: .owners) }
    }

    private enum CodingKeys: CodingKey { case label, color, starred, accounts, folders, owners }
}

/// `config.json`, written by hand or by the `sluice` command: the profiles, and what holds for them all. Work no profile claims, and
/// an account no profile lists, belong to the profile named `default`, which exists whether or not it
/// is written down.
public struct Config: Codable, Sendable, Equatable {
    public static let defaultProfile = "default"
    public internal(set) var profiles: [String: Profile] = [:]
    /// A pool uses the resets its accounts hold without being asked: when it is out, and before one lapses.
    public internal(set) var autoResets = false
    /// Whether the clients' status lines say anything of Sluice's, and what, in order.
    public internal(set) var statusLineOn = true
    public internal(set) var statusLine = StatusLine.usual

    public init() {}

    public init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try keys.decodeIfPresent([String: Profile].self, forKey: .profiles) ?? [:]
        autoResets = try keys.decodeIfPresent(Bool.self, forKey: .autoResets) ?? false
        statusLineOn = try keys.decodeIfPresent(Bool.self, forKey: .statusLineOn) ?? true
        statusLine = try (keys.decodeIfPresent([String].self, forKey: .statusLine))?.map { name in
            guard let item = StatusLine.Item(rawValue: name) else {
                throw DecodingError.dataCorruptedError(forKey: .statusLine, in: keys, debugDescription: "no status line item \(name); there is: \(StatusLine.Item.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return item
        } ?? StatusLine.usual
        guard !statusLine.isEmpty else { throw DecodingError.dataCorruptedError(forKey: .statusLine, in: keys, debugDescription: "a status line says something; to say nothing, set statusLineOn to false") }
    }

    /// Only what is set is written, as a person would write it.
    public func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: CodingKeys.self)
        try keys.encode(profiles, forKey: .profiles)
        if autoResets { try keys.encode(true, forKey: .autoResets) }
        if !statusLineOn { try keys.encode(false, forKey: .statusLineOn) }
        if statusLine != StatusLine.usual { try keys.encode(statusLine, forKey: .statusLine) }
    }

    private enum CodingKeys: CodingKey { case profiles, autoResets, statusLineOn, statusLine }

    /// Every profile's name, the default first.
    public var names: [String] { [Self.defaultProfile] + profiles.keys.filter { $0 != Self.defaultProfile }.sorted() }

    /// What a profile is shown as: its label, or failing one its name.
    public func shown(_ profile: String) -> String { profiles[profile]?.label ?? profile }

    /// The profile that work in `directory` belongs to: the one claiming the deepest folder containing it,
    /// or else the one claiming the owner of the repository it is in, or else the default.
    public func profile(for directory: String, home: String = NSHomeDirectory(), owner: (String) -> String? = Repo.owner) -> String {
        func folder(_ rule: String) -> String { (rule.hasPrefix("~") ? home + rule.dropFirst() : rule).trimmingSuffix("/") + "/" }
        let claims = profiles.flatMap { name, profile in profile.folders.map { (name: name, folder: folder($0)) } }
        if let claim = claims.filter({ (directory.trimmingSuffix("/") + "/").hasPrefix($0.folder) }).max(by: { $0.folder.count < $1.folder.count }) { return claim.name }
        guard profiles.values.contains(where: { !$0.owners.isEmpty }), let owner = owner(directory) else { return Self.defaultProfile }
        return profiles.first { $0.value.owners.contains { $0.lowercased() == owner } }?.key ?? Self.defaultProfile
    }

    /// The profile an account belongs to.
    public func profile(ofAccount label: String) -> String {
        profiles.first { $0.value.accounts.contains(label) }?.key ?? Self.defaultProfile
    }

    /// The accounts that may pay for `profile`'s work: its own and no other's, so a profile with none
    /// at a provider cannot use that provider.
    func pool(_ accounts: [Account], for profile: String) -> [Account] {
        accounts.filter { self.profile(ofAccount: $0.label) == profile }
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String { hasSuffix(suffix) ? String(dropLast(suffix.count)) : self }
}
