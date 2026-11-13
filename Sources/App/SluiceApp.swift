import ServiceManagement
import SluiceCore
import SluiceProviders
import SwiftUI

/// The relay's life, started when the app launches, not when its menu is first opened.
@MainActor @Observable final class Running {
    var relay = "Starting…"
    var problem = ""
    var routed = providers.allSatisfy { Local.isLinked($0.client) }
    private var server: Server?
    private let clients = providers.map(\.client)

    init() {
        Task {
            do {
                server = try await startSluice()
                relay = "Relaying on port \(Sluice.port)"
            } catch {
                relay = "Not relaying: \(error.localizedDescription)"
            }
            // The clients go direct when Sluice is not running, so it starts with the Mac.
            do {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } catch {
                problem = "Will not start at login: \(error.localizedDescription)"
            }
        }
    }

    /// Turns the stand-ins for the clients on or off.
    func route(_ on: Bool) {
        do {
            // The app's own executable always exists.
            if on { try Local.link(["sluice"] + clients, to: Bundle.main.executableURL!) } else { try Local.unlink(clients) }
            problem = ""
        } catch {
            problem = "Could not change the stand-ins: \(error.localizedDescription)"
        }
        routed = clients.allSatisfy(Local.isLinked)
    }
}

struct SluiceApp: App {
    @State private var running = Running()

    var body: some Scene {
        MenuBarExtra("Sluice", systemImage: "arrow.triangle.merge") {
            Text("Sluice \(Sluice.version)")
            Text(running.relay)
            if !running.problem.isEmpty { Text(running.problem) }
            Divider()
            Toggle("Route claude and codex through Sluice", isOn: Binding(get: { running.routed }, set: { running.route($0) }))
            if running.routed {
                Button("Copy the PATH line for your shell") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Local.pathLine, forType: .string)
                }
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
