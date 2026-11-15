import Foundation
import SluiceCore
import SluiceProviders

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sluice: \(message)\n".utf8))
    exit(1)
}

/// Run under a client's name (through a link made by `sluice setup`), this is that client's stand-in:
/// it opens the profile `StandIns.home` picks.
func standIn(for provider: any Provider, _ arguments: [String]) -> Never {
    guard let real = StandIns.real(provider.client, path: ProcessInfo.processInfo.environment["PATH"] ?? "") else {
        fail("no \(provider.client) on PATH besides this stand-in")
    }
    do {
        let config = try Storage.live.config(), variable = provider.home.variable
        let folder = StandIns.home(
            named: ProcessInfo.processInfo.environment[variable], in: config.profile(for: FileManager.default.currentDirectoryPath), of: config.names, folder: provider.folder
        )
        if let folder { setenv(variable, folder, 1) } else { unsetenv(variable) }
    } catch {
        fail("\(error)")
    }
    let argv = ([real] + arguments).map { strdup($0) } + [nil]
    execv(real, argv)
    fail("could not run \(real): \(String(cString: strerror(errno)))")
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
  sluice account refill <provider> <account> <reset>
                                                 use a reset the account holds, by its id in `status --json`;
                                                 what it refills is whole again at once, and it cannot be taken back

  sluice resets [auto | manual]                  whether a pool uses the resets it holds by itself: when it is out,
                                                 or one is about to lapse. With neither word, says which it is

  sluice statusline <provider> [--with <command>]
                                                 the line a client shows under its prompt, of the pool its folder's
                                                 profile has there, and after it what the command says
  sluice statusline on | off                     whether the clients show it
  sluice statusline items [<item> ...]           what that line says, in order: \(StatusLine.Item.allCases.map(\.rawValue).joined(separator: ", ")).
                                                 With no item, says what it is

  sluice setup [--undo]                          make your coding agents talk to Sluice and open the right profile
  sluice serve                                   run the relay in the foreground

Nothing asks a question. Results are on standard output, messages on standard error, and a failure
exits with 1 and says what to do. A change holds at once, without a restart.
"""

/// What cannot be done is thrown, and said where the command is run from.
func command(_ arguments: [String]) async throws {
    let json = arguments.contains("--json")
    let words = arguments.filter { !$0.hasPrefix("--") }
    switch (words.first, words.dropFirst().first) {
    case ("serve", nil):
        let server = try await startSluice().server
        print("sluice \(Sluice.version) on \(Sluice.address)")
        while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) }
        withExtendedLifetime(server) {}
    case ("login", _):
        let profile = values(of: "--profile", in: arguments).first
        let provider = words.dropFirst().first { $0 != profile } ?? "claude"
        let url = signInAddress(provider: provider, profile: profile)
        print("Opening \(url)")
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [url]
        try open.run()
    case ("status", nil):
        let rows = try await relayAccounts()
        if json { return printJSON(rows) }
        for profile in try Storage.live.config().names {
            let rows = rows.filter { $0.profile == profile }
            if rows.isEmpty { continue }
            print(([profile] + (try identities(in: profile).map(said))).joined(separator: "  "))
            for row in rows {
                let windows = (row.windows + row.scoped).map { "\($0.name) \($0.percentText) → \($0.resetsAt.timeText)" } + (row.resets.isEmpty ? [] : ["\(row.resets.map(\.left).reduce(0, +)) resets"])
                let plan = row.plan.map { ($0.business ? "business " : "") + $0.tier }
                // Said only once the week has shown it: how well its provider's formula holds on this account.
                let size = row.spread.map { "1% of its week is \(Int(row.size).formatted(.number.notation(.compactName))) weighed tokens ±\(Int(($0 * 100).rounded()))%" }
                print("  " + [row.provider, row.label, plan, row.problem ?? (windows.isEmpty ? "no usage reported" : windows.joined(separator: ", ")), size, "\(row.warmConversations) warm"].compactMap { $0 }.joined(separator: "  "))
            }
        }
        if rows.isEmpty { print("No accounts. Run: sluice login") }
    case ("resets", let mode):
        guard words.count <= 2, mode == nil || mode == "auto" || mode == "manual" else { fail("usage: sluice resets [auto | manual]") }
        let config = try mode.map { mode in try Storage.live.change { $0.useResets(mode == "auto") } } ?? Storage.live.config()
        if json { return printJSON(["resets": config.autoResets ? "auto" : "manual"]) }
        print(config.autoResets ? "auto: a pool uses the resets it holds when it is out, or one is about to lapse." : "manual: a reset is used only when told to, in the panel or with: sluice account refill")
    case ("statusline", "items"):
        let items = words.dropFirst(2).map { name -> StatusLine.Item in
            guard let item = StatusLine.Item(rawValue: name) else { fail("no status line item \(name); there is: \(StatusLine.Item.allCases.map(\.rawValue).joined(separator: ", "))") }
            return item
        }
        let config = try items.isEmpty ? Storage.live.config() : Storage.live.change { try $0.say(items) }
        if json { printJSON(config.statusLine) } else { print(config.statusLine.map(\.rawValue).joined(separator: " ")) }
    case ("statusline", let turn) where turn == "on" || turn == "off":
        try Storage.live.change { $0.showStatusLine(turn == "on") }
        if try isSetUp() { try showStatusLines(by: program()) }
        print(turn == "on" ? "The clients' status lines say the pool." : "The clients' status lines say nothing of Sluice's.")
    case ("statusline", _):
        let own = values(of: StatusLine.own, in: arguments).first, lined = statusShowing
        guard let provider = words.dropFirst().first(where: { $0 != own }).flatMap({ id in lined.first { $0.id == id } }) else { fail("say whose status line: \(lined.map(\.id).joined(separator: ", "))") }
        // The user's own line, run as the client would run it: by the shell, handed what the client hands this.
        var theirs = ""
        if let own {
            let shell = Process(), said = Pipe(), told = Pipe()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = ["-c", own]
            (shell.standardInput, shell.standardOutput) = (told, said)
            try shell.run()
            // A command that reads nothing may be gone before it is told: that is no failure of its line.
            signal(SIGPIPE, SIG_IGN)
            try? told.fileHandleForWriting.write(contentsOf: FileHandle.standardInput.readDataToEndOfFile())
            try told.fileHandleForWriting.close()
            theirs = String(decoding: said.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        // Under a prompt is no place to say what went wrong, a relay not running or a config not read:
        // Sluice's part is then left out, and the user's own line is said all the same.
        var ours = ""
        let now = Date()
        // The pool is the one the relay draws on: that of the profile the folder belongs to.
        if let config = try? Storage.live.config(), let accounts = try? await relayAccounts(), let readings = try? Storage.live.readings() {
            let profile = config.profile(for: FileManager.default.currentDirectoryPath)
            let pool = accounts.filter { $0.profile == profile && $0.provider == provider.id }
            if !pool.isEmpty {
                let samples = readings.filter { $0.at >= now.addingTimeInterval(-86400) }
                ours = terminalText(StatusLine.runs(config.statusLine, of: StatusLine.Pool(pool, profile: profile, config: config, samples: samples, now: now), now: now))
            }
        }
        print([ours, theirs].filter { !$0.isEmpty }.joined(separator: StatusLine.separator), terminator: theirs.isEmpty ? "\n" : "")
    case ("setup", nil):
        if arguments.contains("--undo") {
            try stopRouting(all: true)
            print("Your coding agents talk to their providers directly again, and open one profile everywhere.")
        } else {
            try setUp(program: program())
            print("Your coding agents now talk to Sluice. In a new shell, \(providers.map(\.client).joined(separator: " and ")) open the profile their folder belongs to. Undo with: sluice setup --undo")
        }
    case ("profile", "list"):
        let config = try Storage.live.config()
        let reports = try config.names.map { name in
            let profile = config.profiles[name], identities = try identities(in: name)
            let signedIn = Dictionary(uniqueKeysWithValues: identities.compactMap { identity in identity.account.map { (identity.client, $0) } })
            return (report: ProfileReport(name: name, label: profile?.label, color: profile?.color, starred: profile?.starred ?? [], signedIn: signedIn, accounts: profile?.accounts ?? [], folders: profile?.folders ?? [], owners: profile?.owners ?? []), identities: identities)
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
        // A new profile has its own client folder, which is set to talk to Sluice like the others.
        let routed = try isSetUp()
        try Storage.live.change { try $0.add(profile: words[2]) }
        if routed { try setUp(program: program()) }
        print("Added profile \(words[2]). Give it work with: sluice profile claim \(words[2]) --folder <path>")
    case ("profile", "rename"):
        guard words.count >= 3 else { fail("usage: sluice profile rename <name> [label]") }
        let config = try Storage.live.change { try $0.label(words[2], as: words.dropFirst(3).joined(separator: " ")) }
        print("Profile \(words[2]) is shown as \(config.shown(words[2])).")
    case ("profile", "color"):
        guard words.count == 4, words[3] == "none" || Tint(rawValue: words[3]) != nil else {
            fail("usage: sluice profile color <name> \(Tint.allCases.map(\.rawValue).joined(separator: " | ")) | none")
        }
        let color = Tint(rawValue: words[3])
        try Storage.live.change { try $0.color(words[2], color) }
        print("Profile \(words[2]) is \(color?.rawValue ?? "no color").")
    case ("profile", let verb) where verb == "star" || verb == "unstar":
        guard words.count == 4 else { fail("usage: sluice profile \(verb!) <name> <provider>") }
        guard providers.contains(where: { $0.id == words[3] }) else { fail("no provider \(words[3]); there is: \(providers.map(\.id).joined(separator: ", "))") }
        try Storage.live.change { try $0.star(words[2], words[3], verb == "star") }
        print("Profile \(words[2])'s \(words[3]) pool is \(verb == "star" ? "" : "no longer ")shown in the menu bar.")
    case ("profile", "remove"):
        guard words.count == 3 else { fail("usage: sluice profile remove <name>") }
        try Storage.live.change { try $0.remove(profile: words[2]) }
        print("Removed profile \(words[2]). Its accounts serve the default profile; its client folder is left as it is.")
    case ("profile", let verb) where verb == "claim" || verb == "unclaim":
        let folders = values(of: "--folder", in: arguments), owners = values(of: "--owner", in: arguments)
        // The name comes right after the verb, so that an option's value is never taken for it.
        guard arguments.count > 2, !arguments[2].hasPrefix("--"), !(folders.isEmpty && owners.isEmpty) else {
            fail("usage: sluice profile \(verb!) <name> --folder <path> | --owner <owner>")
        }
        let name = arguments[2]
        try Storage.live.change { config in
            for folder in folders { if verb == "claim" { try config.claim(folder: folder, for: name) } else { try config.unclaim(folder: folder, from: name) } }
            for owner in owners { if verb == "claim" { try config.claim(owner: owner, for: name) } else { try config.unclaim(owner: owner, from: name) } }
        }
        print("Profile \(name) \(verb == "claim" ? "now claims" : "no longer claims") \((folders + owners).joined(separator: ", ")).")
    case ("account", "move"):
        guard words.count == 4 else { fail("usage: sluice account move <account> <profile>") }
        let known = try await relayAccounts().map(\.label)
        guard known.contains(words[2]) else { fail("no account \(words[2]); there is: \(Set(known).sorted().joined(separator: ", "))") }
        try Storage.live.change { try $0.move(account: words[2], to: words[3]) }
        print("\(words[2]) now serves profile \(words[3]).")
    case ("account", "remove"):
        guard words.count == 4 else { fail("usage: sluice account remove <provider> <account>") }
        try await forget(provider: words[2], account: words[3])
        print("Removed the \(words[2]) account \(words[3]).")
    case ("account", "refill"):
        guard words.count == 5 else { fail("usage: sluice account refill <provider> <account> <reset>") }
        try await useReset(words[4], provider: words[2], account: words[3])
        print("Used the reset \(words[4]) of the \(words[2]) account \(words[3]).")
    default:
        if let first = words.first, first != "help" { fail("no such command: \(words.joined(separator: " ")). Run sluice for the list.") }
        print(usage)
    }
}
