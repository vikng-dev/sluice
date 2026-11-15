import Foundation

/// The git repository a folder is in, read from its files.
public enum Repo {
    /// The owner in the origin remote of the repository containing `folder`, lowercased:
    /// `acme` for `git@host:Acme/app.git` and for `https://host/acme/app`. Nil outside a repository, or with no origin.
    public static func owner(of folder: String) -> String? {
        var url = URL(fileURLWithPath: folder)
        while url.path != "/" {
            if let config = config(of: url.appending(path: ".git")) { return originOwner(in: config) }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// The repository's config, given its `.git`: a folder, or in a worktree a file naming the folder,
    /// which in turn names the repository it shares its config with.
    private static func config(of dotGit: URL) -> String? {
        var folder = dotGit
        if let pointer = try? String(contentsOf: dotGit, encoding: .utf8), pointer.hasPrefix("gitdir: ") {
            folder = URL(fileURLWithPath: pointer.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: dotGit.deletingLastPathComponent())
            if let common = try? String(contentsOf: folder.appending(path: "commondir"), encoding: .utf8) {
                folder = URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: folder.appending(path: "x"))
            }
        }
        return try? String(contentsOf: folder.appending(path: "config"), encoding: .utf8)
    }

    static func originOwner(in config: String) -> String? {
        var inOrigin = false
        for line in config.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("[") { inOrigin = line == #"[remote "origin"]"#; continue }
            guard inOrigin, line.hasPrefix("url"), let address = line.split(separator: "=", maxSplits: 1).last else { continue }
            let parts = address.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == "/" || $0 == ":" })
            return parts.count >= 2 ? parts[parts.count - 2].lowercased() : nil
        }
        return nil
    }
}
