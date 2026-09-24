#if DEBUG
import SwiftUI
import SwiftData
import GymLogKit

/// Synthetic data for GymLogUITests, chosen by launch arguments and only
/// compiled into Debug builds (UI tests run Debug). `-uiTesting` itself, which
/// selects the in-memory store, stays in `GymLogApp`.
@MainActor
enum UITestingSeeds {
    static func apply(to client: Client, in context: ModelContext, arguments: [String]) {
        if arguments.contains("-uiTestingBodyMetrics") { seedBodyMetrics(for: client, in: context) }
        if arguments.contains("-uiTestingReviewedSession") { seedReviewedSession(for: client, in: context) }
        if arguments.contains("-uiTestingBandHistory") { seedBandHistory(for: client, in: context) }
    }

    /// UI tests only: one finished, synthetic session with a stored AI review, so the history
    /// detail cards can be exercised without a cloud service.
    private static func seedReviewedSession(for client: Client, in context: ModelContext) {
        let session = WorkoutSession(id: "ui-test-reviewed", date: Date(), dateOrigin: .asRecorded, dateRaw: "ui-test", weekNumber: 1, sourceSheet: "App", sourceRow: 0)
        session.client = client
        context.insert(session)
        for (order, (name, nameZh, pattern)) in [("Back squat", "槓鈴背蹲", MovementPattern.squat), ("Bench press", "槓鈴臥推", .push)].enumerated() {
            let exercise = Exercise(id: "ui-ex-\(order)", canonicalName: name, aliases: [], movementPattern: pattern, equipment: .barbell, loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 0, needsReview: false, reviewReason: nil, nameZh: nameZh)
            context.insert(exercise)
            let block = SessionBlock(order: order, blockType: .single, restSeconds: 90, restRaw: "90s", sourceRow: order)
            block.session = session
            context.insert(block)
            let entry = ExerciseEntry(order: 0, exerciseIdRef: exercise.id, exerciseRaw: name, plannedSets: 3, exercise: exercise)
            entry.block = block
            context.insert(entry)
            for index in 0..<3 {
                let set = SetLog(setIndex: index, load: .absolute(kg: order == 0 ? 60 : 40, raw: order == 0 ? "60" : "40"), target: .range(low: 8, high: 12, raw: "8-12"), actual: index < 2 || order == 0 ? .fixed(value: 10, raw: "10") : .unknown(raw: ""), isInferred: false)
                set.entry = entry
                context.insert(set)
            }
        }
        let report = TrainingInsights.report(session)
        let review = TrainingReview(
            summary: "兩個主項都按計劃完成了大部分組數，深蹲三組全部記錄，臥推最後一組未填結果。",
            findings: ["深蹲 60 kg 三組均達到目標範圍下緣，節奏穩定。", "臥推前兩組完成 10 次，第三組沒有記錄，無法判斷是否完成。"],
            suggestions: ["下次先補齊臥推最後一組的實際次數。", "若深蹲三組都能輕鬆完成 12 次，再考慮小幅增加負重。"],
            limitations: ["沒有 RPE 或動作影片，無法評估動作品質與疲勞程度。"],
            evidenceIDs: report.lines.map(\.id)
        )
        session.insightJSON = TrainingInsights.encode(InsightArchive(fingerprint: TrainingInsights.fingerprint(report), energy: report, review: review, reviewFingerprint: TrainingInsights.reviewKey(session), generatedAt: Date().addingTimeInterval(-3600), model: "deepseek-flash"))
    }

    /// UI-only body-composition fixture. It intentionally contains eight
    /// records with uneven dates, two same-day records, and metric-specific
    /// gaps so the profile trend can be checked against the shared latest-six
    /// window without touching user data.
    private static func seedBodyMetrics(for client: Client, in context: ModelContext) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ day: Int, hour: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
        }
        let records: [(id: String, date: Date, weight: Double?, fat: Double?, muscle: Double?)] = [
            ("ui-bm-01", date(1), 70.0, 22.0, 30.0),
            ("ui-bm-02", date(4), 69.7, 21.8, 30.2),
            ("ui-bm-03", date(10), 69.0, 21.5, nil),
            ("ui-bm-04", date(12, hour: 8), 68.8, 21.0, 31.0),
            ("ui-bm-05", date(12, hour: 18), 68.6, nil, 31.1),
            ("ui-bm-06", date(15), 68.0, 20.5, 31.2),
            ("ui-bm-07", date(20), 67.5, 20.0, 31.4),
            ("ui-bm-08", date(25), 67.0, 19.5, 31.6)
        ]
        if ProcessInfo.processInfo.arguments.contains("-uiTestingBodyMetricHistory") {
            for index in 9...16 {
                let metric = BodyMetric(id: String(format: "ui-bm-%02d", index),
                    date: date(25).addingTimeInterval(Double(index - 8) * 86400),
                    weightKg: Double(60 + index), bodyFatPercent: Double(index + 10),
                    skeletalMuscleKg: Double(index + 20))
                metric.client = client
                context.insert(metric)
            }
        }
        for record in records {
            let metric = BodyMetric(
                id: record.id,
                date: record.date,
                weightKg: record.weight,
                bodyFatPercent: record.fat,
                skeletalMuscleKg: record.muscle
            )
            metric.client = client
            context.insert(metric)
        }
    }

    /// A synthetic machine exercise whose only history is an orange band,
    /// for the band/weight switch after a numeric override.
    private static func seedBandHistory(for client: Client, in context: ModelContext) {
        let exercise = Exercise(id: "ui-band-history", canonicalName: "Synthetic band history", aliases: [],
            movementPattern: .pull, equipment: .machine, loadDirection: .higherIsStronger,
            isUnilateral: false, occurrenceCount: 1, needsReview: false, reviewReason: nil)
        let session = WorkoutSession(id: "ui-band-session", date: Date(), dateOrigin: .asRecorded,
            dateRaw: "", weekNumber: 1, sourceSheet: "UI test", sourceRow: 0)
        let block = SessionBlock(order: 0, blockType: .single, sourceRow: 0)
        let entry = ExerciseEntry(order: 0, exerciseIdRef: exercise.id, exerciseRaw: exercise.canonicalName, plannedSets: 1, exercise: exercise)
        let set = SetLog(setIndex: 0, load: .band(color: "orange", count: 1, raw: "orange"),
            target: .fixed(value: 10, raw: "10"), actual: .fixed(value: 10, raw: "10"), isInferred: false)
        context.insert(exercise); context.insert(session); session.client = client
        context.insert(block); block.session = session
        context.insert(entry); entry.block = block
        context.insert(set); set.entry = entry
    }
}
#endif
