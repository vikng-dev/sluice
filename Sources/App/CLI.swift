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

private func accounts() async -> [AccountStatus] {
    do { return try await relayAccounts() } catch { fail("\(error)") }
}

/// This program's own file, which the stand-ins link to.
private func program() -> URL {
    guard let me = Bundle.main.executableURL?.resolvingSymlinksInPath() else { fail("could not find this program's own path") }
    return me
}

/// Results go to standard output as JSON an agent can read: sorted keys, and dates as ISO 8601.
private func printJSON(_ value: some Encodable) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    // These are plain values of strings, numbers and dates.
    print(String(decoding: try! encoder.encode(value), as: UTF8.self))
}

/// A profile as `sluice profile list` reports it.
private struct ProfileReport: Encodable {
    var name: String
    var label: String?
    var color: Tint?
    /// The providers whose pool here is shown in the menu bar.
    var starred: [String]
    /// By client: the account it is itself signed in as in the profile.
    var signedIn: [String: String]
    var accounts: [String]
    var folders: [String]
    var owners: [String]
}

/// A client's own sign-in in a profile, in words.
private func said(_ identity: Identity) -> String {
    identity.account.map { "\(identity.client) signed in as \($0)" } ?? "\(identity.client) not signed in"
}

/// Changes the profiles on disk, or says why not.
private func change(_ edit: (inout Config) throws -> Void) -> Config {
    do { return try Storage.live.change(edit) } catch { fail("\(error)") }
}

/// The values given for a repeatable option, e.g. every `--folder <path>`.
private func values(of option: String, in arguments: [String]) -> [String] {
    arguments.indices.filter { arguments[$0] == option }.map { index in
        guard index + 1 < arguments.count else { fail("\(option) needs a value") }
        return arguments[index + 1]
    }
}

private let usage = """
sluice \(Sluice.version)

  sluice status [--json]                         each profile's accounts: plan, usage windows, warm conversations
  sluice login [provider] [--profile <name>]     sign an account in through the browser (default: claude),
                                                 for that profile (default: where it is, or the default profile)

  sluice profile list [--json]                   the profiles: who the client is signed in as, and what each claims
  sluice profile add <name>                      a new, empty profile
  sluice profile remove <name>                   its accounts go back to the default profile
  sluice profile rename <name> [label]           what it is shown as; with no label, its name again
  sluice profile color <name> <color>            \(Tint.allCases.map(\.rawValue).joined(separator: ", ")), or none
  sluice profile star <name> <provider>          show how much of that pool is used in the menu bar
  sluice profile unstar <name> <provider>
  sluice profile claim <name> --folder <path>    work in that folder belongs to the profile
  sluice profile claim <name> --owner <owner>    so do repositories whose origin has that owner
  sluice profile unclaim <name> --folder <path> | --owner <owner>

  sluice account move <account> <profile>        the account serves that profile from now on
  sluice account remove <provider> <account>     forget the sign-in

  sluice setup [--undo]                          make Claude Code and Codex talk to Sluice and open the right profile
  sluice serve                                   run the relay in the foreground

Nothing asks a question. Results are on standard output, messages on standard error, and a failure
exits with 1 and says what to do. A change holds at once, without a restart.
"""

