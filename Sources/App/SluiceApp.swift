import os
import ServiceManagement
import SluiceCore
import SluiceProviders
import SwiftUI

/// The launchd job that keeps the app running; its description is in the bundle (script/bundle.sh).
let keeperLabel = "\(Sluice.id).relay"
@MainActor let keeper = SMAppService.agent(plistName: "\(keeperLabel).plist")
let isKept = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == keeperLabel
@MainActor var handoverProblem = ""
private let log = Logger(subsystem: Sluice.id, category: "app")
// The app's own executable always exists.
private let program = Bundle.main.executableURL!

/// The relay's life, started when the app launches, not when its panel is first opened.
@MainActor @Observable final class Running {
    var problem = handoverProblem
    /// Why the last change to the profiles was refused.
    var refusal = ""
    var routed = false
    var accounts: [AccountStatus] = []
    var config = Config()
    var identities: [String: [Identity]] = [:]
    var history = History()
    private var sluice: (server: Server, relay: Relay)?
    @ObservationIgnored private var refreshing = false

    init() {
        check()
        Task {
            do {
                sluice = try await startSluice()
                Task { await watch() }
                // Only launchd starts a copy that left; one run by hand stays as it is.
                if isKept { await follow() }
            } catch {
                problem = "Not relaying: \(error)"
                log.error("not relaying: \(String(describing: error), privacy: .public)")
                // Clients may be set to talk to Sluice, so a kept copy does not sit there deaf: launchd starts it again.
                if isKept { exit(1) }
            }
        }
    }

    /// A kept copy follows its own program file. Replaced by an upgrade, it leaves and launchd starts the
    /// new one. It does not wait for a quiet moment: under steady traffic none comes, the relay is back
    /// within a second, and the clients resend what was cut. Removed by an uninstall, it quits as from the menu.
    private func follow() async {
        func found() -> UInt64? { ((try? FileManager.default.attributesOfItem(atPath: program.path))?[.systemFileNumber] as? NSNumber)?.uint64Value }
        var watch = ProgramWatch(launched: found())
        while true {
            try? await Task.sleep(for: .seconds(5))
            switch watch.verdict(found: found(), now: Date()) {
            case .stay:
                continue
            case .restart:
                log.notice("the app was replaced: restarting into it")
                exit(0)
            case .leave:
                log.notice("the app is gone: quitting")
                return quit()
            }
        }
    }

