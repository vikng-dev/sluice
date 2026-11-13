import Foundation
import Testing
@testable import SluiceCore
@testable import SluiceProviders

@Suite struct RouterTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let a = account("a"), b = account("b"), c = account("c")

    static func account(_ label: String) -> Account {
        Account(provider: "p", subject: label, organization: nil, label: label, accessToken: "", refreshToken: "", expiresAt: .distantFuture)
    }

    func week(_ used: Double, resetsIn hours: Double) -> [Window] {
        [Window(name: "week", used: used, resetsAt: now.addingTimeInterval(hours * 3600))]
    }

    func order(_ router: Router = Router(), conversation: String? = nil, usage: [String: [Window]]) -> [String] {
        router.order([a, b, c], conversation: conversation, usage: usage, now: now).map(\.label)
    }

    @Test func theAccountResettingSoonestGoesFirstAndUntouchedOnesLast() {
        #expect(order(usage: [b.id: week(0.5, resetsIn: 90), c.id: week(0.2, resetsIn: 20)]) == ["c", "b", "a"])
    }

    @Test func aWarmConversationStaysWhereItsCacheIs() {
        var router = Router()
        router.served("talk", by: b.id, cacheLifetime: 3600, now: now)
        let usage = [b.id: week(0.5, resetsIn: 90), c.id: week(0.2, resetsIn: 20)]
        #expect(order(router, conversation: "talk", usage: usage).first == "b")
        #expect(order(router, conversation: "other", usage: usage).first == "c")
    }

    @Test func aColdConversationIsPlacedAfresh() {
        var router = Router()
        router.served("talk", by: b.id, cacheLifetime: 300, now: now.addingTimeInterval(-301))
        #expect(order(router, conversation: "talk", usage: [b.id: week(0.5, resetsIn: 90), c.id: week(0.2, resetsIn: 20)]).first == "c")
    }

    @Test func aSpentAccountLosesEvenItsWarmConversations() {
        var router = Router()
        router.served("talk", by: c.id, cacheLifetime: 3600, now: now)
        #expect(order(router, conversation: "talk", usage: [b.id: week(0.5, resetsIn: 90), c.id: week(1, resetsIn: 20)]) == ["b", "a"])
    }

    @Test func aWindowPastItsResetNoLongerCounts() {
        #expect(order(usage: [c.id: week(1, resetsIn: -1)]) == ["a", "b", "c"])
    }


    @Test func withThePoolSpentTheAccountBackSoonestAnswers() {
        #expect(order(usage: [a.id: week(1, resetsIn: 50), b.id: week(1, resetsIn: 5), c.id: week(1, resetsIn: 30)]) == ["b"])
    }
}

@Suite struct ClaudeReadingTests {
    func reading(_ status: Int, _ headers: [String: String]) -> Reading {
        Claude().reading(status: status, headers: Dictionary(uniqueKeysWithValues: headers.map { ("anthropic-ratelimit-unified-" + $0, $1) }))
    }

    @Test func aRejectedWindowRefusesAndReadsAsSpent() {
        let result = reading(429, ["5h-status": "rejected", "5h-reset": "2000", "5h-utilization": "0.97", "7d-status": "allowed", "7d-reset": "9000", "7d-utilization": "0.4"])
        #expect(result.refused)
        #expect(result.windows == [Window(name: "5h", used: 1, resetsAt: Date(timeIntervalSince1970: 2000)), Window(name: "7d", used: 0.4, resetsAt: Date(timeIntervalSince1970: 9000))])
    }

    @Test func aRateLimitWithNoSpentWindowIsNotARefusal() {
        #expect(!reading(429, ["5h-status": "allowed", "5h-reset": "2000", "5h-utilization": "0.3"]).refused)
    }

    @Test func aSpentPerModelWindowRefusesWithoutClosingTheAccount() {
        let result = reading(429, ["7d_oi-status": "rejected", "7d-status": "allowed", "7d-reset": "9000", "7d-utilization": "0.4"])
        #expect(result.refused)
        #expect(result.windows.allSatisfy { $0.used < 1 })
    }

    @Test func aWindowTheResponseOmitsIsNotReported() {
        #expect(reading(200, ["7d-reset": "9000", "7d-utilization": "0"]).windows.map(\.name) == ["7d"])
    }
}

@Suite struct CodexReadingTests {
    @Test func windowsAreNamedByTheirLengthAndAnUnusedSlotIsSkipped() {
        let reading = Codex().reading(status: 200, headers: [
            "x-codex-primary-used-percent": "42", "x-codex-primary-window-minutes": "10080", "x-codex-primary-reset-at": "9000",
            "x-codex-secondary-used-percent": "0", "x-codex-secondary-window-minutes": "0", "x-codex-secondary-reset-at": "",
        ])
        #expect(reading == Reading(windows: [Window(name: "7d", used: 0.42, resetsAt: Date(timeIntervalSince1970: 9000))], refused: false))
    }
}

@Suite struct UsageAnswerTests {
    @Test func claudeWindowsWithoutAResetAreLeftOut() throws {
        let body = #"{"five_hour":{"utilization":0.0,"resets_at":null},"seven_day":{"utilization":49.0,"resets_at":"2026-11-18T09:00:00.063930+00:00"},"seven_day_opus":null}"#
        let windows = try Claude.windows(inUsage: Data(body.utf8))
        #expect(windows.map(\.name) == ["7d"] && windows[0].used == 0.49)
        #expect(Int(windows[0].resetsAt.timeIntervalSince1970) == 1_794_992_400)
        // A plan with no five-hour window sends null for it.
        #expect(try Claude.windows(inUsage: Data(#"{"five_hour":null,"seven_day":null}"#.utf8)).isEmpty)
    }

