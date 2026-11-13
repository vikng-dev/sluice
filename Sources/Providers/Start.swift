import Foundation
import SluiceCore

public let providers: [any Provider] = [Claude(), Codex()]

/// Starts the relay with every provider on Sluice's port.
public func startSluice() async throws -> Server {
    let relay = try Relay(providers: providers, storage: .live, port: Sluice.port)
    let server = try Server(port: Sluice.port) { try await relay.handle($0, $1) }
    try await server.start()
    return server
}

/// The clients that keep a folder per profile, which is what a stand-in chooses.
private var standIns: [String] { providers.filter { $0.home(of: Config.defaultProfile) != nil }.map(\.client) }

/// Sets this machine up: every client talks to Sluice in every profile, and `program` (Sluice itself)
/// stands in for the clients to open the right profile.
public func setUp(program: URL) throws {
    let profiles = try Storage.live.config().names
    for provider in providers { try provider.route(true, profiles: profiles) }
    try StandIns.install(standIns, program: program)
}

/// Makes every client talk to its provider again. With `all`, the stand-ins go too; without, they stay,
/// since work keeps belonging to its profile whether or not Sluice relays it.
public func stopRouting(all: Bool) throws {
    let profiles = try Storage.live.config().names
    for provider in providers { try provider.route(false, profiles: profiles) }
    if all { try StandIns.remove(standIns) }
}

public func isSetUp() throws -> Bool {
    let profiles = try Storage.live.config().names
    return try providers.allSatisfy { try $0.isRouted(profiles: profiles) } && standIns.allSatisfy(StandIns.isInstalled)
}
