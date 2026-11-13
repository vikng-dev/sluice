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

    @Test func theModelARequestAsksForIsItsOwnAndNotOneNamedInsideIt() {
        // A tool call in the conversation may carry a model of its own.
        let body = #"{"messages":[{"content":[{"type":"tool_use","input":{"model":"opus"}}]}],"model":"claude-fable-5-2","stream":true}"#
        let request = HTTPRequest(method: "POST", target: "/v1/messages", headers: [], body: Data(body.utf8))
        #expect(Claude().model(of: request) == "claude-fable-5-2")
        #expect(Claude().model(of: HTTPRequest(method: "GET", target: "/v1/models", headers: [], body: Data())) == nil)
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
        let config = try config(#"{"profiles":{"work":{"accounts":["w","w2"]}}}"#)
        let all = ["w", "w2", "mine"].map { account($0) }
        #expect(config.pool(all, for: "work").map(\.label) == ["w", "w2"])
        // An account no profile lists is the default's.
        #expect(config.pool(all, for: "default").map(\.label) == ["mine"])
    }

    @Test func aProfileWithNoAccountAtAProviderIsNotServedByAnothers() throws {
        let config = try config(#"{"profiles":{"work":{"accounts":["w"]}}}"#)
        #expect(config.pool([account("mine", at: "other")], for: "work").isEmpty)
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

@Suite struct ProgramWatchTests {
    let start = Date(timeIntervalSince1970: 0)

    @Test func anUpgradeThatMovesTheFileOutThenInIsARestartNotAnUninstall() {
        var watch = ProgramWatch(launched: 1)
        #expect(watch.verdict(found: 1, now: start) == .stay)
        #expect(watch.verdict(found: nil, now: start + 5) == .stay)
        #expect(watch.verdict(found: 2, now: start + 10) == .restart)
    }

    @Test func aRolledBackUpgradePutsTheSameFileBackAndChangesNothing() {
        var watch = ProgramWatch(launched: 1)
        #expect(watch.verdict(found: nil, now: start) == .stay)
        #expect(watch.verdict(found: 1, now: start + 5) == .stay)
        // The earlier absence does not count toward a later one.
        #expect(watch.verdict(found: nil, now: start + ProgramWatch.patience + 1) == .stay)
    }

    @Test func aFileGoneForTheWholePatienceIsAnUninstall() {
        var watch = ProgramWatch(launched: 1)
        #expect(watch.verdict(found: nil, now: start) == .stay)
        #expect(watch.verdict(found: nil, now: start + ProgramWatch.patience) == .leave)
    }
}

@Suite struct ManageTests {
    func config(_ json: String) throws -> Config { try JSONDecoder().decode(Config.self, from: Data(json.utf8)) }

    @Test func aNewProfileIsNamedFromWhatItIsShownAsInCharactersAFolderCanHave() throws {
        var config = Config()
        #expect(try config.add(profileShownAs: " Side Projects ") == "side-projects")
        #expect(config.shown("side-projects") == "Side Projects")
        // A name with no plain characters still gets one, and so does the next.
        let first = try config.add(profileShownAs: "עבודה"), second = try config.add(profileShownAs: "בית")
        #expect(first != second && config.shown(first) == "עבודה" && config.shown(second) == "בית")
        // What is typed as a plain name needs no label.
        #expect(try config.add(profileShownAs: "work") == "work")
        #expect(config.profiles["work"]?.label == nil)
        #expect(throws: ConfigError.self) { try config.add(profileShownAs: "Work") }
    }

    @Test func aMovedAccountLeavesItsProfileAndJoinsTheOther() throws {
        var config = try config(#"{"profiles":{"a":{"accounts":["x","y"]},"b":{}}}"#)
        try config.move(account: "y", to: "b")
        #expect(config.profiles["a"]?.accounts == ["x"] && config.profiles["b"]?.accounts == ["y"])
        // The default profile's accounts are listed nowhere.
        try config.move(account: "y", to: "default")
        #expect(config.profile(ofAccount: "y") == "default" && config.profiles["b"]?.accounts == [])
        #expect(throws: ConfigError.self) { try config.move(account: "x", to: "nowhere") }
        #expect(config.profile(ofAccount: "x") == "a")
    }

    @Test func noTwoProfilesAreShownAsTheSameThing() throws {
        var config = try config(#"{"profiles":{"work":{},"side":{}}}"#)
        try config.label("default", as: " Me ")
        #expect(config.shown("default") == "Me" && config.names.first == "default")
        #expect(throws: ConfigError.self) { try config.label("work", as: "me") }
        #expect(throws: ConfigError.self) { try config.label("work", as: "Side") }
        try config.label("default", as: "")
        #expect(config.shown("default") == "default")
    }

    @Test func aFolderBelongsToOneProfileHoweverItIsWritten() throws {
        var config = try config(#"{"profiles":{"a":{"folders":["~/work/"]},"b":{}}}"#)
        #expect(throws: ConfigError.self) { try config.claim(folder: "/home/me/work", for: "b", home: "/home/me") }
        try config.claim(folder: "/home/me/play/../other", for: "b", home: "/home/me")
        #expect(config.profiles["b"]?.folders == ["~/other"])
        try config.unclaim(folder: "/home/me/work", from: "a", home: "/home/me")
        #expect(config.profiles["a"]?.folders == [])
        #expect(throws: ConfigError.self) { try config.claim(owner: "Acme", for: "missing") }
    }

    /// Every change reads the file, edits it and writes it, so a key the reader dropped would be wiped at the next change.
    @Test func whatIsReadIsWrittenBackKeyForKey() throws {
        let written = #"{"autoResets":true,"profiles":{"a":{"accounts":["x"],"color":"teal","folders":["~/w"],"label":"A side","owners":["Acme"],"starred":["p"]}}}"#
        var config = try config(written)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        #expect(String(decoding: try encoder.encode(config), as: UTF8.self) == written)
        try config.add(profile: "b")
        #expect(throws: ConfigError.self) { try config.add(profile: "b") }
        #expect(throws: ConfigError.self) { try config.add(profile: "Not Plain") }
        #expect(throws: ConfigError.self) { try config.remove(profile: "default") }
    }

    @Test func anAccountsAddressIsItsProviderAndName() {
        #expect(Route(target: "/accounts/claude/a%40b.c") == .account(provider: "claude", label: "a@b.c"))
        #expect(Route(target: "/accounts/claude") == nil)
    }
}
