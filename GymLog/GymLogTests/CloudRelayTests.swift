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
