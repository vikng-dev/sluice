import Foundation
import SluiceCore
import SluiceProviders

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sluice: \(message)\n".utf8))
    exit(1)
}

/// Run under a client's name (through a link made by `sluice setup`), this is that client's stand-in:
/// it opens the profile the current folder belongs to. A profile the user named for this launch wins.
func standIn(for provider: any Provider, _ arguments: [String]) -> Never {
    guard let real = StandIns.real(provider.client, path: ProcessInfo.processInfo.environment["PATH"] ?? "") else {
        fail("no \(provider.client) on PATH besides this stand-in")
    }
    do {
        let profile = try Storage.live.config().profile(for: FileManager.default.currentDirectoryPath)
        if profile != Config.defaultProfile, let home = provider.home(of: profile) { setenv(home.variable, home.folder.path, 0) }
    } catch {
        fail("\(error)")
    }
    let argv = ([real] + arguments).map { strdup($0) } + [nil]
    execv(real, argv)
    fail("could not run \(real): \(String(cString: strerror(errno)))")
}

/// The `sluice` command.
func command(_ arguments: [String]) async {
    let address = "http://localhost:\(Sluice.port)"
    switch arguments.first {
    case "serve":
        do {
            let server = try await startSluice()
            print("sluice \(Sluice.version) on \(address)")
            while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) }
            withExtendedLifetime(server) {}
        } catch {
            fail("\(error)")
        }
    case "login":
        let url = "\(address)/login/\(arguments.dropFirst().first ?? "claude")"
        print("Opening \(url)")
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [url]
        do { try open.run() } catch { fail("\(error)") }
    case "status":
        do {
            let (status, body) = try await HTTPCall.send("GET", URL(string: "\(address)/status")!)
            guard status == 200 else { fail(String(decoding: body, as: UTF8.self)) }
            let rows = try JSONDecoder().decode([AccountStatus].self, from: body)
            let time = Date.FormatStyle(date: .omitted, time: .shortened), day = Date.FormatStyle().weekday(.abbreviated).hour().minute()
            for (profile, rows) in Dictionary(grouping: rows, by: \.profile).sorted(by: { ($0.key == Config.defaultProfile ? "" : $0.key) < ($1.key == Config.defaultProfile ? "" : $1.key) }) {
                print(profile)
                for row in rows {
                    let windows = row.windows.sorted { $0.resetsAt < $1.resetsAt }.map {
                        "\($0.name) \(Int(($0.used * 100).rounded()))% → \($0.resetsAt.formatted($0.resetsAt.timeIntervalSinceNow < 86400 ? time : day))"
                    }
                    print("  " + [row.provider, row.label + (row.main ? " (main)" : ""), windows.isEmpty ? "no usage seen" : windows.joined(separator: ", "), "\(row.warmConversations) warm"].joined(separator: "  "))
                }
            }
            if rows.isEmpty { print("No accounts. Run: sluice login") }
        } catch {
            fail("not running (\(error.localizedDescription)). Start the app or run: sluice serve")
        }
    case "setup":
        do {
            if arguments.dropFirst().first == "--undo" {
                try stopRouting(all: true)
                print("Claude Code and Codex talk to their providers directly again, and open one profile everywhere.")
            } else {
                guard let me = Bundle.main.executableURL?.resolvingSymlinksInPath() else { fail("could not find this program's own path") }
                try setUp(program: me)
                print("Claude Code and Codex now talk to Sluice. In a new shell, claude opens the profile its folder belongs to. Undo with: sluice setup --undo")
            }
        } catch {
            fail("\(error)")
        }
    default:
        print("""
        sluice \(Sluice.version)

          sluice serve              run the relay in the foreground
          sluice login [provider]   sign an account in (default: claude)
          sluice status             each profile's accounts, their windows, and warm conversations
          sluice setup [--undo]     make Claude Code and Codex talk to Sluice and open the right profile
        """)
    }
}
