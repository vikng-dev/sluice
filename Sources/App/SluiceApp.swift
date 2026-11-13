import ServiceManagement
import SluiceCore
import SluiceProviders
import SwiftUI

@main
struct SluiceApp: App {
    @State private var relay = "Starting…"
    @State private var login = ""
    @State private var server: Server?

    var body: some Scene {
        MenuBarExtra("Sluice", systemImage: "arrow.triangle.merge") {
            Text("Sluice \(Sluice.version)")
            Text(relay)
                .task {
                    do {
                        server = try await startSluice()
                        relay = "Relaying on port \(Sluice.port)"
                    } catch {
                        relay = "Not relaying: \(error.localizedDescription)"
                    }
                    // The clients fall back to going direct when Sluice is not running, so it starts with the Mac.
                    do {
                        if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                    } catch {
                        login = "Will not start at login: \(error.localizedDescription)"
                    }
                }
            if !login.isEmpty { Text(login) }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
