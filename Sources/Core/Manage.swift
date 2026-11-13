import Foundation

/// A change to the profiles that was refused, in words that say what to do instead.
public struct ConfigError: Error, CustomStringConvertible, Equatable {
    public let description: String
}

public extension Storage {
    /// Changes the profiles on disk. The relay reads them at each request, so a change holds at once.
    @discardableResult func change(_ edit: (inout Config) throws -> Void) throws -> Config {
        var next = try config()
        try edit(&next)
        try storeConfig(next)
        return next
    }
}

/// The changes a person or an agent makes to the profiles. Each leaves the config valid or throws.
public extension Config {
    /// A profile's name is also the end of its client folder's name, so it is kept to plain characters.
    mutating func add(profile name: String) throws {
        guard name.wholeMatch(of: /[a-z0-9][a-z0-9-]*/) != nil else {
            throw ConfigError(description: "a profile's name is lowercase letters, digits and dashes: \(name)")
        }
        guard !names.contains(name) else { throw ConfigError(description: "there is already a profile named \(name)") }
        profiles[name] = Profile()
    }

    /// A new profile from what it is to be shown as. Its name is the label's plain characters, numbered
    /// when another profile has them; the label is kept where it says more than the name.
    @discardableResult mutating func add(profileShownAs label: String) throws -> String {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw ConfigError(description: "a profile needs a name") }
        let plain = label.lowercased().split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) }).joined(separator: "-")
        let base = plain.isEmpty ? "profile" : plain
        var name = base, count = 1
        while names.contains(name) {
            count += 1
            name = "\(base)-\(count)"
        }
        try add(profile: name)
        if label != name { try self.label(name, as: label) }
        return name
    }

    /// Its accounts are then listed nowhere, which makes them the default profile's.
    mutating func remove(profile name: String) throws {
        guard name != Self.defaultProfile else { throw ConfigError(description: "the default profile always exists") }
        try require(name)
        profiles[name] = nil
    }

    /// A label is what the profile is shown as; its name stays what its folders and the commands go by.
    /// An empty one takes the label away. No two profiles are shown as the same thing.
    mutating func label(_ profile: String, as label: String) throws {
        try require(profile)
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let other = names.first(where: { $0 != profile && [$0, shown($0)].contains { $0.lowercased() == label.lowercased() } }) {
            throw ConfigError(description: "profile \(other) already goes by \(label)")
        }
        profiles[profile, default: Profile()].label = label.isEmpty ? nil : label
    }

    mutating func color(_ profile: String, _ color: Tint?) throws {
        try require(profile)
        profiles[profile, default: Profile()].color = color
    }

    /// A pool is a profile's accounts at one provider, so its star is kept under the provider's name.
    mutating func star(_ profile: String, _ provider: String, _ starred: Bool) throws {
        try require(profile)
        profiles[profile, default: Profile()].starred.removeAll { $0 == provider }
        if starred { profiles[profile, default: Profile()].starred.append(provider) }
    }

    /// Whether the pool uses the resets it holds without being asked, kept like its star.
    mutating func autoReset(_ profile: String, _ provider: String, _ on: Bool) throws {
        try require(profile)
        profiles[profile, default: Profile()].autoResets.removeAll { $0 == provider }
        if on { profiles[profile, default: Profile()].autoResets.append(provider) }
    }

    mutating func claim(folder: String, for profile: String, home: String = NSHomeDirectory()) throws {
        try require(profile)
        let folder = Self.written(folder, home: home)
        if let other = profiles.first(where: { $0.value.folders.contains { Self.written($0, home: home) == folder } })?.key {
            if other == profile { return }
            throw ConfigError(description: "\(folder) belongs to profile \(other); release it first: sluice profile unclaim \(other) --folder \(folder)")
        }
        profiles[profile, default: Profile()].folders.append(folder)
    }

    mutating func claim(owner: String, for profile: String) throws {
        try require(profile)
        if let other = profiles.first(where: { $0.value.owners.contains { $0.lowercased() == owner.lowercased() } })?.key {
            if other == profile { return }
            throw ConfigError(description: "\(owner) belongs to profile \(other); release it first: sluice profile unclaim \(other) --owner \(owner)")
        }
        profiles[profile, default: Profile()].owners.append(owner)
    }

    mutating func unclaim(folder: String, from profile: String, home: String = NSHomeDirectory()) throws {
        let folder = Self.written(folder, home: home)
        guard profiles[profile]?.folders.contains(where: { Self.written($0, home: home) == folder }) == true else {
            throw ConfigError(description: "profile \(profile) does not claim \(folder)")
        }
        profiles[profile]?.folders.removeAll { Self.written($0, home: home) == folder }
    }

    mutating func unclaim(owner: String, from profile: String) throws {
        guard profiles[profile]?.owners.contains(where: { $0.lowercased() == owner.lowercased() }) == true else {
            throw ConfigError(description: "profile \(profile) does not claim \(owner)")
        }
        profiles[profile]?.owners.removeAll { $0.lowercased() == owner.lowercased() }
    }

    mutating func move(account label: String, to profile: String) throws {
        try require(profile)
        forget(account: label)
        // The default profile's accounts are the ones listed nowhere.
        if profile != Self.defaultProfile { profiles[profile, default: Profile()].accounts.append(label) }
    }

    mutating func forget(account label: String) {
        for name in profiles.keys { profiles[name]?.accounts.removeAll { $0 == label } }
    }

    private func require(_ profile: String) throws {
        guard names.contains(profile) else {
            throw ConfigError(description: "no profile named \(profile); there is: \(names.joined(separator: ", "))")
        }
    }

    /// A folder as the config writes it: absolute, without `..` or a closing slash, and from `~` when under
    /// home. Links are followed, since a program's working folder is reported with them followed.
    private static func written(_ folder: String, home: String) -> String {
        let given = folder.hasPrefix("~") ? home + folder.dropFirst() : folder
        let real = realpath(given, nil)
        defer { free(real) }
        // A folder that does not exist yet has no links to follow.
        let absolute = real.map { String(cString: $0) } ?? URL(fileURLWithPath: given).standardizedFileURL.path
        return absolute == home ? "~" : absolute.hasPrefix(home + "/") ? "~" + absolute.dropFirst(home.count) : absolute
    }
}