    @Test func claudePlanIsReadFromTheOrganizationAndItsTier() {
        func plan(_ organization: String) -> Plan? { Claude.plan(inProfile: Data(#"{"organization":\#(organization)}"#.utf8)) }
        #expect(plan(#"{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_20x","plan_display_name":"Ultra"}"#)
            == Plan(name: "Ultra", multiple: 20, business: false, price: 200))
        // A Team seat is on a person's tier, and is still a seat.
        #expect(plan(#"{"organization_type":"claude_team","rate_limit_tier":"default_claude_max_5x","seat_tier":"team_tier_1"}"#)
            == Plan(name: "Team", multiple: 5, business: true, price: 125))
        #expect(plan(#"{"organization_type":"claude_enterprise","rate_limit_tier":null}"#) == Plan(name: "Enterprise", multiple: nil, business: true, price: nil))
        #expect(Claude.plan(inProfile: Data(#"{"account":{}}"#.utf8)) == nil)
    }

    @Test func claudeCodesOwnSignInIsReadFromItsStateAndASignedOutOneHasNone() throws {
        #expect(try Claude.account(inState: Data(#"{"oauthAccount":{"emailAddress":"me@home.example"},"numStartups":3}"#.utf8), path: "") == "me@home.example")
        #expect(try Claude.account(inState: Data(#"{"numStartups":3}"#.utf8), path: "") == nil)
        // A file cut short is not taken for a signed-out client.
        #expect(throws: UserFileError.self) { try Claude.account(inState: Data(#"{"oauthAccount":{"#.utf8), path: "") }
    }

    @Test func codexsOwnSignInIsTheEmailInItsTokenAndAnAPIKeyIsNobody() throws {
        let claims = Data(#"{"email":"me@home.example"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        #expect(try Codex.account(inSignIn: Data(#"{"auth_mode":"chatgpt","tokens":{"id_token":"h.\#(claims).s"}}"#.utf8), path: "") == "me@home.example")
        #expect(try Codex.account(inSignIn: Data(#"{"OPENAI_API_KEY":"k","tokens":null}"#.utf8), path: "") == nil)
    }

    @Test func codexWindowsAreNamedByTheirLength() throws {
        let body = #"{"plan_type":"prolite","rate_limit":{"primary_window":{"used_percent":3,"limit_window_seconds":604800,"reset_at":1795144120},"secondary_window":null}}"#
        let usage = try Codex.usage(in: Data(body.utf8))
        #expect(usage.windows == [Window(name: "7d", used: 0.03, resetsAt: Date(timeIntervalSince1970: 1_795_144_120))])
        #expect(usage.plan?.multiple == 5)
        // A plan that is not listed keeps the provider's word.
        #expect(try Codex.usage(in: Data(#"{"plan_type":"self_serve_business","rate_limit":{}}"#.utf8)).plan?.name == "Self Serve Business")
        #expect(throws: ProviderError.self) { try Codex.usage(in: Data("{}".utf8)) }
    }

    @Test func aTierShowsTheMultipleOrElseTheName() {
        #expect(Plan(name: "Ultra", multiple: 20, business: false, price: 200).tier == "20x $200")
        #expect(Plan(name: "Go", multiple: nil, business: false, price: 8).tier == "Go $8")
        #expect(Plan(name: "Enterprise", multiple: nil, business: true, price: nil).tier == "Enterprise")
    }
}

@Suite struct UserFileTests {
    @Test func codexConfigGainsSluiceAndGivesItBackUnchanged() throws {
        let own = "model = \"x\"\n\n[projects.\"/a\"]\ntrust_level = \"trusted\"\n"
        let routed = try Codex.pointed(own, at: "A", path: "")
        // The choice is a top-level key: after a table header it would belong to that table.
        #expect(routed.hasPrefix(Codex.choice + "\n") && routed.hasSuffix(Codex.entry("A").joined(separator: "\n") + "\n"))
        #expect(try Codex.pointed(routed, at: "B", path: "") == Codex.pointed(own, at: "B", path: ""))
        #expect(try Codex.pointed(routed, at: nil, path: "") == own)
    }

    @Test func codexConfigWithItsOwnProviderIsLeftAlone() {
        #expect(throws: UserFileError.self) { try Codex.pointed("model_provider = \"other\"\n", at: "A", path: "") }
    }

    @Test func claudeSettingsKeepEverythingElse() throws {
        let own = Data(#"{"env":{"KEEP":"1"},"model":"x"}"#.utf8)
        let routed = try Claude.pointed(own, at: "A", path: "")
        #expect(try JSONSerialization.jsonObject(with: routed) as? NSDictionary == ["env": ["KEEP": "1", "ANTHROPIC_BASE_URL": "A"], "model": "x"])
        #expect(try JSONSerialization.jsonObject(with: Claude.pointed(routed, at: nil, path: "")) as? NSDictionary == ["env": ["KEEP": "1"], "model": "x"])
        #expect(throws: UserFileError.self) { try Claude.pointed(Data("[]".utf8), at: "A", path: "") }
    }
}

@Suite struct StandInTests {
    @Test func theRealClientIsTheOneAfterTheStandInOnPath() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sluice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["wrapper", "real"] {
            try FileManager.default.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: root.appending(path: "\(folder)/tool").path, contents: nil, attributes: [.posixPermissions: 0o755])
        }
        let own = StandIns.folder.path, wrapper = root.appending(path: "wrapper").path, real = root.appending(path: "real").path
        // A wrapper ahead of the stand-in handed on to it: running the wrapper again would loop.
        #expect(StandIns.real("tool", path: "\(wrapper):\(own):\(real)") == real + "/tool")
        #expect(StandIns.real("tool", path: "\(real)") == real + "/tool")
        #expect(StandIns.real("tool", path: "\(wrapper):\(own)") == nil)
    }
}
