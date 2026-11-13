import Foundation
import Testing
@testable import SluiceCore
@testable import SluiceProviders

@Suite struct RouteTests {
    @Test func relayKeepsTheProvidersPathAndQueryUntouched() {
        #expect(Route(target: "/claude/v1/messages?beta=true") == .relay(provider: "claude", pin: nil, target: "/v1/messages?beta=true"))
    }

    @Test func pinNamesAnAccountAndIsStrippedFromThePath() {
        #expect(Route(target: "/claude/pin/a%40b.dev/v1/messages") == .relay(provider: "claude", pin: "a@b.dev", target: "/v1/messages"))
    }

    @Test func aPinWithNoNameIsNotARoute() {
        #expect(Route(target: "/claude/pin/") == nil)
    }

    @Test func callbackNeedsBothCodeAndState() {
        #expect(Route(target: "/callback?code=c&state=s") == .callback(code: "c", state: "s"))
        #expect(Route(target: "/callback?code=c") == nil)
    }
}

@Suite struct HeadTests {
    @Test func aChunkedRequestBodyIsRefused() {
        #expect(throws: HTTPError.lengthRequired) {
            try HTTPHead.parse(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked".utf8))
        }
    }

    @Test func headerNamesMatchInAnyCase() throws {
        let (request, length) = try HTTPHead.parse(Data("POST /x HTTP/1.1\r\ncontent-length: 5\r\nX-Y:  z ".utf8))
        #expect(length == 5)
        #expect(request.header("x-y") == "z")
    }
}

@Suite struct AccountSwapTests {
    let account = Account(provider: "claude", subject: "NEW", organization: nil, label: "a@b.dev", accessToken: "tok", refreshToken: "r", expiresAt: .distantFuture)

    func prepared(_ body: String) -> String {
        var request = HTTPRequest(method: "POST", target: "/v1/messages", headers: [("Authorization", "Bearer old")], body: Data(body.utf8))
        Claude().prepare(&request, for: account)
        #expect(request.header("Authorization") == "Bearer tok")
        return String(decoding: request.body, as: UTF8.self)
    }

    @Test func onlyTheMetadataAccountIsSwapped() {
        // The same marker inside a message is the user's text and must survive.
        let body = #"{"messages":[{"content":"account_uuid\":\"OLD\" and } ] tricks"}],"metadata":{"user_id":"{\"device_id\":\"d\",\"account_uuid\":\"OLD\",\"session_id\":\"s\"}"},"stream":true}"#
        let expected = #"{"messages":[{"content":"account_uuid\":\"OLD\" and } ] tricks"}],"metadata":{"user_id":"{\"device_id\":\"d\",\"account_uuid\":\"NEW\",\"session_id\":\"s\"}"},"stream":true}"#
        #expect(prepared(body) == expected)
    }

    @Test func aBodyWithoutMetadataIsLeftAlone() {
        let body = #"{"messages":[{"content":"account_uuid\":\"OLD\""}]}"#
        #expect(prepared(body) == body)
    }
}

@Suite struct ProfileTests {
    func config(_ json: String) throws -> Config { try JSONDecoder().decode(Config.self, from: Data(json.utf8)) }
    func account(_ label: String, at provider: String = "p") -> Account {
        Account(provider: provider, subject: label, organization: nil, label: label, accessToken: "", refreshToken: "", expiresAt: .distantFuture)
    }

    @Test func theDeepestFolderClaimWins() throws {
        let config = try config(#"{"profiles":{"a":{"folders":["~/work"]},"b":{"folders":["~/work/client/"]}}}"#)
        #expect(config.profile(for: "/home/me/work/client/repo", home: "/home/me") == "b")
        #expect(config.profile(for: "/home/me/work", home: "/home/me") == "a")
        // Sharing a prefix is not being inside.
        #expect(config.profile(for: "/home/me/workshop", home: "/home/me") == "default")
    }

    @Test func aFolderClaimBeatsAnOwnerClaim() throws {
        let config = try config(#"{"profiles":{"a":{"folders":["~/work"]},"b":{"owners":["Acme"]}}}"#)
        #expect(config.profile(for: "/home/me/work/app", home: "/home/me", owner: { _ in "acme" }) == "a")
        #expect(config.profile(for: "/home/me/else/app", home: "/home/me", owner: { _ in "acme" }) == "b")
        #expect(config.profile(for: "/home/me/else/app", home: "/home/me", owner: { _ in nil }) == "default")
    }

    @Test func aProfilesWorkNeverUsesAnotherProfilesAccounts() throws {
        let config = try config(#"{"profiles":{"work":{"main":"w","accounts":["w2"]}}}"#)
        let all = ["w", "w2", "mine"].map { account($0) }
        #expect(config.pool(all, for: "work").map(\.label) == ["w", "w2"])
        // An account no profile lists is the default's.
        #expect(config.pool(all, for: "default").map(\.label) == ["mine"])
    }

    @Test func aProviderAProfileHasNoAccountAtIsServedByTheDefault() throws {
        let config = try config(#"{"profiles":{"work":{"main":"w"}}}"#)
        #expect(config.pool([account("mine", at: "other")], for: "work").map(\.label) == ["mine"])
    }

    @Test func theOwnerIsReadFromEitherRemoteForm() {
        #expect(Repo.originOwner(in: "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = git@github.com:Acme/app.git\n") == "acme")
        #expect(Repo.originOwner(in: "[remote \"fork\"]\n\turl = https://h/x/y\n[remote \"origin\"]\n\turl = https://github.com/acme/app\n") == "acme")
        #expect(Repo.originOwner(in: "[core]\n") == nil)
    }
}

@Suite struct LocalCallerTests {
    func request(_ headers: [(String, String)]) -> HTTPRequest {
        HTTPRequest(method: "POST", target: "/claude/v1/messages", headers: headers.map { (name: $0.0, value: $0.1) }, body: Data())
    }

    @Test func aLocalProgramAndASignInNavigationPass() {
        #expect(request([("Host", "localhost:7483")]).isLocalCaller)
        #expect(request([("Host", "127.0.0.1:7483"), ("Sec-Fetch-Mode", "navigate"), ("Sec-Fetch-Site", "cross-site")]).isLocalCaller)
    }

    @Test func aWebPageIsRefused() {
        #expect(!request([("Host", "localhost:7483"), ("Origin", "https://evil.example")]).isLocalCaller)
        #expect(!request([("Host", "localhost:7483"), ("Sec-Fetch-Mode", "no-cors")]).isLocalCaller)
        // A DNS name rebound to this machine still names itself in Host.
        #expect(!request([("Host", "evil.example:7483")]).isLocalCaller)
        #expect(!request([]).isLocalCaller)
    }
}
