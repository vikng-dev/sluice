import ServiceManagement
import SluiceCore
import SluiceProviders
import SwiftUI

/// The relay's life, started when the app launches, not when its menu is first opened.
@MainActor @Observable final class Running {
    var relay = "Starting…"
    var login = ""
    private var server: Server?

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
                login = "Will not start at login: \(error.localizedDescription)"
            }
        }
    }
}

struct SluiceApp: App {
    @State private var running = Running()

    var body: some Scene {
        MenuBarExtra("Sluice", systemImage: "arrow.triangle.merge") {
            Text("Sluice \(Sluice.version)")
            Text(running.relay)
            if !running.login.isEmpty { Text(running.login) }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
