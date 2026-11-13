import Foundation
import os
import Testing
@testable import SluiceCore

/// A provider whose upstream is a local server: account `a` is spent, any other account serves.
private struct Fake: Provider {
    let id = "fake"
    let upstream: URL
    let redirect: URL? = nil
    let client = "fake"
    let name = "Fake"
    func home(of profile: String) -> (variable: String, folder: URL)? { nil }
    func signedIn(in profile: String) throws -> String? { nil }
    func folders(in profile: String) throws -> [String] { [] }
    func count(_ event: Data, into spend: inout Spend) {}
    func route(_ on: Bool, profiles: [String]) {}
    func isRouted(profiles: [String]) -> Bool { false }
    func usage(of account: Account) async throws -> Usage { Usage(plan: nil, windows: []) }
    func authorizeURL(redirectURI: String, state: String, challenge: String) -> URL {
        signsInAs == nil ? upstream : URL(string: "\(redirectURI)?code=c&state=\(state)")!
    }
    /// With a name, the sign-in page is the relay's own callback and the sign-in is that account's.
    var signsInAs: String?
    func signIn(code: String, state: String, redirectURI: String, verifier: String) async throws -> Account {
        guard let signsInAs else { throw ProviderError.signedOut }
        return Account(provider: id, subject: signsInAs, organization: nil, label: signsInAs, accessToken: "", refreshToken: "", expiresAt: .distantFuture)
    }
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
        let relay = try Relay(providers: [Fake(upstream: URL(string: "http://127.0.0.1:47611")!)], storage: Storage(loadAccounts: { accounts }, storeAccounts: { _ in }, config: { Config() }, storeConfig: { _ in }, loadMemory: { Memory() }, storeMemory: { _ in }), port: 47612)
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

    @Test func aSignInStartedForAProfileLandsThereAndOneForNoProfileStaysPut() async throws {
        let work = try JSONDecoder().decode(Config.self, from: Data(#"{"profiles":{"work":{}}}"#.utf8))
        let stored = OSAllocatedUnfairLock(initialState: (accounts: [Account](), config: work))
        let storage = Storage(
            loadAccounts: { stored.withLock { $0.accounts } }, storeAccounts: { next in stored.withLock { $0.accounts = next } },
            config: { stored.withLock { $0.config } }, storeConfig: { next in stored.withLock { $0.config = next } }, loadMemory: { Memory() }, storeMemory: { _ in }
        )
        let relay = try Relay(providers: [Fake(upstream: URL(string: "http://127.0.0.1:1")!, signsInAs: "w")], storage: storage, port: 47616)
        let server = try Server(port: 47616) { try await relay.handle($0, $1) }
        try await server.start()

        #expect(try await HTTPCall.send("GET", URL(string: "http://localhost:47616/login/fake?profile=nowhere")!).status == 404)
        #expect(try await HTTPCall.send("GET", URL(string: "http://localhost:47616/login/fake?profile=work")!).status == 200)
        #expect(try await relay.status().map(\.profile) == ["work"])
        // Signing the same account in again, for no profile, renews it where it is.
        #expect(try await HTTPCall.send("GET", URL(string: "http://localhost:47616/login/fake")!).status == 200)
        #expect(try await relay.status().map(\.profile) == ["work"])
        withExtendedLifetime(server) {}
    }

    @Test func aPinDoesNotReachIntoAnotherProfile() async throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(#"{"profiles":{"work":{"accounts":["w"]}}}"#.utf8))
        let stored = ["w", "mine"].map { Account(provider: "fake", subject: $0, organization: nil, label: $0, accessToken: "", refreshToken: "", expiresAt: .distantFuture) }
        let accounts = try Accounts(storage: Storage(loadAccounts: { stored }, storeAccounts: { _ in }, config: { config }, storeConfig: { _ in }, loadMemory: { Memory() }, storeMemory: { _ in }))
        // A caller with no folder is doing the default profile's work.
        #expect(try await accounts.candidates(provider: "fake", pin: "w", folder: nil, conversation: nil).accounts.isEmpty)
        #expect(try await accounts.candidates(provider: "fake", pin: "mine", folder: nil, conversation: nil).accounts.map(\.label) == ["mine"])
    }

    @Test func aReadingIsALineOfHistoryOnlyWhenItSaysSomethingNew() async throws {
        let stored = [Account(provider: "fake", subject: "a", organization: nil, label: "a", accessToken: "", refreshToken: "", expiresAt: .distantFuture)]
        let lines = OSAllocatedUnfairLock(initialState: [Sample]())
        let accounts = try Accounts(storage: Storage(
            loadAccounts: { stored }, storeAccounts: { _ in }, config: { Config() }, storeConfig: { _ in }, loadMemory: { Memory() }, storeMemory: { _ in },
            appendSample: { sample in lines.withLock { $0.append(sample) } }
        ))
        let reset = Date().addingTimeInterval(86400)
        await accounts.answered("fake/a", reporting: [Window(name: "7d", used: 0.4, resetsAt: reset)])
        // The same reading again, its reset a second off as providers report it.
        await accounts.answered("fake/a", reporting: [Window(name: "7d", used: 0.4, resetsAt: reset.addingTimeInterval(1))])
        await accounts.answered("fake/a", reporting: [Window(name: "7d", used: 0.41, resetsAt: reset)])
        // The provider's two sources round a point apart; a real fall, as at a reset, is kept.
        await accounts.answered("fake/a", reporting: [Window(name: "7d", used: 0.4, resetsAt: reset)])
        await accounts.answered("fake/a", reporting: [Window(name: "7d", used: 0.1, resetsAt: reset)])
        #expect(lines.withLock { $0.map { $0.windows.map(\.used) } } == [[0.4], [0.41], [0.1]])
        #expect(lines.withLock { $0.first?.account } == "a")
    }

    @Test func aRemovedAccountIsForgottenAndOnlyDeleteRemoves() async throws {
        let stored = OSAllocatedUnfairLock(initialState: ["a", "b"].map { Account(provider: "fake", subject: $0, organization: nil, label: $0, accessToken: "", refreshToken: "", expiresAt: .distantFuture) })
        let storage = Storage(loadAccounts: { stored.withLock { $0 } }, storeAccounts: { next in stored.withLock { $0 = next } }, config: { Config() }, storeConfig: { _ in }, loadMemory: { Memory() }, storeMemory: { _ in })
        let relay = try Relay(providers: [Fake(upstream: URL(string: "http://127.0.0.1:1")!)], storage: storage, port: 47614)
        let server = try Server(port: 47614) { try await relay.handle($0, $1) }
        try await server.start()

        let address = URL(string: "http://127.0.0.1:47614/accounts/fake/a")!
        #expect(try await HTTPCall.send("GET", address).status == 405)
        #expect(try await HTTPCall.send("DELETE", address).status == 200)
        #expect(stored.withLock { $0.map(\.label) } == ["b"])
        #expect(try await relay.status().map(\.label) == ["b"])
        #expect(try await HTTPCall.send("DELETE", address).status == 404)
        withExtendedLifetime(server) {}
    }
}
