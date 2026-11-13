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

    func order(_ router: Router = Router(), pin: String? = nil, pinOnly: Set<String> = [], conversation: String? = nil, usage: [String: [Window]]) -> [String] {
        router.order([a, b, c], pin: pin, pinOnly: pinOnly, conversation: conversation, usage: usage, now: now).map(\.label)
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

    @Test func aPinOnlyAccountIsOutsideThePoolButReachableByPin() {
        #expect(order(pinOnly: ["c"], usage: [c.id: week(0.2, resetsIn: 20)]) == ["a", "b"])
        #expect(order(pin: "c", pinOnly: ["c"], usage: [c.id: week(1, resetsIn: 20)]) == ["c"])
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
