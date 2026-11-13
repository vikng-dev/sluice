import os
import ServiceManagement
import SluiceCore
import SluiceProviders
import SwiftUI

/// The launchd job that keeps the app running; its description is in the bundle (script/bundle.sh).
let keeperLabel = "dev.vikng.sluice.relay"
@MainActor let keeper = SMAppService.agent(plistName: "\(keeperLabel).plist")
@MainActor var handoverProblem = ""

/// The relay's life, started when the app launches, not when its panel is first opened.
@MainActor @Observable final class Running {
    var problem = handoverProblem
    var routed = false
    var accounts: [AccountStatus] = []
    var profiles: [String] = []
    var signIns: [String: [(provider: String, client: String, account: String?)]] = [:]
    private var sluice: (server: Server, relay: Relay)?

    init() {
        check()
        Task {
            do {
                sluice = try await startSluice()
                // Only launchd starts a copy that left; one run by hand stays as it is.
                if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == keeperLabel { await follow() }
            } catch {
                problem = "Not relaying: \(error)"
                Logger(subsystem: "dev.vikng.sluice", category: "app").error("not relaying: \(String(describing: error), privacy: .public)")
                // Clients may be set to talk to Sluice, so a kept copy does not sit there deaf: launchd starts it again.
                if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == keeperLabel { exit(1) }
            }
        }
    }

    /// A kept copy follows its own program file. Replaced by an upgrade, it leaves and launchd starts the
    /// new one. It does not wait for a quiet moment: under steady traffic none comes, the relay is back
    /// within a second, and the clients resend what was cut. Removed by an uninstall, it quits as from the menu.
    private func follow() async {
        let log = Logger(subsystem: "dev.vikng.sluice", category: "app")
        // The app's own executable always exists when it starts.
        let program = Bundle.main.executableURL!.path
        func found() -> UInt64? { ((try? FileManager.default.attributesOfItem(atPath: program))?[.systemFileNumber] as? NSNumber)?.uint64Value }
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

    /// Keeps the accounts current for the panel; reading them is local and asks no provider.
    func watch() async {
        while !Task.isCancelled {
            // `sluice setup` and a new profile change this from outside the app.
            check()
            if let relay = sluice?.relay {
                do {
                    accounts = try await relay.status()
                    profiles = try Storage.live.config().names
                    signIns = try Dictionary(uniqueKeysWithValues: profiles.map { ($0, try SluiceProviders.signIns(in: $0)) })
                } catch {
                    problem = "\(error)"
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Sets the clients up to use Sluice, or to talk to their providers again.
    func route(_ on: Bool) {
        // The app's own executable always exists.
        do { if on { try setUp(program: Bundle.main.executableURL!) } else { try stopRouting(all: false) } } catch { problem = "\(error)" }
        check()
    }

    private func check() {
        do { routed = try isSetUp() } catch { problem = "\(error)" }
    }

    /// The provider's sign-in page, in the browser; the account lands in `profile`.
    func signIn(provider: String, profile: String) {
        // A provider's id and a profile's name are plain characters.
        NSWorkspace.shared.open(URL(string: "http://localhost:\(Sluice.port)/login/\(provider)?profile=\(profile)")!)
    }

    func move(_ account: AccountStatus, to profile: String) {
        do { try Storage.live.change { try $0.move(account: account.label, to: profile) } } catch { problem = "\(error)" }
    }

    /// Asks first: signing in again needs the browser and the person.
    func remove(_ account: AccountStatus) {
        let alert = NSAlert()
        alert.messageText = "Remove \(account.label)?"
        alert.informativeText = "Sluice forgets this sign-in and stops using the account. Signing it in again needs the browser."
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
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

    var body: some Scene {
        MenuBarExtra {
            Panel(
                problem: running.problem, accounts: running.accounts, profiles: running.profiles, signIns: running.signIns,
                titles: Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.name) }), now: Date(),
                routed: running.routed, route: running.route, signIn: running.signIn, move: running.move, remove: running.remove, quit: running.quit
            )
            .task { await running.watch() }
        } label: {
            Image(nsImage: gateGlyph(open: running.routed))
        }
        .menuBarExtraStyle(.window)
    }
}
