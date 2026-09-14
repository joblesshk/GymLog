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
            context.insert(Client(id: "ui-test-client", name: "UI Test Client"))
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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(theme.colorScheme)
        }
        .modelContainer(container)
    }
}
