import Foundation
import SluiceCore

public let providers: [any Provider] = [Claude(), Codex()]

/// Starts the relay with every provider on Sluice's port, and keeps every account's usage current:
/// a request's answer updates the account it went through, and the rest are asked every five minutes.
public func startSluice() async throws -> (server: Server, relay: Relay) {
    let relay = try Relay(providers: providers, storage: .live, port: Sluice.port)
    let server = try Server(port: Sluice.port) { try await relay.handle($0, $1) }
    try await server.start()
    Task {
        while !Task.isCancelled {
            await relay.checkUsage()
            try await Task.sleep(for: .seconds(300))
        }
    }
    return (server, relay)
}

/// The clients that keep a folder per profile, which is what a stand-in chooses.
private var standIns: [String] { providers.filter { $0.home(of: Config.defaultProfile) != nil }.map(\.client) }

private func profiles() throws -> [String] { try Storage.live.config().names }

/// Each client that keeps a folder per profile, and whom it is itself signed in as in `profile`.
public func identities(in profile: String) throws -> [Identity] {
    try providers.filter { $0.home(of: profile) != nil }.map { Identity(provider: $0.id, client: $0.client, account: try $0.signedIn(in: profile)) }
}

/// What a command could not do, in words that say what to do instead.
public struct CommandError: Error, CustomStringConvertible {
    public let description: String
}

/// A call to the running relay. One that cannot be made says the relay is not running; one it refuses
/// says so in the relay's own words.
private func relay(_ method: String, _ path: String) async throws -> Data {
    let answer: (status: Int, body: Data)
    // `path` is made here, of plain or percent-encoded segments.
    do { answer = try await HTTPCall.send(method, URL(string: Sluice.address + path)!) } catch {
        throw CommandError(description: "not running (\(error.localizedDescription)). Start the app or run: sluice serve")
    }
    guard answer.status == 200 else { throw CommandError(description: String(decoding: answer.body, as: UTF8.self).replacing("sluice: ", with: "")) }
    return answer.body
}

public func relayAccounts() async throws -> [AccountStatus] {
    try JSONDecoder().decode([AccountStatus].self, from: try await relay("GET", "/status"))
}

/// Forgets a sign-in: the running relay drops it, and the profiles stop listing a name no account has any more.
public func forget(provider: String, account label: String) async throws {
    // The account's name is one segment of the address, whatever characters it has.
    guard let segment = label.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { throw CommandError(description: "unreadable account name") }
    _ = try await relay("DELETE", "/accounts/\(provider)/\(segment)")
    // The same name may still be signed in at another provider, and then the profiles keep it.
    if try await !relayAccounts().contains(where: { $0.label == label }) { try Storage.live.change { $0.forget(account: label) } }
}

/// Sets this machine up: every client talks to Sluice in every profile, and `program` (Sluice itself)
/// stands in for the clients to open the right profile.
public func setUp(program: URL) throws {
    for provider in providers { try provider.route(true, profiles: try profiles()) }
    try StandIns.install(standIns, program: program)
}

/// Makes every client talk to its provider again. With `all`, the stand-ins go too; without, they stay,
/// since work keeps belonging to its profile whether or not Sluice relays it.
public func stopRouting(all: Bool) throws {
    for provider in providers { try provider.route(false, profiles: try profiles()) }
    if all { try StandIns.remove(standIns) }
}

public func isSetUp() throws -> Bool {
    let profiles = try profiles()
    return try providers.allSatisfy { try $0.isRouted(profiles: profiles) } && standIns.allSatisfy(StandIns.isInstalled)
}
