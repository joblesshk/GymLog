import XCTest
import SwiftData
@testable import GymLogKit

/// CONTRACT.md §11.4: "遇到本契约未定义的枚举字符串，降级为对应的兜底分支... 记录
/// 日志，不得崩溃。" This is the requirement most likely to be true only in
/// spirit (a `default:` case someone believes handles it) rather than
/// actually verified. Every test here feeds a string the contract does NOT
/// define through the real `Decodable` initializer and asserts (a) no throw,
/// and (b) the decoded value is the documented fallback case -- not just
/// "didn't crash".
final class UnknownEnumFallbackTests: XCTestCase {

    private func decodeQuoted<T: Decodable>(_ type: T.Type, _ raw: String) throws -> T {
        let json = "\"\(raw)\""
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func testMovementPatternUnknownStringFallsBackToUnknown() throws {
        let value = try decodeQuoted(MovementPattern.self, "explode-and-fly")
        XCTAssertEqual(value, .unknown)
    }

    func testEquipmentUnknownStringFallsBackToOther() throws {
        let value = try decodeQuoted(Equipment.self, "jetpack")
        XCTAssertEqual(value, .other)
    }

    func testLoadDirectionUnknownStringFallsBackToUnknownWithoutCrashing() throws {
        let value = try decodeQuoted(LoadDirection.self, "sidewaysIsStronger")
        XCTAssertEqual(value, .unknown)
        // Business-critical: an unrecognized direction must NOT silently
        // resolve to .lowerIsStronger (that would invert a chart on bad
        // data). It must be its own trackable fallback.
        XCTAssertFalse(value.isInverted)
    }

    func testDateOriginUnknownStringFallsBackToUnknown() throws {
        let value = try decodeQuoted(DateOrigin.self, "guessedFromContext")
        XCTAssertEqual(value, .unknown)
    }

    func testBlockTypeUnknownStringFallsBackToUnknown() throws {
        let value = try decodeQuoted(BlockType.self, "mystery")
        XCTAssertEqual(value, .unknown)
    }

    func testLoadValueUnknownKindFallsBackToUnknownCase() throws {
        let json = #"{"kind":"antigravity","raw":"???"}"#
        let value = try JSONDecoder().decode(LoadValue.self, from: Data(json.utf8))
        if case .unknown(let raw) = value {
            XCTAssertEqual(raw, "???")
        } else {
            XCTFail("Expected .unknown fallback, got \(value)")
        }
    }

    func testLoadValueMalformedFieldsFallBackInsteadOfThrowing() throws {
        // kind "absolute" but kg is a string, not a number -- must not throw.
        let json = #"{"kind":"absolute","kg":"not-a-number","raw":"35"}"#
        let value = try JSONDecoder().decode(LoadValue.self, from: Data(json.utf8))
        if case .unknown(let raw) = value {
            XCTAssertEqual(raw, "35")
        } else {
            XCTFail("Expected fallback to .unknown when kg is malformed, got \(value)")
        }
    }

    func testRepTargetPerSideMalformedFieldsFallBackInsteadOfThrowing() throws {
        // kind "perSide" but "right" is missing entirely -- must not throw.
        let json = #"{"kind":"perSide","left":10,"raw":"10,10"}"#
        let value = try JSONDecoder().decode(RepTarget.self, from: Data(json.utf8))
        if case .unknown(let raw) = value {
            XCTAssertEqual(raw, "10,10")
        } else {
            XCTFail("Expected fallback to .unknown when right is missing, got \(value)")
        }
    }

    func testRepTargetUnknownKindFallsBackToUnknownCase() throws {
        let json = #"{"kind":"parsecs","raw":"???"}"#
        let value = try JSONDecoder().decode(RepTarget.self, from: Data(json.utf8))
        if case .unknown(let raw) = value {
            XCTAssertEqual(raw, "???")
        } else {
            XCTFail("Expected .unknown fallback, got \(value)")
        }
    }

    /// End-to-end: an entire seed file whose exercises/sessions use
    /// unrecognized enum strings throughout must still import successfully
    /// -- degrade, don't crash, don't abort the whole import over one bad
    /// classification string.
    func testFullFixtureImportsDespiteUnknownEnumStringsInside() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let data = try TestSupport.loadFixtureData()
        let result = try SeedImporter.importSeed(data: data, into: context)
        XCTAssertGreaterThan(result.exerciseCount, 0)
        // The fixture deliberately contains an unrecognized movementPattern
        // ("explode"), equipment ("jetpack"), dateOrigin
        // ("guessedFromContext"), and blockType ("mystery") -- if fallback
        // handling were broken, decode would have thrown and this whole
        // test would already have failed above.
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        let mystery = exercises.first { $0.id == "ex-0011" }
        XCTAssertEqual(mystery?.movementPattern, .unknown)
        XCTAssertEqual(mystery?.equipment, .other)
    }
}
