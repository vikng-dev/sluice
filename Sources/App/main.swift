import Foundation
import SluiceProviders

// One program, three roles by how it is run: under a client's name it is that client's stand-in;
// as `sluice`, or with arguments, it is the command; opened as an app, with neither, it is the menu bar app.
let name = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
let arguments = Array(CommandLine.arguments.dropFirst())
if let provider = providers.first(where: { $0.client == name }) {
    standIn(for: provider, arguments)
} else if arguments.isEmpty, name != "sluice" {
    SluiceApp.main()
} else {
    Task {
        await command(arguments)
        exit(0)
    }
    dispatchMain()
}
