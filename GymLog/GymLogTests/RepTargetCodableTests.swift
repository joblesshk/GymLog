import XCTest
@testable import GymLogKit

/// Round-trip encode/decode for every one of RepTarget's 7 branches
/// (CONTRACT.md §7.7-7.8).
final class RepTargetCodableTests: XCTestCase {
    private func roundTrip(_ value: RepTarget, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(RepTarget.self, from: data)
        XCTAssertEqual(decoded, value, file: file, line: line)
    }

    func testRange() throws {
        try roundTrip(.range(low: 8, high: 12, raw: "8-12"))
        try roundTrip(.range(low: 3, high: 5, raw: "3-5"))
    }

    func testFixed() throws {
        try roundTrip(.fixed(value: 10, raw: "10"))
        try roundTrip(.fixed(value: 15, raw: "15"))
    }

    func testTime() throws {
        try roundTrip(.time(seconds: 30, raw: "30s"))
        try roundTrip(.time(seconds: 62, raw: "1:02"))
        // CONTRACT.md §8.3 exact worked example: Rowing 500m corruption.
        try roundTrip(.time(seconds: 143, raw: "2:23"))
    }

    func testDistance() throws {
        try roundTrip(.distance(meters: 500, raw: "500m"))
        try roundTrip(.distance(meters: 200, raw: "200m"))
    }

    func testRounds() throws {
        try roundTrip(.rounds(count: 3, raw: "3round"))
        try roundTrip(.rounds(count: 5, raw: "5x3"))
    }

    func testUnknown() throws {
        try roundTrip(.unknown(raw: "/"))
        try roundTrip(.unknown(raw: ""))
    }

    // CONTRACT.md §7.8: per-side reps for unilateral work, e.g.
    // `Leg extension SL`, `Bulgarian split squat`, `Machine hip thrust SL`.
    func testPerSide() throws {
        try roundTrip(.perSide(left: 10, right: 10, raw: "10,10"))
        try roundTrip(.perSide(left: 8, right: 10, raw: "8,10"))
    }

    // MARK: - Wire shape (matches CONTRACT.md §7.7-7.8 exactly)

    func testPerSideWireShapeMatchesContract() throws {
        let json = #"{"kind":"perSide","left":10,"right":10,"raw":"10,10"}"#
        let decoded = try JSONDecoder().decode(RepTarget.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, .perSide(left: 10, right: 10, raw: "10,10"))
    }

    // MARK: - Display formatting spot checks (per task brief examples)

    func testDisplayText() {
        XCTAssertEqual(RepTarget.range(low: 8, high: 12, raw: "8-12").displayText, "8-12 次")
        XCTAssertEqual(RepTarget.time(seconds: 143, raw: "2:23").displayText, "2:23")
        XCTAssertEqual(RepTarget.time(seconds: 62, raw: "1:02").displayText, "1:02")
        XCTAssertEqual(RepTarget.fixed(value: 10, raw: "10").displayText, "10 次")
        XCTAssertEqual(RepTarget.distance(meters: 500, raw: "500m").displayText, "500 米")
        XCTAssertEqual(RepTarget.rounds(count: 3, raw: "3round").displayText, "3 輪")
        XCTAssertEqual(RepTarget.perSide(left: 10, right: 10, raw: "10,10").displayText, "左右各10次")
        XCTAssertEqual(RepTarget.perSide(left: 8, right: 10, raw: "8,10").displayText, "左8 右10次")
    }
}
