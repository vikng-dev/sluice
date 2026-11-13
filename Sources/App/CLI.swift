import Foundation
import SluiceCore
import SluiceProviders

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sluice: \(message)\n".utf8))
    exit(1)
}

/// Run under a client's name (through a link made by `sluice setup`), this is that client's stand-in:
/// it points the real client at Sluice when Sluice is running, and otherwise just runs it.
func standIn(for provider: any Provider, _ arguments: [String]) -> Never {
    // Other tools wrap these clients too, and some hand control back to the first one on PATH: this one.
    // `SLUICE_TRIED` lists what was already run on the way here, so each pass moves on to the next candidate.
    let shims = Local.shims.standardizedFileURL.path
    let tried = (ProcessInfo.processInfo.environment["SLUICE_TRIED"] ?? "").split(separator: ":").map(String.init)
    let folders = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).standardizedFileURL.path }
    let candidates = folders.filter { $0 != shims }.map { $0 + "/" + provider.client }
    guard let real = candidates.first(where: { !tried.contains($0) && FileManager.default.isExecutableFile(atPath: $0) }) else {
        fail("no \(provider.client) on PATH besides this stand-in")
    }
    setenv("SLUICE_TRIED", (tried + [real]).joined(separator: ":"), 1)
    var launch = arguments
    if tried.isEmpty, Local.isRunning {
        do {
            let pointing = provider.pointing(launch, at: try Local.address(provider: provider.id, directory: FileManager.default.currentDirectoryPath))
            // A value the user set for this launch wins over Sluice's.
            for (name, value) in pointing.environment { setenv(name, value, 0) }
            launch = pointing.arguments
        } catch {
            fail("\(error)")
        }
    }
    let argv = ([real] + launch).map { strdup($0) } + [nil]
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
            for row in rows {
                let windows = row.windows.sorted { $0.resetsAt < $1.resetsAt }.map {
                    "\($0.name) \(Int(($0.used * 100).rounded()))% → \($0.resetsAt.formatted($0.resetsAt.timeIntervalSinceNow < 86400 ? time : day))"
                }
                print([row.provider, row.label, row.pinOnly ? "pin-only" : "pool", windows.isEmpty ? "no usage seen" : windows.joined(separator: ", "), "\(row.warmConversations) warm"].joined(separator: "  "))
            }
            if rows.isEmpty { print("No accounts. Run: sluice login") }
        } catch {
            fail("not running (\(error.localizedDescription)). Start the app or run: sluice serve")
        }
    case "setup":
        let clients = providers.map(\.client)
        do {
            if arguments.dropFirst().first == "--undo" {
                try Local.unlink(clients)
                print("Removed the stand-ins: \(clients.joined(separator: " and ")) run directly again.")
                break
            }
            guard let me = Bundle.main.executableURL?.resolvingSymlinksInPath() else { fail("could not find this program's own path") }
            try Local.link(["sluice"] + clients, to: me)
        } catch {
            fail("\(error)")
        }
        let first = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").first.map { URL(fileURLWithPath: String($0)).standardizedFileURL.path }
        print("Linked sluice, \(clients.joined(separator: " and ")) in \(Local.shims.path).")
        print(first == Local.shims.standardizedFileURL.path ? "They go through Sluice whenever it is running." : """

        Put that folder first on your PATH, as the last line of your shell's startup file:

          \(Local.pathLine)

        New shells then run \(clients.joined(separator: " and ")) through Sluice whenever it is running.
        Undo with: sluice setup --undo
        """)
    case "address":
        guard let provider = arguments.dropFirst().first else { fail("usage: sluice address <provider>") }
        do { print(try Local.address(provider: provider, directory: FileManager.default.currentDirectoryPath)) } catch { fail("\(error)") }
    default:
        print("""
        sluice \(Sluice.version)

          sluice serve              run the relay in the foreground
          sluice login [provider]   sign an account in (default: claude)
          sluice status             accounts, their windows, and warm conversations
          sluice setup [--undo]     make claude and codex go through Sluice when it is running
          sluice address <provider> the address a client in this folder would use
        """)
    }
}
