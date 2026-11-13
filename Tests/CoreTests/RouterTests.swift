import Foundation
import os
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

    @Test func theFoldersAClientWorkedInAreReadFromItsOwnRecord() throws {
        #expect(try Claude.folders(inState: Data(#"{"projects":{"/w/app":{"allowedTools":[]}},"numStartups":3}"#.utf8), path: "") == ["/w/app"])
        #expect(try Claude.folders(inState: Data(#"{"numStartups":3}"#.utf8), path: "") == [])
        // A table under a folder's own is not another folder, and neither is any other table.
        let settings = "model = \"x\"\n[projects.\"/w/my app\"]\ntrust_level = \"trusted\"\n[model_providers.sluice]\nname = \"s\"\n[projects.'/w/other']\n"
        #expect(Codex.folders(inSettings: settings) == ["/w/my app", "/w/other"])
    }

    @Test func whatAnAnswerCostIsReadFromItsStreamHoweverTheStreamIsCutUp() {
        let stream = [
            #"event: message_start"#,
            #"data: {"type":"message_start","message":{"model":"m-1","usage":{"input_tokens":3,"cache_creation_input_tokens":10,"cache_read_input_tokens":24000,"output_tokens":1}}}"#,
            "",
            // What an answer says is not what it cost.
            #"data: {"type":"content_block_delta","delta":{"text":"the word \"usage\": {\"output_tokens\": 9}"}}"#,
            "",
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}"#,
            "",
        ].joined(separator: "\n")
        var meter = Meter(count: Claude().count)
        let bytes = Array(stream.utf8)
        for start in stride(from: 0, to: bytes.count, by: 7) { meter.read(Data(bytes[start..<min(start + 7, bytes.count)])) }
        meter.finish()
        var cost = Spend()
        (cost.model, cost.input, cost.cacheRead, cost.cacheWrite, cost.output) = ("m-1", 3, 24000, 10, 42)
        #expect(meter.spend == cost)
    }

    @Test func anAnswerInOnePieceIsCountedAndCodexsCachedTokensAreNotCountedTwice() {
        var whole = Meter(count: Claude().count)
        whole.read(Data(#"{"model":"m-2","usage":{"input_tokens":5,"output_tokens":6}}"#.utf8))
        whole.finish()
        #expect(whole.spend.input == 5 && whole.spend.output == 6 && whole.spend.model == "m-2")

        var codex = Meter(count: Codex().count)
        codex.read(Data(#"data: {"type":"response.created","response":{"model":"g","usage":null}}"#.utf8 + [10]))
        codex.read(Data(#"data: {"type":"response.completed","response":{"model":"g","usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":60},"output_tokens":7}}}"#.utf8 + [10]))
        #expect(codex.spend.input == 40 && codex.spend.cacheRead == 60 && codex.spend.output == 7 && codex.spend.model == "g")
    }

    @Test func anAnswerCutShortIsToldForAsFarAsItGot() async throws {
        let told = OSAllocatedUnfairLock(initialState: [Spend]())
        let body = AsyncStream<Data> { stream in
            stream.yield(Data(#"{"model":"m","usage":{"input_tokens":8}}"#.utf8 + [10]))
            stream.yield(Data("more".utf8))
        }
        do {
            var reader = Metered(base: body, count: Claude().count) { spend in told.withLock { $0.append(spend) } }.makeAsyncIterator()
            _ = try await reader.next()
        }
        #expect(told.withLock { $0.map(\.input) } == [8])
    }

    @Test func aPoolLastsLongerForWhatComesBackAtAReset() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Half of one account is left, and it is whole again in ten hours; the other is untouched.
        let pool = [Member(weight: 1, used: 0.5, resetsAt: now + 10 * 3600), Member(weight: 1, used: 0, resetsAt: nil)]
        // At a twentieth of the pool an hour: the first is spent in 5h, is back at 10h, and all is spent at 25h, not 15h.
        #expect(Forecast.dry(pool, burn: 0.05, now: now) == now + 25 * 3600)
        #expect(Forecast.dry(pool, burn: 0.001, now: now) == nil)
        #expect(Forecast.dry([Member(weight: 1, used: 1, resetsAt: now + 3600)], burn: 0.05, now: now) == now)
    }

    @Test func howFastAPoolIsUsedCountsNewHighsAndNotTheRoundingBetween() {
        let start = Date(timeIntervalSince1970: 1_000_000), reset = start + 86400
        func sample(_ hours: Double, _ used: Double, _ reset: Date) -> Sample {
            Sample(at: start + hours * 3600, provider: "p", account: "a", windows: [Window(name: "5h", used: 0.9, resetsAt: start + 60), Window(name: "7d", used: used, resetsAt: reset)])
        }
        let samples = [sample(0, 0.40, reset), sample(1, 0.42, reset), sample(1.5, 0.41, reset), sample(2, 0.42, reset), sample(3, 0.03, reset + 7 * 86400)]
        // Two points, then three in a new window: five in four hours, on the half of the pool this account is.
        let burn = Forecast.burn([(samples, 1), ([], 1)], from: start, to: start + 4 * 3600)
        #expect(abs((burn ?? 0) - 0.05 / 2 / 4) < 1e-9)
        #expect(Forecast.burn([(samples, 1)], from: start, to: start + 600) == nil)
    }

    @Test func theTimeLeftIsReadInItsTwoLargestUnits() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func left(_ seconds: Double) -> String { Window(name: "7d", used: 0, resetsAt: now + seconds).leftText(now: now) }
        #expect(left(4 * 86400 + 20 * 3600 + 50 * 60) == "4d 20h")
        #expect(left(3 * 3600 + 5 * 60) == "3h 5m")
        #expect(left(86400 + 20) == "1d")
        #expect(left(12 * 60) == "12m")
        // A reset that has just passed is not time owed.
        #expect(left(-90) == "0m")
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
        #expect(Plan(name: "Ultra", multiple: 20, business: false, price: 200).tier == "20x")
        #expect(Plan(name: "Go", multiple: nil, business: false, price: 8).tier == "Go")
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
