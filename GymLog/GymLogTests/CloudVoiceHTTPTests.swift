import XCTest
@testable import GymLogKit

private final class VoiceHTTPStub: URLProtocol {
    static var responseBody = Data()
    static var statusCode = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class CloudVoiceHTTPTests: XCTestCase {
    private func invoke(status: Int = 200, finish: String = "stop", content: String) async throws -> CloudVoicePlan {
        VoiceHTTPStub.statusCode = status
        VoiceHTTPStub.responseBody = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": finish, "message": ["content": content]]]])
        let sessionConfig = URLSessionConfiguration.ephemeral; sessionConfig.protocolClasses = [VoiceHTTPStub.self]
        let session = URLSession(configuration: sessionConfig); defer { session.invalidateAndCancel() }
        var config = CloudVoiceConfiguration(); config.llmKey = "test-placeholder"; config.llmBaseURL = "https://example.invalid/v1"
        return try await CloudVoiceInterpreter(session: session).interpret(transcript: "開始", context: "{}", configuration: config)
    }
    func testCompleteJSONDecoded() async throws {
        let plan = try await invoke(content: #"{"version":1,"clarification":null,"operations":[{"kind":"startSession","evidence":"開始"}]}"#)
        XCTAssertEqual(plan.operations.first?.kind, .startSession)
    }
    func testTruncatedCompletionRejectedEvenWhenContentIsValidJSON() async {
        do { _ = try await invoke(finish: "length", content: #"{"version":1,"operations":[]}"#); XCTFail() }
        catch { XCTAssertTrue(error is CloudVoiceError) }
    }
    func testErrorBodyIsNeverDisplayed() async {
        do { _ = try await invoke(status: 503, content: "provider-private-details"); XCTFail() }
        catch { XCTAssertFalse(error.localizedDescription.contains("provider-private-details")); XCTAssertTrue(error.localizedDescription.contains("503")) }
    }
}
