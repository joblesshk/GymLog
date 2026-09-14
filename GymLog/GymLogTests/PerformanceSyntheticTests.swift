import XCTest
import SwiftData
@testable import GymLogKit

/// 2026-09-08 M3 acceptance criterion (工程审阅与CrossFit适配方案.md):
/// "测1,000/10,000合成课次的首屏和查询,保留设备及结果;没有瓶颈证据就不全面重构
/// 查询" -- measure history-list first-screen load and the WOD/strength PR
/// scans against 1,000 and 10,000 synthetic sessions, on the actual
/// destination simulator, and only justify a query rewrite if one of these
/// shows real evidence of a bottleneck. Thresholds below are deliberately
/// generous (an order of magnitude above what was actually observed while
/// writing this test) -- they exist to catch a genuine future regression,
/// not to assert a specific timing.
final class PerformanceSyntheticTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var client: Client!

    override func setUpWithError() throws {
        container = try TestSupport.makeInMemoryContainer()
        context = ModelContext(container)
        client = Client(id: "perf-client", name: "Perf Client")
        context.insert(client)
    }

    // MARK: - Synthetic data generation

    /// One WOD block (For Time, 2 movements) + one strength block (1 entry,
    /// 3 sets) per session, alternating exercises across a small pool so the
    /// PR analyzers have genuine multi-attempt history to scan, not just
    /// singleton groups.
    @discardableResult
    private func makeSessions(count: Int) throws -> [WorkoutSession] {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let benchExercise = Exercise(
            id: "perf-ex-bench", canonicalName: "Perf Bench Press", aliases: [],
            movementPattern: .unknown, equipment: .other, loadDirection: .higherIsStronger,
            isUnilateral: false, occurrenceCount: 0, needsReview: false, reviewReason: nil
        )
        context.insert(benchExercise)

        var sessions: [WorkoutSession] = []
        sessions.reserveCapacity(count)

        for i in 0..<count {
            let date = baseDate.addingTimeInterval(Double(i) * 86_400)
            let session = WorkoutSession(
                id: "perf-session-\(i)",
                date: date,
                dateOrigin: .asRecorded,
                dateRaw: "synthetic",
                weekNumber: i / 7,
                sourceSheet: "perf",
                sourceRow: i
            )
            session.client = client
            context.insert(session)

            let elapsed = 900 - (i % 60) // varies so PR flags aren't all-true or all-false
            let prescription = WODPrescription(
                id: "perf-wod-fran", revision: 1, name: "Perf Fran", format: .forTime,
                rounds: [WODRoundPrescription(roundIndex: 0, movements: [
                    WODMovementPrescription(stepID: "s1", exerciseID: nil, exerciseNameSnapshot: "Thruster", quantity: .reps(21, raw: "21")),
                    WODMovementPrescription(stepID: "s2", exerciseID: nil, exerciseNameSnapshot: "Pull-up", quantity: .reps(21, raw: "21")),
                ])],
                scoringRule: .completionTime
            )
            let result = WODResult(status: .completed, elapsedSeconds: elapsed, variant: .rx)
            let wodBlock = SessionBlock(order: 0, blockType: .single, sourceRow: i, sectionKind: .wod, wodPayload: WODPayload(prescription: prescription, result: result))
            wodBlock.session = session
            context.insert(wodBlock)

            let strengthBlock = SessionBlock(order: 1, blockType: .single, sourceRow: i, sectionKind: .strength)
            strengthBlock.session = session
            context.insert(strengthBlock)

            let entry = ExerciseEntry(order: 0, exerciseIdRef: benchExercise.id, exerciseRaw: benchExercise.canonicalName, plannedSets: 3, exercise: benchExercise)
            entry.block = strengthBlock
            context.insert(entry)

            for setIndex in 0..<3 {
                let kg = Double(60 + (i % 40) + setIndex)
                let load = LoadValue.absolute(kg: kg, raw: "\(kg)")
                let set = SetLog(setIndex: setIndex, load: load, target: .fixed(value: 5, raw: "5"), actual: .fixed(value: 5, raw: "5"), isInferred: false)
                set.entry = entry
                context.insert(set)
            }

            sessions.append(session)
        }

        try context.save()
        return sessions
    }

    // MARK: - 1,000 sessions

    func testFirstScreenAndPRQueriesAt1000Sessions() throws {
        let genStart = CFAbsoluteTimeGetCurrent()
        try makeSessions(count: 1_000)
        print("[PERF] generate+save 1,000 sessions: \(CFAbsoluteTimeGetCurrent() - genStart)s")
        try measureHistoryWorkload(sessionCount: 1_000, fetchBudget: 1.0, wodPRBudget: 1.5, strengthPRBudget: 1.5)
    }

    // MARK: - 10,000 sessions

    func testFirstScreenAndPRQueriesAt10000Sessions() throws {
        let genStart = CFAbsoluteTimeGetCurrent()
        try makeSessions(count: 10_000)
        print("[PERF] generate+save 10,000 sessions: \(CFAbsoluteTimeGetCurrent() - genStart)s")
        try measureHistoryWorkload(sessionCount: 10_000, fetchBudget: 3.0, wodPRBudget: 6.0, strengthPRBudget: 6.0)
    }

    // MARK: - Shared workload

    /// Mirrors the three real hot paths this scale actually exercises:
    /// `HistoryListView`'s `@Query` + `SessionRow` summary formatting (first
    /// screen), `SessionDetailView.wodPRBlockKeys` (full-history WOD PR
    /// scan, recomputed on every detail-view render), and the pre-existing
    /// `SessionDetailView.prPointIDs` full-history strength PR scan.
    private func measureHistoryWorkload(sessionCount: Int, fetchBudget: Double, wodPRBudget: Double, strengthPRBudget: Double) throws {
        // 1) First-screen fetch + row summary formatting (HistoryListView).
        let fetchStart = CFAbsoluteTimeGetCurrent()
        let descriptor = FetchDescriptor<WorkoutSession>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        let allSessions = try context.fetch(descriptor)
        XCTAssertEqual(allSessions.count, sessionCount)
        for session in allSessions {
            for block in session.orderedBlocks where block.sectionKind == .wod {
                if let payload = block.wodPayload {
                    _ = WODSummaryFormatter.compactSummary(payload)
                }
            }
        }
        let fetchElapsed = CFAbsoluteTimeGetCurrent() - fetchStart
        print("[PERF] first-screen fetch+format (\(sessionCount) sessions): \(fetchElapsed)s")
        XCTAssertLessThan(fetchElapsed, fetchBudget, "History first-screen fetch+format took \(fetchElapsed)s for \(sessionCount) sessions, budget \(fetchBudget)s")

        // 2) WOD PR scan across full history (SessionDetailView.wodPRBlockKeys shape).
        let wodStart = CFAbsoluteTimeGetCurrent()
        var keys: [String] = []
        var entries: [WODPRAnalyzer.Entry] = []
        for session in allSessions {
            for block in session.orderedBlocks where block.sectionKind == .wod {
                guard let payload = block.wodPayload else { continue }
                keys.append("\(session.id)#\(block.order)")
                entries.append(WODPRAnalyzer.Entry(date: session.date, payload: payload))
            }
        }
        let combined = zip(keys, entries).sorted { $0.1.date < $1.1.date }
        let flags = WODPRAnalyzer.prFlags(entries: combined.map(\.1))
        XCTAssertEqual(flags.count, sessionCount)
        let wodElapsed = CFAbsoluteTimeGetCurrent() - wodStart
        print("[PERF] WOD PR scan (\(sessionCount) sessions): \(wodElapsed)s")
        XCTAssertLessThan(wodElapsed, wodPRBudget, "WOD PR scan took \(wodElapsed)s for \(sessionCount) sessions, budget \(wodPRBudget)s")

        // 3) Strength PR scan across full history (SessionDetailView.prPointIDs shape).
        let strengthStart = CFAbsoluteTimeGetCurrent()
        let allEntries = try context.fetch(FetchDescriptor<ExerciseEntry>())
        XCTAssertEqual(allEntries.count, sessionCount)
        let points = ExerciseHistoryAnalyzer.points(from: allEntries, loadDirection: .higherIsStronger, includeInferred: true)
        let prFlags = ExerciseHistoryAnalyzer.prFlags(points: points, direction: .higherIsStronger)
        XCTAssertEqual(prFlags.count, points.count)
        let strengthElapsed = CFAbsoluteTimeGetCurrent() - strengthStart
        print("[PERF] Strength PR scan (\(sessionCount) sessions): \(strengthElapsed)s")
        XCTAssertLessThan(strengthElapsed, strengthPRBudget, "Strength PR scan took \(strengthElapsed)s for \(sessionCount) sessions, budget \(strengthPRBudget)s")
    }
}
