import Foundation
import ServiceManagement
import SluiceProviders

// One program, three roles by how it is run: under a client's name it is that client's stand-in;
// as `sluice`, or with arguments, it is the command; opened as an app it is the menu bar app.
let name = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
let arguments = Array(CommandLine.arguments.dropFirst())
if let provider = providers.first(where: { $0.client == name }) {
    standIn(for: provider, arguments)
} else if arguments.isEmpty, name != "sluice" {
    // Clients are set to talk to Sluice, so launchd keeps it running. Opened by hand, the app
    // (re)starts that kept copy and leaves. A development build has no bundle to register and runs as it is.
    if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != keeperLabel, Bundle.main.bundleIdentifier != nil {
        do {
            if keeper.status == .enabled { try keeper.unregister() }
            try keeper.register()
            exit(0)
        } catch {
            handoverProblem = "Not kept running: \(error.localizedDescription)"
        }
    }
    SluiceApp.main()
} else {
    Task {
        await command(arguments)
        exit(0)
    }
    dispatchMain()
}
