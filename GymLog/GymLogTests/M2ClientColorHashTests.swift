import XCTest
@testable import GymLogKit

/// CONTRACT-UI.md §3.4: "每个学员一个稳定配色（由 Client.id 哈希决定...）".
/// The critical property under test is determinism -- unlike Swift's own
/// `Hasher`, which is randomly seeded per process, this must return the
/// exact same hue for the same id every time, including across "process
/// restarts" (simulated here by just calling it many times independently,
/// since a real restart isn't testable in-process).
final class M2ClientColorHashTests: XCTestCase {
    func testSameIDAlwaysProducesTheSameHue() {
        let hues = (0..<50).map { _ in ClientColorHash.hue(forID: "example-athlete-id") }
        XCTAssertTrue(hues.allSatisfy { $0 == hues[0] }, "hue must be fully deterministic for a fixed id")
    }

    func testDifferentIDsTypicallyProduceDifferentHues() {
        let ids = (0..<20).map { "cl-\($0)" }
        let hues = Set(ids.map { ClientColorHash.hue(forID: $0) })
        XCTAssertGreaterThan(hues.count, 15, "20 distinct ids should not collide heavily")
    }

    func testHueIsAlwaysInUnitRange() {
        for id in ["example-athlete-id", "", "a very long client id with spaces and 中文", "🏋️"] {
            let hue = ClientColorHash.hue(forID: id)
            XCTAssertGreaterThanOrEqual(hue, 0)
            XCTAssertLessThan(hue, 1)
        }
    }
}
