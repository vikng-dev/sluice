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
    var state = "Starting…"
    var problem = handoverProblem
    var routed = false
    var accounts: [AccountStatus] = []
    private var sluice: (server: Server, relay: Relay)?

    init() {
        check()
        Task {
            do {
                sluice = try await startSluice()
                state = "Relaying"
                // Only launchd starts a copy that left; one run by hand stays as it is.
                if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == keeperLabel { await follow() }
            } catch {
                state = "Not relaying: \(error)"
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
            if let relay = sluice?.relay {
                do { accounts = try await relay.status() } catch { problem = "\(error)" }
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
                state: running.state, problem: running.problem, accounts: running.accounts, now: Date(),
                routed: running.routed, route: running.route, quit: running.quit
            )
            .task { await running.watch() }
        } label: {
            Image(nsImage: gateGlyph(open: running.routed))
        }
        .menuBarExtraStyle(.window)
    }
}
