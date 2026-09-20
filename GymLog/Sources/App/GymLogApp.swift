import SwiftUI
import SwiftData
import GymLogKit

/// 外观设置（HANDOFF.md §5）：跟随系统 / 浅色 / 深色，`@AppStorage` 持久化，
/// 切换即时生效、无需重启。
enum AppTheme: String, CaseIterable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: return L("跟隨系統", "System")
        case .light: return L("淺色", "Light")
        case .dark: return L("深色", "Dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@main
struct GymLogApp: App {
    @AppStorage("appTheme") private var theme: AppTheme = .system
    let container: ModelContainer

    init() {
        #if DEBUG
        CloudVoiceConfiguration.importDevelopmentConfigurationIfRequested()
        #endif
        // 2026-09-11: XCUITest 需要每次都从一个已知的空白状态出发（无学员、无
        // 未保存草稿），不能依赖上一次测试跑完留下的磁盘状态。`-uiTesting`
        // 只由 `GymLogUITests` 传入（见 P0 崩溃修复的搜索选择器回归），正常
        // App/TestFlight 启动不带这个参数，行为完全不变。
        let isUITesting = ProcessInfo.processInfo.arguments.contains("-uiTesting")
        if isUITesting {
            DraftPersistence().clear()
            // UI tests look up Traditional Chinese labels; a language chosen in an earlier run
            // must not leak into this one.
            UserDefaults.standard.removeObject(forKey: "appLanguage")
        }
        let schema = Schema([
            Client.self,
            BodyMetric.self,
            Assessment.self,
            WorkoutSession.self,
            SessionBlock.self,
            ExerciseEntry.self,
            SetLog.self,
            Exercise.self,
            SessionTemplate.self,
            TemplateBlock.self,
            TemplateExerciseSlot.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: isUITesting)
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        if isUITesting {
            // `TodayView` auto-selects `clients.first?.id` whenever
            // `currentClientID == nil` -- seeding exactly one client here
            // means UI tests can jump straight to today's entry flow without
            // also having to automate 「新增學員」.
            let context = ModelContext(container)
            let client = Client(id: "ui-test-client", name: "UI Test Client", startWeightKg: 70)
            context.insert(client)
            if ProcessInfo.processInfo.arguments.contains("-uiTestingBodyMetrics") {
                Self.seedBodyMetrics(for: client, in: context)
            }
            if ProcessInfo.processInfo.arguments.contains("-uiTestingReviewedSession") {
                Self.seedReviewedSession(for: client, in: context)
            }
            try? context.save()
        }
        // NOTE: HANDOFF.md §2 specifies page titles at 30/Heavy via a global
        // UINavigationBarAppearance override. That was reverted: on this iOS
        // SDK, installing a custom appearance (transparent OR opaque) on
        // UINavigationBar.appearance() while a large title is displayed
        // reproducibly breaks touch delivery to the List/ScrollView content
        // underneath it -- confirmed on-device by every row in SettingsView's
        // List becoming untappable, with the large title itself also failing
        // to render. Shipping a broken Settings screen is worse than a
        // slightly different title weight, so this app keeps the system
        // default large-title style instead.
    }

    /// UI tests only: one finished, synthetic session with a stored AI review, so the history
    /// detail cards can be exercised without a cloud service.
    private static func seedReviewedSession(for client: Client, in context: ModelContext) {
        let session = WorkoutSession(id: "ui-test-reviewed", date: Date(), dateOrigin: .asRecorded, dateRaw: "ui-test", weekNumber: 1, sourceSheet: "App", sourceRow: 0)
        session.client = client
        context.insert(session)
        for (order, (name, pattern)) in [("Back squat", MovementPattern.squat), ("Bench press", .push)].enumerated() {
            let exercise = Exercise(id: "ui-ex-\(order)", canonicalName: name, aliases: [], movementPattern: pattern, equipment: .barbell, loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 0, needsReview: false, reviewReason: nil)
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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(theme.colorScheme)
        }
        .modelContainer(container)
    }
}
