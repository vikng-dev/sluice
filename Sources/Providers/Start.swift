import SluiceCore

/// Starts the relay with every provider on Sluice's port.
public func startSluice() async throws -> Server {
    let relay = try Relay(providers: [Claude()], vault: .keychain, port: Sluice.port)
    let server = try Server(port: Sluice.port) { try await relay.handle($0, $1) }
    try await server.start()
    return server
}
