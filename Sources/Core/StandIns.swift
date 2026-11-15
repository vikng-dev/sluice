import Foundation

/// The commands that stand in for the clients: each is a link to Sluice, which picks the profile for the
/// folder it is run in and then runs the real client. They work whether or not the relay is running.
public enum StandIns {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/sluice/bin")
    static let line = #"export PATH="$HOME/.config/sluice/bin:$PATH" # sluice"#

    /// The user's shell startup file, where the line that puts the stand-ins first on PATH goes.
    private static func startup() throws -> UserFile {
        let shell = URL(fileURLWithPath: String(cString: getpwuid(getuid()).pointee.pw_shell)).lastPathComponent
        guard ["zsh", "bash"].contains(shell) else {
            throw UserFileError(path: shell, reason: "Sluice does not know this shell's startup file; add this line to it yourself: \(line)")
        }
        return UserFile(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".\(shell)rc"))
    }

    private static func lines(of file: UserFile) throws -> [String] {
        String(decoding: try file.read() ?? Data(), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// The folder a client is to open, as its own variable names it; nil for its usual one. It is the
    /// folder of `profile`, which the current folder belongs to, unless the variable already names a
    /// profile's folder: the user named that profile for this launch. A folder that is no profile's, as
    /// a shell from an older setup may still name, is passed over.
    public static func home(named: String?, in profile: String, of profiles: [String], folder: (String) -> URL) -> String? {
        func path(_ profile: String) -> String { folder(profile).standardizedFileURL.path }
        let asked = named.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let opened = profiles.first { path($0) == asked } ?? profile
        return opened == Config.defaultProfile ? nil : path(opened)
    }

    public static func install(_ commands: [String], program: URL) throws {
        try remove(commands)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for command in commands { try FileManager.default.createSymbolicLink(at: folder.appending(path: command), withDestinationURL: program) }
        let file = try startup()
        var lines = try lines(of: file)
        if lines.last == "" { lines.removeLast() }
        try file.write(Data((lines + [line, ""]).joined(separator: "\n").utf8))
    }

    public static func remove(_ commands: [String]) throws {
        for command in commands where isInstalled(command) { try FileManager.default.removeItem(at: folder.appending(path: command)) }
        let file = try startup(), lines = try lines(of: file)
        if lines.contains(line) { try file.write(Data(lines.filter { $0 != line }.joined(separator: "\n").utf8)) }
    }

    public static func isInstalled(_ command: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: folder.appending(path: command).path)) != nil
    }

    /// The real `command`: the first one on `path` after the stand-ins' folder, so a wrapper ahead of
    /// the stand-in that hands on to it is not run again; anywhere on `path` when the folder is not on it.
    public static func real(_ command: String, path: String) -> String? {
        let folders = path.split(separator: ":").map { URL(fileURLWithPath: String($0)).standardizedFileURL.path }
        let own = folder.standardizedFileURL.path
        let after = folders.firstIndex(of: own).map { Array(folders[($0 + 1)...]) } ?? folders
        return after.filter { $0 != own }.map { $0 + "/" + command }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
