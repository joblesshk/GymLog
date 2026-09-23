import XCTest
import CryptoKit
@testable import GymLogKit

/// The relay only serves requests whose system prompt hash is listed in
/// `backend/worker-relay/wrangler.jsonc` (`ALLOWED_SYSTEM_PROMPT_SHA256`).
/// A prompt edit without updating that list would make every cloud request
/// fail with 400 -- this test makes the two change together.
final class CloudPromptPinTests: XCTestCase {
    private func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func testSystemPromptsMatchRelayAllowlist() {
        let message = "Prompt changed: update ALLOWED_SYSTEM_PROMPT_SHA256 in backend/worker-relay/wrangler.jsonc and this constant."
        XCTAssertEqual(sha256(CloudVoiceInterpreter.prompt), "37d23de46ab2cf848d67f87a83a7a93ffa3f489ec99ebecec1497805760170c8", message)
        XCTAssertEqual(sha256(TrainingReviewService.rules), "561358993c85458a366fdf2251df9733bf2f7da180f8ad6f5e17e14ca5214fea", message)
    }
}
