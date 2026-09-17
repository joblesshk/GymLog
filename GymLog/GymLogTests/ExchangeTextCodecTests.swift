import XCTest
import SwiftData
@testable import GymLogKit

@MainActor
final class ExchangeTextCodecTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try TestSupport.makeInMemoryContainer()
        context = ModelContext(container)
    }
    private func package(kind: ExchangePayloadKind = .plan) -> ExchangePackage {
        let ref = ExchangeClientRef(remoteClientID: "remote", displayName: "Ada")
        let set = ExchangeSetDTO(setIndex: 0, load: .absolute(kg: 40, raw: "40"), target: .fixed(value: 8, raw: "8"), actual: kind == .results ? .fixed(value: 7, raw: "7") : nil)
        let entry = ExchangeEntryDTO(order: 0, exerciseRef: ExchangeExerciseRef(exerciseID: "ex", canonicalName: "Bench Press", nameZh: "", recordingMetric: .reps, equipment: .barbell), plannedSets: 1, sets: [set])
        let block = ExchangeBlockDTO(order: 0, blockType: .single, restSeconds: nil, sectionKind: .strength, entries: [entry], wodPayloadRawJSON: nil)
        let session = ExchangeSessionDTO(recordID: "record", sourcePlanID: nil, trainingLocalDate: "2026-09-17", weekNumber: 3, plannedDurationMinutes: nil, blocks: [block])
        return ExchangePackage(packageID: "package", createdAt: Date(timeIntervalSince1970: 1), originInstallationID: "origin", payloadKind: kind, client: ref, sessions: [session], exercises: [], contentDigestSHA256: ExchangeDigest.compute(payloadKind: kind, client: ref, sessions: [session], exercises: []))
    }

    func testReadableTextRoundTripsPlanAndResults() throws {
        for kind in [ExchangePayloadKind.plan, .results] {
            let source = package(kind: kind)
            let text = try ExchangeTextCodec.encode(source)
            let decoded = try ExchangeTextCodec.decode(text.replacingOccurrences(of: "\n", with: "\r\n"))
            XCTAssertEqual(decoded.sessions, source.sessions)
            XCTAssertTrue(text.contains("Bench Press"))
        }
    }

    func testJSONWithChatPrefixAndSuffixRoundTrips() throws {
        let source = package()
        let json = String(data: try JSONEncoder.iso8601.encode(source), encoding: .utf8)!
        XCTAssertEqual(try ExchangeTextCodec.decode("before\n\(json)\nafter").packageID, source.packageID)
    }

    func testTruncatedMarkedTextAndMultiplePackagesAreRejected() throws {
        let text = try ExchangeTextCodec.encode(package())
        XCTAssertThrowsError(try ExchangeTextCodec.decode(text.replacingOccurrences(of: ExchangeTextCodec.jsonEnd, with: "")))
        XCTAssertThrowsError(try ExchangeTextCodec.decode(text + "\n" + text)) { error in
            XCTAssertEqual(error as? ExchangeTextCodec.CodecError, .multiplePackages)
        }
    }

    func testUTF16BOMAndOversizeTextAreHandled() throws {
        let text = try ExchangeTextCodec.encode(package())
        let utf16 = Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!
        XCTAssertEqual(try ExchangeTextCodec.decode(data: utf16).packageID, "package")
        XCTAssertThrowsError(try ExchangeTextCodec.decode(String(repeating: "x", count: ExchangeTextCodec.maxTextBytes + 1))) { error in
            XCTAssertEqual(error as? ExchangeTextCodec.CodecError, .tooLarge(ExchangeTextCodec.maxTextBytes + 1))
        }
    }

    func testPlanWithMaliciousActualStillImportsAsUnknown() throws {
        var malicious = package(kind: .plan)
        malicious.sessions[0].blocks[0].entries[0].sets[0].actual = .fixed(value: 99, raw: "99")
        let destination = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(destination)
        let client = Client(id: "receiver", name: "Receiver")
        context.insert(client)
        _ = try ExchangeImporter.commit(malicious, targetClientID: client.id, in: context)
        let imported = try XCTUnwrap(try context.fetch(FetchDescriptor<WorkoutSession>()).first)
        XCTAssertEqual(imported.orderedBlocks.first?.orderedEntries.first?.orderedSets.first?.actual, .unknown(raw: "not recorded in shared package"))
    }

    func testWODPackageTextRoundTripsWithoutDroppingTheBlock() throws {
        var wod = package(kind: .results)
        wod.sessions[0].blocks[0] = ExchangeBlockDTO(order: 0, blockType: .single, restSeconds: nil, sectionKind: .wod, entries: [], wodPayloadRawJSON: "{\"schemaVersion\":1,\"prescription\":{},\"result\":{}}")
        let text = try ExchangeTextCodec.encode(wod)
        XCTAssertTrue(text.contains("WOD"))
        let decoded = try ExchangeTextCodec.decode(text)
        XCTAssertEqual(decoded.sessions.first?.blocks.first?.sectionKind, .wod)
        XCTAssertEqual(decoded.sessions.first?.blocks.first?.wodPayloadRawJSON, wod.sessions.first?.blocks.first?.wodPayloadRawJSON)
    }

    func testInvalidPackageDateIsRejectedInsteadOfFallingBackToToday() throws {
        var invalid = package()
        invalid.sessions[0].trainingLocalDate = "2026-02-30"
        XCTAssertThrowsError(try ExchangeTextCodec.decode(try ExchangeTextCodec.encode(invalid))) { error in
            XCTAssertTrue(String(describing: error).contains("trainingLocalDate"))
        }
    }

    func testLegacyBilingualSummaryIsConservativeAndStable() throws {
        let summary = "Ada 訓練摘要 · 2026-09-17 · 第3週\n\n單組:\n• Bench Press：60kg×8 次"
        let first = try ExchangeTextCodec.decode(summary)
        let second = try ExchangeTextCodec.decode(summary)
        XCTAssertEqual(first.payloadKind, .results)
        XCTAssertEqual(first.sessions.first?.recordID, second.sessions.first?.recordID)
        XCTAssertEqual(first.sessions.first?.blocks.first?.entries.first?.sets.first?.target, .unknown(raw: "legacy summary has no target"))
        XCTAssertEqual(first.sessions.first?.blocks.first?.entries.first?.sets.first?.actual, .fixed(value: 8, raw: "8 次"))

        let english = "Ada — Session Summary · 2026-09-17 · Week 3\n\nSingle:\n• Bench Press：60kg×8 reps"
        let englishPackage = try ExchangeTextCodec.decode(english)
        XCTAssertEqual(englishPackage.sessions.first?.blocks.first?.blockType, .single)
        XCTAssertEqual(englishPackage.sessions.first?.blocks.first?.entries.first?.sets.first?.actual, .fixed(value: 8, raw: "8 reps"))
    }

    func testLegacySummaryProducedBySessionSummaryGeneratorParses() throws {
        let oldLanguage = UserDefaults.standard.object(forKey: "appLanguage")
        defer {
            if let oldLanguage { UserDefaults.standard.set(oldLanguage, forKey: "appLanguage") }
            else { UserDefaults.standard.removeObject(forKey: "appLanguage") }
        }
        UserDefaults.standard.set(AppLanguage.zhHant.rawValue, forKey: "appLanguage")
        let client = Client(id: "codec-client", name: "Ada")
        let exercise = Exercise(id: "codec-exercise", canonicalName: "Bench Press", aliases: [], movementPattern: .push, equipment: .barbell, loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 0, needsReview: false, reviewReason: nil)
        let session = WorkoutSession(id: "codec-session", date: ISO8601DateFormatter().date(from: "2026-09-17T12:00:00Z")!, dateOrigin: .asRecorded, dateRaw: "2026-09-17", weekNumber: 3, sourceSheet: "Test", sourceRow: 0)
        session.client = client
        let block = SessionBlock(order: 0, blockType: .single, sourceRow: 0)
        block.session = session
        let entry = ExerciseEntry(order: 0, exerciseIdRef: exercise.id, exerciseRaw: exercise.canonicalName, plannedSets: 1, exercise: exercise)
        entry.block = block
        let set = SetLog(setIndex: 0, load: .absolute(kg: 60, raw: "60"), target: .unknown(raw: ""), actual: .fixed(value: 8, raw: "8"), isInferred: false)
        set.entry = entry
        context.insert(client); context.insert(exercise); context.insert(session); context.insert(block); context.insert(entry); context.insert(set)
        let summary = SessionSummaryGenerator.summary(for: session, clientName: client.displayName, prPointIDs: [])
        let decoded = try ExchangeTextCodec.decode(summary)
        XCTAssertEqual(decoded.sessions.first?.trainingLocalDate, "2026-09-17")
        XCTAssertEqual(decoded.sessions.first?.blocks.first?.entries.first?.sets.first?.actual, .fixed(value: 8, raw: "8 次"))
    }

    func testUnsupportedLegacyRowsRejectAndUnitlessValuesStayUnknown() throws {
        XCTAssertThrowsError(try ExchangeTextCodec.decode("Ada 訓練摘要 · 2026-09-17 · 第3週\n\nWOD:\n• Fran：3"))
        let parsed = try ExchangeTextCodec.decode("Ada 訓練摘要 · 2026-09-17 · 第3週\n\n單組:\n• Bench Press：60kg×8")
        XCTAssertEqual(parsed.sessions.first?.blocks.first?.entries.first?.sets.first?.actual, .unknown(raw: "8"))
    }

    func testLegacySummaryValidatesDateAndKnownFormatterLoadText() throws {
        let invalidDate = "Ada 訓練摘要 · 2026-02-30 · 第3週\n\n單組:\n• Bench Press：60kg×8 次"
        XCTAssertThrowsError(try ExchangeTextCodec.decode(invalidDate)) { error in
            XCTAssertTrue(String(describing: error).contains("trainingLocalDate"))
        }

        let summary = "Ada 訓練摘要 · 2026-09-17 · 第3週\n\n單組:\n• Pull-up：自重×8 次\n• Split squat：單側 10kg×8 次\n• Pulldown：輔助 -10kg×8 次"
        let parsed = try ExchangeTextCodec.decode(summary)
        let entries = try XCTUnwrap(parsed.sessions.first?.blocks.first?.entries)
        let sets = entries.flatMap(\.sets)
        XCTAssertEqual(sets[0].load, .bodyweight(raw: "自重"))
        XCTAssertEqual(sets[1].load, .perSide(kg: 10, raw: "單側 10kg"))
        XCTAssertEqual(sets[2].load, .assisted(kg: 10, raw: "輔助 -10kg"))
    }

    func testLegacySummaryParsesUnequalAndEnglishPerSideResults() throws {
        let summary = "Ada — Session Summary · 2026-09-17 · Week 3\n\nSingle:\n• Split squat：60kg×L8 R10 reps\n• Lunges：20kg×10 reps/side"
        let parsed = try ExchangeTextCodec.decode(summary)
        let entries = try XCTUnwrap(parsed.sessions.first?.blocks.first?.entries)
        let sets = entries.flatMap(\.sets)
        XCTAssertEqual(sets[0].actual, .perSide(left: 8, right: 10, raw: "L8 R10 reps"))
        XCTAssertEqual(sets[1].actual, .perSide(left: 10, right: 10, raw: "10 reps/side"))
    }
}

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
