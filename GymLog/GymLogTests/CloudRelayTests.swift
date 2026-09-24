import XCTest
@testable import GymLogKit

final class CloudRelayTests: XCTestCase {
    func testSourceDistributionIncludesNoServiceOrProviderKeys() {
        let config = CloudVoiceConfiguration()
        XCTAssertFalse(config.hasASR); XCTAssertFalse(config.hasLLM)
        XCTAssertTrue(config.usesASRRelay); XCTAssertTrue(config.usesLLMRelay)
        XCTAssertTrue(config.asrToken.isEmpty); XCTAssertTrue(config.llmKey.isEmpty)
        XCTAssertEqual(URL(string: config.asrURL)?.host, URL(string: config.llmBaseURL)?.host)
    }
    func testGrantCarriesUniqueOperationAndNoProviderSecret() throws {
        let identity = "trial_" + String(repeating: "a", count: 64)
        let a = try CloudRelaySession.request(credential: identity)
        let b = try CloudRelaySession.request(credential: identity)
        XCTAssertNotEqual(a.value(forHTTPHeaderField: "X-Operation-ID"), b.value(forHTTPHeaderField: "X-Operation-ID"))
        XCTAssertEqual(a.value(forHTTPHeaderField: "Authorization"), "Bearer " + identity)
        XCTAssertNil(a.value(forHTTPHeaderField: "X-Api-Access-Key"))
        XCTAssertThrowsError(try CloudRelaySession.request(credential: "invalid"))
    }
    func testRelayErrorsDistinguishRateLimitBudgetAndReplay() throws {
        func message(_ body: String, status: Int = 429, retry: String? = nil) -> String? {
            let response = HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: status,
                httpVersion: nil, headerFields: retry.map { ["Retry-After": $0] })!
            return CloudRelayError.message(data: Data(body.utf8), response: response)
        }
        XCTAssertEqual(message(#"{"error":{"code":"ip_rate_limit"}}"#, retry: "60"),
            L("請求過於頻繁，請於 60 秒後重試。這不代表本月額度已用完。", "Too many requests. Retry in 60 seconds. Your monthly allowance may still be available."))
        let monthly = message(#"{"error":"monthly_limit"}"#)
        XCTAssertEqual(monthly, L("本月雲端額度已用完，請於下月重設後再試。", "Your monthly cloud allowance is exhausted. Try again after next month's reset."))
        XCTAssertNotEqual(message("{}"), monthly)
        XCTAssertEqual(message(#"{"error":"service_daily_budget_exhausted"}"#, status: 503),
            L("雲端服務今日總額度已用完，請於香港時間午夜重設後再試。", "The service's daily budget is exhausted. Try again after midnight Hong Kong time."))
        XCTAssertEqual(message(#"{"error":"operation_already_used_or_expired"}"#, status: 409),
            L("這次指令的授權已使用或過期，請重新提交指令。", "This operation's authorization was used or expired. Submit a new request."))
        XCTAssertNil(message(#"{"error":{"message":"private upstream detail"}}"#, status: 502))
    }

    private func stream(finish: String = "stop", done: Bool = true) throws -> Data {
        let content = #"{"version":1,"operations":[{"kind":"startSession","evidence":"開始"}]}"#
        func event(_ fragment: String, reason: String? = nil) throws -> String {
            var choice: [String: Any] = ["delta": ["content": fragment]]
            if let reason { choice["finish_reason"] = reason }
            let data = try JSONSerialization.data(withJSONObject: ["choices": [choice]])
            return "data: " + String(data: data, encoding: .utf8)!
        }
        var events = [try event(String(content.prefix(20))), try event(String(content.dropFirst(20)), reason: finish)]
        if done { events.append("data: [DONE]") }
        return Data((events.joined(separator: "\r\n\r\n") + "\r\n\r\n").utf8)
    }
    func testSSEFragmentsBecomeSingleValidatedPlan() throws {
        XCTAssertEqual(try CloudVoiceInterpreter.decodeEventStream(stream()).operations.first?.kind, .startSession)
    }
    func testTruncatedAndUnfinishedStreamsNeverExecute() throws {
        XCTAssertThrowsError(try CloudVoiceInterpreter.decodeEventStream(stream(done: false)))
        XCTAssertThrowsError(try CloudVoiceInterpreter.decodeEventStream(stream(finish: "length")))
        XCTAssertThrowsError(try CloudVoiceInterpreter.decodeEventStream(Data("data: {\"error\":\"private\"}\n\ndata: [DONE]\n\n".utf8)))
    }
}
