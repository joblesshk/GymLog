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
        if arguments.contains("-screenshotShowcase") { seedShowcase(for: client, in: context) }
    }

    /// App Store screenshots only: a synthetic client (no real athlete) with six weeks of
    /// progressing A/B sessions and InBody records. Imports the exercise library itself so the
    /// sessions point at real library rows and no import banner covers the first screen.
    private static func seedShowcase(for client: Client, in context: ModelContext) {
        if let url = Bundle.main.url(forResource: "exercise_library_seed", withExtension: "json") {
            _ = try? SeedImporter.importSeed(from: url, into: context)
        }
        client.name = "陳嘉欣"; client.gender = "女"; client.age = 32; client.heightCm = 165
        client.startWeightKg = 62; client.goal = "增肌減脂，12 週內硬舉 100 kg"
        let library = (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
        func exercise(_ id: String) -> Exercise? { library.first { $0.id == id } }
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        // (exercise id, sets, reps, starting kg, weekly increase)
        // Whole-kilogram steps keep the summary tiles free of decimals.
        let dayA: [(String, Int, Int, Double, Double)] = [("ex-e9ef8fb3", 4, 8, 45, 2), ("ex-bf3245ad", 4, 8, 30, 1), ("ex-90a95057", 3, 10, 12, 1), ("ex-7ee6be80", 3, 10, 8, 1)]
        let dayB: [(String, Int, Int, Double, Double)] = [("ex-43564d3c", 4, 6, 60, 5), ("ex-a07c0b8f", 3, 10, 50, 5), ("ex-83992c85", 3, 10, 30, 2), ("ex-5afbb0fe", 3, 12, 8, 1)]
        for index in 0..<12 {
            let week = index / 2
            let plan = index.isMultiple(of: 2) ? dayA : dayB
            let date = calendar.date(byAdding: .day, value: -(43 - week * 7 - (index % 2) * 3), to: today)!.addingTimeInterval(19 * 3600)
            let session = WorkoutSession(id: "showcase-\(index)", date: date, dateOrigin: .asRecorded, dateRaw: "",
                weekNumber: week + 1, sourceSheet: "App", sourceRow: 0, warmup: "動態伸展 8 分鐘", plannedDurationMinutes: 60)
            session.client = client
            context.insert(session)
            for (order, item) in plan.enumerated() {
                guard let exercise = exercise(item.0) else { continue }
                let block = SessionBlock(order: order, blockType: .single, restSeconds: 90, restRaw: "90s", sourceRow: order)
                block.session = session
                context.insert(block)
                let entry = ExerciseEntry(order: 0, exerciseIdRef: exercise.id, exerciseRaw: exercise.canonicalName, plannedSets: item.1, exercise: exercise)
                entry.block = block
                context.insert(entry)
                let kg = item.3 + Double(week) * item.4
                let raw = kg.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(kg)) : String(kg)
                for set in 0..<item.1 {
                    let reps = set == item.1 - 1 && week % 3 == 2 ? item.2 - 1 : item.2
                    let log = SetLog(setIndex: set, load: .absolute(kg: kg, raw: raw), target: .fixed(value: item.2, raw: String(item.2)),
                        actual: .fixed(value: reps, raw: String(reps)), isInferred: false)
                    log.entry = entry
                    context.insert(log)
                }
            }
        }
        let metrics: [(Int, Double, Double, Double)] = [(49, 62.0, 27.8, 23.1), (42, 61.6, 27.2, 23.3), (35, 61.3, 26.6, 23.4), (28, 61.1, 26.1, 23.6), (21, 60.7, 25.5, 23.8), (14, 60.4, 25.0, 23.9), (7, 60.2, 24.6, 24.1), (1, 59.9, 24.1, 24.3)]
        for (offset, weight, fat, muscle) in metrics {
            let metric = BodyMetric(id: "showcase-bm-\(offset)", date: calendar.date(byAdding: .day, value: -offset, to: today)!.addingTimeInterval(8 * 3600),
                weightKg: weight, bodyFatPercent: fat, skeletalMuscleKg: muscle)
            metric.client = client
            context.insert(metric)
        }
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
