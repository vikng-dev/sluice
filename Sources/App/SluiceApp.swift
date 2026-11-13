import SluiceCore
import SluiceProviders
import SwiftUI

@main
struct SluiceApp: App {
    @State private var state = "Starting…"
    @State private var server: Server?

    var body: some Scene {
        MenuBarExtra("Sluice", systemImage: "arrow.triangle.merge") {
            Text("Sluice \(Sluice.version)")
            Text(state)
                .task {
                    do {
                        server = try await startSluice()
                        state = "Relaying on port \(Sluice.port)"
                    } catch {
                        state = "Not relaying: \(error.localizedDescription)"
                    }
                }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
