import Foundation
import SluiceCore
import SluiceProviders

let address = "http://localhost:\(Sluice.port)"
let arguments = CommandLine.arguments.dropFirst()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sluice: \(message)\n".utf8))
    exit(1)
}

switch arguments.first {
case "serve":
    do {
        let server = try await startSluice()
        print("sluice \(Sluice.version) on \(address)")
        while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) }
        withExtendedLifetime(server) {}
    } catch {
        fail("\(error)")
    }
case "login":
    let url = "\(address)/login/\(arguments.dropFirst().first ?? "claude")"
    print("Opening \(url)")
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = [url]
    do { try open.run() } catch { fail("\(error)") }
case "status":
    do {
        let (status, body) = try await HTTPCall.send("GET", URL(string: "\(address)/status")!)
        guard status == 200, let rows = try? JSONDecoder().decode([[String: String]].self, from: body) else { fail("unexpected answer (\(status))") }
        for row in rows { print("\(row["provider"] ?? "?")  \(row["label"] ?? "?")") }
        if rows.isEmpty { print("No accounts. Run: sluice login") }
    } catch {
        fail("not running (\(error.localizedDescription)). Start the app or run: sluice serve")
    }
default:
    print("""
    sluice \(Sluice.version)

      sluice serve              run the relay in the foreground
      sluice login [provider]   sign an account in (default: claude)
      sluice status             list signed-in accounts
    """)
}
