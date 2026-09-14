import XCTest
@testable import GymLogKit

/// Round-trip encode/decode for every one of LoadValue's 9 branches
/// (CONTRACT.md §7.6), verifying the wire format survives a full
/// encode -> decode cycle intact.
final class LoadValueCodableTests: XCTestCase {
    private func roundTrip(_ value: LoadValue, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(LoadValue.self, from: data)
        XCTAssertEqual(decoded, value, file: file, line: line)
    }

    func testAbsolute() throws {
        try roundTrip(.absolute(kg: 35, raw: "35"))
        try roundTrip(.absolute(kg: 12.5, raw: "12.5"))
    }

    func testPerSide() throws {
        try roundTrip(.perSide(kg: 6, raw: "6each"))
        try roundTrip(.perSide(kg: 12, raw: "Single 12"))
    }

    func testBodyweight() throws {
        try roundTrip(.bodyweight(raw: "bw"))
        try roundTrip(.bodyweight(raw: "Bw"))
    }

    func testAssisted() throws {
        try roundTrip(.assisted(kg: 30, raw: "30"))
    }

    func testBand() throws {
        try roundTrip(.band(color: "purple", count: 1, raw: "Purple"))
        try roundTrip(.band(color: "blue", count: 2, raw: "2blue"))
    }

    func testMachineStack() throws {
        try roundTrip(.machineStack(level: "Rack 12", raw: "Rack 12"))
        try roundTrip(.machineStack(level: "Machine", raw: "Machine"))
    }

    func testPinLoad() throws {
        try roundTrip(.pinLoad(desc: "1red1green", raw: "1red1green"))
    }

    func testSled() throws {
        try roundTrip(.sled(kg: 40, raw: "40"))
    }

    func testUnknown() throws {
        try roundTrip(.unknown(raw: "/"))
        try roundTrip(.unknown(raw: ""))
    }

    // MARK: - Wire shape (matches CONTRACT.md §7.6 exactly)

    func testWireShapeMatchesContract() throws {
        let json = #"{"kind":"absolute","kg":35,"raw":"35"}"#
        let decoded = try JSONDecoder().decode(LoadValue.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, .absolute(kg: 35, raw: "35"))
    }

    // MARK: - Display formatting spot checks (per task brief examples)

    // Traditional Chinese, not Simplified: `displayText` now branches on
    // `LanguageContext.current`, which defaults to `.zhHant` when no
    // `appLanguage` preference is set (as in this test process).
    func testDisplayText() {
        // CONTRACT-UI.md §3.3 (2026-08 revision): assisted load displays as
        // a negative number so it can't be mistaken for weight lifted, even
        // though the underlying stored `kg` and PR/trend direction are
        // unchanged (still `LoadDirection.lowerIsStronger`, positive kg).
        XCTAssertEqual(LoadValue.assisted(kg: 30, raw: "30").displayText, "輔助 -30kg")
        XCTAssertEqual(LoadValue.bodyweight(raw: "bw").displayText, "自重")
        XCTAssertEqual(LoadValue.perSide(kg: 6, raw: "6each").displayText, "單側 6kg")
    }
}
