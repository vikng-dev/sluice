import Foundation

/// A change to the profiles that was refused, in words that say what to do instead.
public struct ConfigError: Error, CustomStringConvertible, Equatable {
    public let description: String
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

    /// Its accounts are then listed nowhere, which makes them the default profile's.
    mutating func remove(profile name: String) throws {
        guard name != Self.defaultProfile else { throw ConfigError(description: "the default profile always exists") }
        try require(name)
        profiles[name] = nil
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

    /// The account leaves the profile it is in and joins `profile`, as its main account when it has none.
    mutating func move(account label: String, to profile: String) throws {
        try require(profile)
        forget(account: label)
        if profiles[profile]?.main == nil {
            profiles[profile, default: Profile()].main = label
        } else if profile != Self.defaultProfile {
            // The default profile's further accounts are the ones listed nowhere.
            profiles[profile]?.accounts.append(label)
        }
    }

    /// The account becomes its profile's main one; the one it replaces stays in the profile.
    mutating func makeMain(_ label: String) {
        let name = profile(ofAccount: label)
        var profile = profiles[name] ?? Profile()
        if let old = profile.main, old != label, name != Self.defaultProfile { profile.accounts.append(old) }
        profile.accounts.removeAll { $0 == label }
        profile.main = label
        profiles[name] = profile
    }

    /// No profile lists the account any more.
    mutating func forget(account label: String) {
        for name in profiles.keys {
            if profiles[name]?.main == label { profiles[name]?.main = nil }
            profiles[name]?.accounts.removeAll { $0 == label }
        }
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