    /// Reading the accounts is local and asks no provider. It goes on while the panel is shut, as the
    /// menu bar shows the starred pools.
    private func watch() async {
        while !Task.isCancelled {
            // `sluice setup` and a new profile change this from outside the app.
            check()
            if let relay = sluice?.relay {
                do {
                    accounts = try await relay.status()
                    config = try Storage.live.config()
                    identities = try Dictionary(uniqueKeysWithValues: config.names.map { ($0, try SluiceProviders.identities(in: $0)) })
                } catch {
                    problem = "\(error)"
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func route(_ on: Bool) {
        do { if on { try setUp(program: program) } else { try stopRouting(all: false) } } catch { problem = "\(error)" }
        check()
    }

    private func check() {
        do { routed = try isSetUp() } catch { problem = "\(error)" }
    }

    func signIn(provider: String, profile: String) {
        // A provider's id and a profile's name are plain characters.
        NSWorkspace.shared.open(URL(string: "\(Sluice.address)/login/\(provider)?profile=\(profile)")!)
    }

    /// Changes the profiles, and shows the change at once. A refused one is said until the next that holds.
    private func change(_ edit: (inout Config) throws -> Void) {
        do {
            config = try Storage.live.change(edit)
            // The relay's own list follows at the next refresh.
            for index in accounts.indices { accounts[index].profile = config.profile(ofAccount: accounts[index].label) }
            refusal = ""
        } catch {
            refusal = "\(error)"
        }
    }

    /// A new profile has its own client folders, which are set to talk to Sluice like the others.
    /// Made for an account, the profile has it from the start.
    func addProfile(shownAs label: String, with founder: AccountStatus?) {
        change { config in
            let name = try config.add(profileShownAs: label)
            if let founder { try config.move(account: founder.label, to: name) }
        }
        if refusal.isEmpty, routed { route(true) }
    }

    /// Its accounts and what it claimed become the default profile's.
    func removeProfile(_ profile: String) {
        change { try $0.remove(profile: profile) }
    }

    /// Asks which folders. All of them are claimed, or none.
    func claimFolders(for profile: String) {
        let chooser = NSOpenPanel()
        chooser.canChooseDirectories = true
        chooser.canChooseFiles = false
        chooser.allowsMultipleSelection = true
        chooser.prompt = "Add"
        chooser.message = "Work in these folders belongs to \(config.shown(profile))."
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard chooser.runModal() == .OK else { return }
        change { config in for folder in chooser.urls { try config.claim(folder: folder.path, for: profile) } }
    }

    /// Asks which owner, offering those no profile claims yet.
    func claimOwner(for profile: String) {
        let claimed = Set(config.profiles.values.flatMap(\.owners).map { $0.lowercased() })
        func unclaimed(_ owners: [String]) -> [String] { owners.filter { !claimed.contains($0.lowercased()) } }
        guard let owner = askForOwner(of: config.shown(profile), known: unclaimed(knownOwners()), find: { unclaimed(await githubOwners(like: $0)) }) else { return }
        change { try $0.claim(owner: owner, for: profile) }
    }

    func unclaim(_ claim: Claim, from profile: String) {
        change { config in
            switch claim {
            case .folder(let folder): try config.unclaim(folder: folder, from: profile)
            case .owner(let owner): try config.unclaim(owner: owner, from: profile)
            }
        }
    }

    func move(_ account: AccountStatus, to profile: String) {
        change { try $0.move(account: account.label, to: profile) }
    }

    func tint(_ profile: String, _ tint: Tint?) {
        change { try $0.color(profile, tint) }
    }

    /// The panel was opened. The providers are asked again about usage told more than a minute ago and
    /// resets asked for more than ten minutes ago, so that what is looked at is current.
    func refresh() {
        guard let relay = sluice?.relay, !refreshing else { return }
        refreshing = true
        Task {
            await relay.checkUsage(olderThan: 60, resetsOlderThan: 600)
            if let told = try? await relay.status() { accounts = told }
            refreshing = false
        }
    }

    /// The histories are read off the main thread: a week of requests is many lines.
    func loadHistory() {
        Task {
            do {
                history = try await Task.detached { History(samples: try Storage.live.readings(), requests: try Storage.live.requests()) }.value
            } catch {
                problem = "\(error)"
            }
        }
    }

    func useReset(_ reset: Reset, of account: AccountStatus) {
        guard let relay = sluice?.relay else { return refusal = "The reset was not used: the relay is not running" }
        Task {
            do {
                try await relay.use(reset: reset.id, provider: account.provider, account: account.label)
                refusal = ""
            } catch let refused as ResetRefused {
                refusal = "The reset was not used: \(refused)"
            } catch {
                refusal = "The reset may have been used: \(error)"
            }
            if let told = try? await relay.status() { accounts = told }
        }
    }

    func star(_ profile: String, _ provider: String, _ starred: Bool) {
        change { try $0.star(profile, provider, starred) }
    }

    func autoReset(_ on: Bool) {
        change { $0.useResets(on) }
    }

    /// What the menu bar shows in place of the glyph: the starred pools by profile, each profile's colour
    /// and its pools by provider, with how much of each is used or left. Empty when none is starred.
    func counters(left: Bool) -> [(color: NSColor?, pools: [(provider: String, text: String)])] {
        config.names.map { profile in
            let starred = config.profiles[profile]?.starred ?? []
            let pools = Dictionary(grouping: accounts.filter { $0.profile == profile && starred.contains($0.provider) }, by: \.provider).sorted { $0.key < $1.key }.map { provider, pool in
                (provider: provider, text: "\(Int(((left ? 1 - pool.used : pool.used) * 100).rounded()))%")
            }
            return (config.profiles[profile]?.color.map { NSColor($0.color) }, pools)
        }
    }

    func rename(_ profile: String, to label: String) {
        change { try $0.label(profile, as: label) }
    }

    func remove(_ account: AccountStatus) {
        Task {
            do { try await forget(provider: account.provider, account: account.label) } catch { problem = "\(error)" }
        }
    }

    /// The clients would be left talking to nothing, so they go direct first; then launchd is told to let go.
    func quit() {
        route(false)
        do { if keeper.status == .enabled { try keeper.unregister() } } catch { problem = "\(error)" }
        NSApplication.shared.terminate(nil)
    }
}

struct SluiceApp: App {
    @State private var running = Running()
    @AppStorage("readsLeft") private var left = false
    private let titles = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.name) })

    var body: some Scene {
        MenuBarExtra {
            Panel(
                problem: running.problem.isEmpty ? running.refusal : running.problem, accounts: running.accounts, config: running.config, identities: running.identities, titles: titles, now: Date(),
                routed: running.routed, route: running.route, signIn: running.signIn, move: running.move, remove: running.remove, rename: running.rename, tint: running.tint, star: running.star, useReset: running.useReset, autoReset: running.autoReset,
                addProfile: running.addProfile, removeProfile: running.removeProfile,
                claimFolders: running.claimFolders, claimOwner: running.claimOwner, unclaim: { running.unclaim($1, from: $0) },
                history: running.history, loadHistory: running.loadHistory, refresh: running.refresh, quit: running.quit
            )
        } label: {
            // The glyph says whether clients are routed; while they are, the starred pools take its place.
            let counters = running.counters(left: left).filter { !$0.pools.isEmpty }
            Image(nsImage: counters.isEmpty || !running.routed ? gateGlyph(open: running.routed) : counterGlyph(counters))
        }
        .menuBarExtraStyle(.window)
    }
}
