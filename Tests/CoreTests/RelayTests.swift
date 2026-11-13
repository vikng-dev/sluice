import Foundation
import Testing
@testable import SluiceCore

/// A provider whose upstream is a local server: account `a` is spent, any other account serves.
private struct Fake: Provider {
    let id = "fake"
    let upstream: URL
    let redirect: URL? = nil
    let client = "fake"
    func home(of profile: String) -> (variable: String, folder: URL)? { nil }
    func route(_ on: Bool, profiles: [String]) {}
    func isRouted(profiles: [String]) -> Bool { false }
    func authorizeURL(redirectURI: String, state: String, challenge: String) -> URL { upstream }
    func signIn(code: String, state: String, redirectURI: String, verifier: String) async throws -> Account { throw ProviderError.signedOut }
    func refresh(_ account: Account) async throws -> Account { account }
    func prepare(_ request: inout HTTPRequest, for account: Account) { request.setHeader("X-Account", account.label) }
    func conversation(of request: HTTPRequest) -> (id: String, cacheLifetime: TimeInterval)? { nil }
    func reading(status: Int, headers: [String: String]) -> Reading {
        Reading(windows: status == 429 ? [Window(name: "week", used: 1, resetsAt: .distantFuture)] : [], refused: status == 429)
    }
}

private actor Hits {
    var accounts: [String] = []
    func add(_ account: String) { accounts.append(account) }
}

@Suite struct RelayTests {
    @Test func aSpentAccountsRefusalNeverReachesTheClientWhileAnotherCanServe() async throws {
        let hits = Hits()
        let provider = try Server(port: 47611) { request, writer in
            let account = request.header("X-Account") ?? ""
            await hits.add(account)
            if account == "a" { return try await writer.send(429, text: "spent") }
            let parts = AsyncStream<Data> { $0.yield(Data("served by ".utf8)); $0.yield(Data("\(account) \(request.target)".utf8)); $0.finish() }
            try await writer.send(200, headers: [], body: parts)
        }
        try await provider.start()
        let accounts = ["a", "b"].map { Account(provider: "fake", subject: $0, organization: nil, label: $0, accessToken: "", refreshToken: "", expiresAt: .distantFuture) }
        let relay = try Relay(providers: [Fake(upstream: URL(string: "http://127.0.0.1:47611")!)], storage: Storage(loadAccounts: { accounts }, storeAccounts: { _ in }, config: { Config() }, loadMemory: { Memory() }, storeMemory: { _ in }), port: 47612)
        let server = try Server(port: 47612) { try await relay.handle($0, $1) }
        try await server.start()

        let url = URL(string: "http://127.0.0.1:47612/fake/v1/thing?x=1")!
        let first = try await HTTPCall.send("GET", url)
        #expect(first.status == 200)
        #expect(String(decoding: first.body, as: UTF8.self) == "served by b /v1/thing?x=1")
        // `a` is now known spent, so the next request does not ask it again.
        _ = try await HTTPCall.send("GET", url)
        #expect(await hits.accounts == ["a", "b", "b"])

        let pinned = try await HTTPCall.send("GET", URL(string: "http://127.0.0.1:47612/fake/pin/a/v1/thing")!)
        #expect(pinned.status == 429)
        withExtendedLifetime((provider, server)) {}
    }
}
