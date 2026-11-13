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
            } catch {
                state = "Not relaying: \(error)"
                Logger(subsystem: "dev.vikng.sluice", category: "app").error("not relaying: \(String(describing: error), privacy: .public)")
                // Clients may be set to talk to Sluice, so a kept copy does not sit there deaf: launchd starts it again.
                if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == keeperLabel { exit(1) }
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
