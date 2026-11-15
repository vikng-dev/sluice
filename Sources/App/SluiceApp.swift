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

/// The app's state and what its panel can do, as the panel's views read and ask it.
@MainActor @Observable final class Running {
    /// What each provider's subscriptions are sold as, by its id.
    let titles = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.name) })
    /// Why Sluice is not relaying, which stays so until it is started again.
    var problem = handoverProblem
    /// What could not be read at the last look, gone at the next that reads it.
    var unread = ""
    /// Why the last thing asked of the panel was not done, gone at the next that is.
    var refusal = ""
    /// The one of them the panel says.
    var said: String { [problem, unread, refusal].first { !$0.isEmpty } ?? "" }
    var routed = false
    var accounts: [AccountStatus] = []
    /// By account, how many requests it is at work on now, for those that are or were within the last
    /// minute: what the bars beside an account show.
    private(set) var levels: [String: Int] = [:]
    var config = Config()
    /// By profile.
    var identities: [String: [Identity]] = [:]
    var history = History()
    private var sluice: (server: Server, relay: Relay)?
    @ObservationIgnored private var refreshing = false

    /// Starts the relay, when the app launches and not when its panel is first opened.
    func start() {
        routed = (try? isSetUp()) ?? false
        // A machine set up by an older Sluice has no status line yet.
        if routed { attempt { try showStatusLines(by: program) } }
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
            do {
                // `sluice setup` and a new profile change this from outside the app.
                routed = try isSetUp()
                if let relay = sluice?.relay {
                    accounts = try await relay.status()
                    config = try Storage.live.config()
                    identities = try Dictionary(uniqueKeysWithValues: config.names.map { ($0, try SluiceProviders.identities(in: $0)) })
                }
                unread = ""
            } catch {
                unread = "\(error)"
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func route(_ on: Bool) {
        attempt {
            defer { routed = (try? isSetUp()) ?? routed }
            if on { try setUp(program: program) } else { try stopRouting(all: false) }
        }
    }

    /// Does what the panel asked. One that fails is said until the next that works.
    private func attempt(_ action: () throws -> Void) {
        do {
            try action()
            refusal = ""
        } catch {
            refusal = "\(error)"
        }
    }

    /// The same for what is asked of the relay, whose accounts are then read again.
    private func attempt(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
                refusal = ""
            } catch {
                refusal = "\(error)"
            }
            if let told = try? await sluice?.relay.status() { accounts = told }
        }
    }

    func signIn(provider: String, profile: String) {
        // A provider's id and a profile's name are plain characters.
        NSWorkspace.shared.open(URL(string: signInAddress(provider: provider, profile: profile))!)
    }

    /// Changes the profiles, and shows the change at once. A refused one is said until the next that holds.
    private func change(_ edit: (inout Config) throws -> Void) {
        attempt {
            config = try Storage.live.change(edit)
            // The relay's own list follows at the next refresh.
            for index in accounts.indices { accounts[index].profile = config.profile(ofAccount: accounts[index].label) }
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
        // Not wherever a picker was last left, which may hold a folder of the same name as the one meant.
        chooser.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        chooser.message = "Work in these folders belongs to \(config.shown(profile))."
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard chooser.runModal() == .OK else { return }
        change { config in for folder in chooser.urls { try config.claim(folder: folder.path, for: profile) } }
    }

    /// Of `owners`, those no profile claims yet.
    private func unclaimed(_ owners: [String]) -> [String] {
        let claimed = Set(config.profiles.values.flatMap(\.owners).map { $0.lowercased() })
        return owners.filter { !claimed.contains($0.lowercased()) }
    }

    /// The owners a profile could claim: those of the repositories on this Mac, and those GitHub finds for what is typed.
    func ownersHere() -> [String] { unclaimed(knownOwners()) }
    func owners(like text: String) async -> [String] { unclaimed(await githubOwners(like: text)) }

    func claim(owner: String, for profile: String) {
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

    /// While the panel is looked at, the relay is asked every second which accounts are at work, and the
    /// bars are told only when that has changed.
    func meter() async {
        while !Task.isCancelled, let relay = sluice?.relay {
            if let told = try? await relay.status() { measure(told, now: Date()) }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func measure(_ told: [AccountStatus], now: Date) {
        let levels = Dictionary(told.filter { $0.streaming > 0 || $0.lastAnswered.map { now.timeIntervalSince($0) < 60 } == true }.map { ($0.id, $0.streaming) }, uniquingKeysWith: +)
        if levels != self.levels { self.levels = levels }
    }

    /// The histories are read off the main thread: a week of requests is many lines.
    func loadHistory() {
        Task {
            do {
                history = try await Task.detached { History(samples: try Storage.live.readings(), requests: try Storage.live.requests()) }.value
            } catch {
                refusal = "\(error)"
            }
        }
    }

    /// Spends the reset. Asked of the relay as the command does, so that what came of it is said in the same words.
    func useReset(_ reset: Reset, of account: AccountStatus) {
        attempt { try await SluiceProviders.useReset(reset.id, provider: account.provider, account: account.label) }
    }

    func star(_ profile: String, _ provider: String, _ starred: Bool) {
        change { try $0.star(profile, provider, starred) }
    }

    /// What the clients' status lines say from now on. The line is run afresh each time it is shown, so
    /// only turning it on or off is told to the clients.
    func say(_ items: [StatusLine.Item]) {
        change { try $0.say(items) }
    }

    func showStatusLine(_ on: Bool) {
        change { $0.showStatusLine(on) }
        if refusal.isEmpty, routed { attempt { try showStatusLines(by: program) } }
    }

    func autoReset(_ on: Bool) {
        change { $0.useResets(on) }
    }

    /// What the menu bar shows in place of the glyph: the profiles with a starred pool, each with its
    /// colour and its starred pools by provider, with how much of each is used or left.
    func counters(left: Bool) -> [(color: NSColor?, pools: [(provider: String, text: String)])] {
        config.names.compactMap { profile in
            let starred = config.profiles[profile]?.starred ?? []
            let pools = Dictionary(grouping: accounts.filter { $0.profile == profile && starred.contains($0.provider) }, by: \.provider).sorted { $0.key < $1.key }.map { provider, pool in
                (provider: provider, text: Share.text(pool.used, left: left))
            }
            return pools.isEmpty ? nil : (config.profiles[profile]?.color.map { NSColor($0.color) }, pools)
        }
    }

    func rename(_ profile: String, to label: String) {
        change { try $0.label(profile, as: label) }
    }

    func remove(_ account: AccountStatus) {
        attempt { try await forget(provider: account.provider, account: account.label) }
    }

    /// The clients would be left talking to nothing, so they go direct first; then launchd is told to let go.
    func quit() {
        route(false)
        do { if keeper.status == .enabled { try keeper.unregister() } } catch { refusal = "\(error)" }
        NSApplication.shared.terminate(nil)
    }
}

struct SluiceApp: App {
    private let running = Running()
    @AppStorage(Share.key) private var left = false

    init() { running.start() }

    var body: some Scene {
        MenuBarExtra {
            Panel(now: Date()).environment(running)
        } label: {
            // The glyph says whether clients are routed; while they are, the starred pools take its place.
            let counters = running.counters(left: left)
            Image(nsImage: counters.isEmpty || !running.routed ? gateGlyph(open: running.routed) : counterGlyph(counters))
        }
        .menuBarExtraStyle(.window)
    }
}