func command(_ arguments: [String]) async {
    let json = arguments.contains("--json")
    let words = arguments.filter { !$0.hasPrefix("--") }
    switch (words.first, words.dropFirst().first) {
    case ("serve", nil):
        do {
            let server = try await startSluice().server
            print("sluice \(Sluice.version) on \(Sluice.address)")
            while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) }
            withExtendedLifetime(server) {}
        } catch {
            fail("\(error)")
        }
    case ("login", _):
        let profile = values(of: "--profile", in: arguments).first
        let provider = words.dropFirst().first { $0 != profile } ?? "claude"
        let url = "\(Sluice.address)/login/\(provider)" + (profile.map { "?profile=\($0)" } ?? "")
        print("Opening \(url)")
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [url]
        do { try open.run() } catch { fail("\(error)") }
    case ("status", nil):
        let rows = await accounts()
        if json { return printJSON(rows) }
        for (profile, rows) in Dictionary(grouping: rows, by: \.profile).sorted(by: { ($0.key == Config.defaultProfile ? "" : $0.key) < ($1.key == Config.defaultProfile ? "" : $1.key) }) {
            let signedIn: [String]
            do { signedIn = try identities(in: profile).map(said) } catch { fail("\(error)") }
            print(([profile] + signedIn).joined(separator: "  "))
            for row in rows {
                let windows = row.windows.map { "\($0.name) \($0.percentText) → \($0.resetText)" }
                let plan = row.plan.map { ($0.business ? "business " : "") + $0.tier }
                print("  " + [row.provider, row.label, plan, row.problem ?? (windows.isEmpty ? "no usage reported" : windows.joined(separator: ", ")), "\(row.warmConversations) warm"].compactMap { $0 }.joined(separator: "  "))
            }
        }
        if rows.isEmpty { print("No accounts. Run: sluice login") }
    case ("setup", nil):
        do {
            if arguments.contains("--undo") {
                try stopRouting(all: true)
                print("Claude Code and Codex talk to their providers directly again, and open one profile everywhere.")
            } else {
                try setUp(program: program())
                print("Claude Code and Codex now talk to Sluice. In a new shell, claude and codex open the profile their folder belongs to. Undo with: sluice setup --undo")
            }
        } catch {
            fail("\(error)")
        }
    case ("profile", "list"):
        let reports: [(report: ProfileReport, identities: [Identity])]
        do {
            let config = try Storage.live.config()
            reports = try config.names.map { name in
                let profile = config.profiles[name], identities = try identities(in: name)
                let signedIn = Dictionary(uniqueKeysWithValues: identities.compactMap { identity in identity.account.map { (identity.client, $0) } })
                return (ProfileReport(name: name, label: profile?.label, color: profile?.color, starred: profile?.starred ?? [], signedIn: signedIn, accounts: profile?.accounts ?? [], folders: profile?.folders ?? [], owners: profile?.owners ?? []), identities)
            }
        } catch {
            fail("\(error)")
        }
        if json { return printJSON(reports.map(\.report)) }
        for (report, identities) in reports {
            let look = [report.label, report.color?.rawValue].compactMap { $0 }.joined(separator: ", ")
            print(([report.name + (look.isEmpty ? "" : " (\(look))")] + identities.map(said)).joined(separator: "  "))
            for (title, items) in [("accounts", report.accounts), ("folders", report.folders), ("owners", report.owners), ("starred", report.starred)] where !items.isEmpty {
                print("  \(title): \(items.joined(separator: ", "))")
            }
        }
    case ("profile", "add"):
        guard words.count == 3 else { fail("usage: sluice profile add <name>") }
        do {
            // A new profile has its own client folder, which is set to talk to Sluice like the others.
            let routed = try isSetUp()
            _ = change { try $0.add(profile: words[2]) }
            if routed { try setUp(program: program()) }
        } catch {
            fail("\(error)")
        }
        print("Added profile \(words[2]). Give it work with: sluice profile claim \(words[2]) --folder <path>")
    case ("profile", "rename"):
        guard words.count >= 3 else { fail("usage: sluice profile rename <name> [label]") }
        let config = change { try $0.label(words[2], as: words.dropFirst(3).joined(separator: " ")) }
        print("Profile \(words[2]) is shown as \(config.shown(words[2])).")
    case ("profile", "color"):
        guard words.count == 4, words[3] == "none" || Tint(rawValue: words[3]) != nil else {
            fail("usage: sluice profile color <name> \(Tint.allCases.map(\.rawValue).joined(separator: " | ")) | none")
        }
        let color = Tint(rawValue: words[3])
        _ = change { try $0.color(words[2], color) }
        print("Profile \(words[2]) is \(color?.rawValue ?? "no color").")
    case ("profile", let verb) where verb == "star" || verb == "unstar":
        guard words.count == 4 else { fail("usage: sluice profile \(verb!) <name> <provider>") }
        guard providers.contains(where: { $0.name == words[3] }) else { fail("no provider \(words[3]); there is: \(providers.map(\.name).joined(separator: ", "))") }
        _ = change { try $0.star(words[2], words[3], verb == "star") }
        print("Profile \(words[2])'s \(words[3]) pool is \(verb == "star" ? "" : "no longer ")shown in the menu bar.")
    case ("profile", "remove"):
        guard words.count == 3 else { fail("usage: sluice profile remove <name>") }
        _ = change { try $0.remove(profile: words[2]) }
        print("Removed profile \(words[2]). Its accounts serve the default profile; its client folder is left as it is.")
    case ("profile", let verb) where verb == "claim" || verb == "unclaim":
        let folders = values(of: "--folder", in: arguments), owners = values(of: "--owner", in: arguments)
        // The name comes right after the verb, so that an option's value is never taken for it.
        guard arguments.count > 2, !arguments[2].hasPrefix("--"), !(folders.isEmpty && owners.isEmpty) else {
            fail("usage: sluice profile \(verb!) <name> --folder <path> | --owner <owner>")
        }
        let name = arguments[2]
        _ = change { config in
            for folder in folders { if verb == "claim" { try config.claim(folder: folder, for: name) } else { try config.unclaim(folder: folder, from: name) } }
            for owner in owners { if verb == "claim" { try config.claim(owner: owner, for: name) } else { try config.unclaim(owner: owner, from: name) } }
        }
        print("Profile \(name) \(verb == "claim" ? "now claims" : "no longer claims") \((folders + owners).joined(separator: ", ")).")
    case ("account", "move"):
        guard words.count == 4 else { fail("usage: sluice account move <account> <profile>") }
        let known = await accounts().map(\.label)
        guard known.contains(words[2]) else { fail("no account \(words[2]); there is: \(Set(known).sorted().joined(separator: ", "))") }
        _ = change { try $0.move(account: words[2], to: words[3]) }
        print("\(words[2]) now serves profile \(words[3]).")
    case ("account", "remove"):
        guard words.count == 4 else { fail("usage: sluice account remove <provider> <account>") }
        do { try await forget(provider: words[2], account: words[3]) } catch { fail("\(error)") }
        print("Removed the \(words[2]) account \(words[3]).")
    default:
        if let first = words.first, first != "help" { fail("no such command: \(words.joined(separator: " ")). Run sluice for the list.") }
        print(usage)
    }
}
