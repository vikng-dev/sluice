import SluiceCore
import SwiftUI

@main
struct SluiceApp: App {
    var body: some Scene {
        MenuBarExtra("Sluice", systemImage: "arrow.triangle.merge") {
            Text("Sluice \(Sluice.version)")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
