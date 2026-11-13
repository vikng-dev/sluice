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
        guard status == 200 else { fail(String(decoding: body, as: UTF8.self)) }
        let rows = try JSONDecoder().decode([AccountStatus].self, from: body)
        let time = Date.FormatStyle(date: .omitted, time: .shortened), day = Date.FormatStyle().weekday(.abbreviated).hour().minute()
        for row in rows {
            let windows = row.windows.sorted { $0.resetsAt < $1.resetsAt }.map {
                "\($0.name) \(Int(($0.used * 100).rounded()))% → \($0.resetsAt.formatted($0.resetsAt.timeIntervalSinceNow < 86400 ? time : day))"
            }
            print([row.provider, row.label, row.pinOnly ? "pin-only" : "pool", windows.isEmpty ? "no usage seen" : windows.joined(separator: ", "), "\(row.warmConversations) warm"].joined(separator: "  "))
        }
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
