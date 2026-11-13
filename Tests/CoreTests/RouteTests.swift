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
