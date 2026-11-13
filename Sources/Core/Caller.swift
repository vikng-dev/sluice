import Darwin
import Foundation

/// What Sluice can tell about the program at the other end of a loopback connection.
enum Caller {
    /// The working folder of the process whose socket runs from `port` to `server`,
    /// or nil when no process of this user holds it any more.
    static func folder(ofLocalPort port: UInt16, to server: UInt16) -> String? {
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        for pid in pids.prefix(Int(max(count, 0))) where pid > 0 {
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size)
            let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, size)
            for descriptor in descriptors.prefix(Int(max(filled, 0)) / MemoryLayout<proc_fdinfo>.size) where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
                var socket = socket_fdinfo()
                guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socket, Int32(MemoryLayout<socket_fdinfo>.size)) > 0,
                      socket.psi.soi_kind == SOCKINFO_TCP else { continue }
                let ends = socket.psi.soi_proto.pri_tcp.tcpsi_ini
                guard UInt16(bigEndian: UInt16(truncatingIfNeeded: ends.insi_lport)) == port,
                      UInt16(bigEndian: UInt16(truncatingIfNeeded: ends.insi_fport)) == server else { continue }
                var paths = proc_vnodepathinfo()
                guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &paths, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return nil }
                return withUnsafeBytes(of: &paths.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            }
        }
        return nil
    }
}

/// The git repository a folder is in, read from its files.
enum Repo {
    /// The owner in the origin remote of the repository containing `folder`, lowercased:
    /// `acme` for `git@host:Acme/app.git` and for `https://host/acme/app`. Nil outside a repository, or with no origin.
    static func owner(of folder: String) -> String? {
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
