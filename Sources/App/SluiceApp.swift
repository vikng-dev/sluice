import os
import ServiceManagement
import SluiceCore
import SluiceProviders
import SwiftUI

/// The launchd job that keeps the app running; its description is in the bundle (script/bundle.sh).
let keeperLabel = "dev.vikng.sluice.relay"
@MainActor let keeper = SMAppService.agent(plistName: "\(keeperLabel).plist")
@MainActor var handoverProblem = ""

/// The relay's life, started when the app launches, not when its menu is first opened.
@MainActor @Observable final class Running {
    var relay = "Starting…"
    var problem = handoverProblem
    var routed = false
    private var server: Server?

    init() {
        check()
        Task {
            do {
                server = try await startSluice()
                relay = "Relaying on port \(Sluice.port)"
            } catch {
                relay = "Not relaying: \(error)"
                Logger(subsystem: "dev.vikng.sluice", category: "app").error("not relaying: \(String(describing: error), privacy: .public)")
                // Clients may be set to talk to Sluice, so a kept copy does not sit there deaf: launchd starts it again.
                if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == keeperLabel { exit(1) }
            }
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
            Text("Sluice \(Sluice.version)")
            Text(running.relay)
            if !running.problem.isEmpty { Text(running.problem) }
            Divider()
            Toggle("Route Claude Code and Codex through Sluice", isOn: Binding(get: { running.routed }, set: { running.route($0) }))
            Divider()
            Button("Quit, and route nothing") { running.quit() }
                .keyboardShortcut("q")
        } label: {
            Image(nsImage: gateGlyph(open: running.routed))
        }
    }
}
