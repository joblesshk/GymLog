import XCTest
import SwiftData
@testable import GymLogKit

/// 2026-09-09 的「訓練體系」分类（力量 / CrossFit / 兩者皆是）与随之补进标准
/// 动作库的 16 个主流 CrossFit 动作。
///
/// 教练的原话：「exercise 里面可以分为：Gym 力量训练需要的 exercise 和 CrossFit
/// 所有的 movements」。这套用例盯三件事：
///
/// 1. 种子文件里每一行都有分类，且两个筛选各自不为空（否则 WOD 那边的
///    CrossFit 筛选会是一片空白，等于没做）；
/// 2. 已装机设备的回填只写 `discipline` 一个字段——教练在動作庫里手工改过的
///    名称/分类/记录方式绝不能被这一支覆盖（`applyLibraryAdditions` 已经立过
///    同一条规矩）；
/// 3. 幂等：重复跑不会重复插行、也不会把值改坏。
final class ExerciseDiscipline20260909Tests: XCTestCase {

    private final class BundleToken {}

    private func seedURL() throws -> URL {
        try XCTUnwrap(Bundle(for: BundleToken.self).url(forResource: "exercise_library_seed", withExtension: "json"))
    }

    private func emptyContext() throws -> ModelContext {
        ModelContext(try TestSupport.makeInMemoryContainer())
    }

    private func decodedSeed() throws -> SeedFile {
        try JSONDecoder().decode(SeedFile.self, from: try Data(contentsOf: try seedURL()))
    }

    // MARK: - 种子文件

    func testEverySeedRowCarriesADiscipline() throws {
        for exercise in try decodedSeed().exercises {
            XCTAssertNotNil(exercise.discipline, "\(exercise.canonicalName) 缺少 discipline")
        }
    }

    /// 两个筛选都必须有实打实的内容。库里 CrossFit 一侧如果只剩个位数，那这个
    /// 功能对教练就是没用的。
    func testBothDisciplineFiltersHaveRealContent() throws {
        let exercises = try decodedSeed().exercises
        let strength = exercises.filter { ($0.discipline ?? .strength).belongs(to: .strength) }
        let crossfit = exercises.filter { ($0.discipline ?? .strength).belongs(to: .crossfit) }
        XCTAssertGreaterThan(strength.count, 150, "力量一側太少")
        XCTAssertGreaterThan(crossfit.count, 80, "CrossFit 一側太少")
        // 重叠是这个三值枚举存在的理由：Deadlift/Thruster 之类两边都算。
        XCTAssertGreaterThan(strength.count + crossfit.count, exercises.count, "應該存在「兩者皆是」的重疊")
    }

    /// 抽查几条：只在 CrossFit 里出现的、两边都用的、以及只在力量课里出现的。
    /// 分错的话，教练在 WOD 里翻不到 Double-under，或者在 CrossFit 筛选里翻到
    /// 一堆固定器械。
    func testSpotChecksOnTheClassification() throws {
        var byName: [String: ExerciseDiscipline] = [:]
        for exercise in try decodedSeed().exercises {
            byName[exercise.canonicalName] = exercise.discipline ?? .strength
        }
        XCTAssertEqual(byName["Double-under"], .crossfit)
        XCTAssertEqual(byName["Kipping Pull-up"], .crossfit)
        XCTAssertEqual(byName["Wall Walk"], .crossfit)
        XCTAssertEqual(byName["Deadlift"], .both)
        XCTAssertEqual(byName["Thruster"], .both)
        XCTAssertEqual(byName["Wall ball"], .both)
        XCTAssertEqual(byName["Machine chest fly"], .strength)
        XCTAssertEqual(byName["Latpull wide"], .strength)
    }

    // MARK: - 新增的 16 个动作

    func testSeedShipsTheSixteenNewCrossFitMovements() throws {
        let byID = Dictionary(uniqueKeysWithValues: try decodedSeed().exercises.map { ($0.id, $0) })
        XCTAssertEqual(SeedImporter.libraryAdditionIDs20260909.count, 16)
        XCTAssertEqual(Set(SeedImporter.libraryAdditionIDs20260909).count, 16, "no duplicate ids")

        for id in SeedImporter.libraryAdditionIDs20260909 {
            let exercise = try XCTUnwrap(byID[id], "seed 里找不到 \(id)")
            XCTAssertFalse(exercise.canonicalName.isEmpty)
            XCTAssertFalse(exercise.nameZh?.isEmpty ?? true, "\(exercise.canonicalName)：每一行都要有中文名")
            XCTAssertFalse(exercise.notes?.isEmpty ?? true, "\(exercise.canonicalName)：每一行都要有動作說明")
            XCTAssertFalse(exercise.needsReview, "人工整理的行不是分类器猜的，needsReview 必须为 false")
            XCTAssertNotEqual(exercise.discipline, .strength, "这一批加的都是 CrossFit 动作")
        }
    }

    func testAdditionsInsertOnlyWhatIsMissingAndAreIdempotent() throws {
        let context = try emptyContext()
        let url = try seedURL()
        let inserted = try SeedImporter.applyExerciseLibraryAdditions20260909(seedURL: url, context: context)
        XCTAssertEqual(inserted, 16)
        XCTAssertEqual(try SeedImporter.applyExerciseLibraryAdditions20260909(seedURL: url, context: context), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Exercise>()), 16)
    }

    // MARK: - 已装机设备的回填

    /// 升级上来的设备里，每一行都通过轻量迁移拿到默认的 `.strength`。这一支要
    /// 把它们按种子文件改对。
    func testClassificationBackfillFixesRowsThatMigratedInAsStrength() throws {
        let context = try emptyContext()
        let url = try seedURL()
        // 先整份导入，再把所有行退回「出厂默认」，模拟轻量迁移后的状态。
        _ = try SeedImporter.importSeed(from: url, into: context)
        for exercise in try context.fetch(FetchDescriptor<Exercise>()) {
            exercise.discipline = .strength
        }
        try context.save()

        let changed = try SeedImporter.applyExerciseDisciplineClassification20260909(seedURL: url, context: context)
        XCTAssertGreaterThan(changed, 80, "至少該把 CrossFit 与「兩者皆是」那一批改回来")

        let all = try context.fetch(FetchDescriptor<Exercise>())
        let doubleUnder = try XCTUnwrap(all.first { $0.canonicalName == "Double-under" })
        XCTAssertEqual(doubleUnder.discipline, .crossfit)
        let deadlift = try XCTUnwrap(all.first { $0.canonicalName == "Deadlift" })
        XCTAssertEqual(deadlift.discipline, .both)

        // 幂等：第二次跑没有任何行需要改。
        XCTAssertEqual(try SeedImporter.applyExerciseDisciplineClassification20260909(seedURL: url, context: context), 0)
    }

    /// 这一支**只**写 discipline。教练手工改过的其他字段必须原样留着——
    /// `applyExerciseLibraryReview202609`（会整份 upsert）与它的区别就在这里。
    func testClassificationBackfillTouchesNothingButDiscipline() throws {
        let context = try emptyContext()
        let url = try seedURL()
        _ = try SeedImporter.importSeed(from: url, into: context)

        let all = try context.fetch(FetchDescriptor<Exercise>())
        let thruster = try XCTUnwrap(all.first { $0.canonicalName == "Thruster" })
        thruster.canonicalName = "Thruster（教練改過的名字）"
        thruster.nameZh = "教練自己填的"
        thruster.recordingMetric = .time
        thruster.equipment = .dumbbell
        thruster.discipline = .strength
        try context.save()

        try SeedImporter.applyExerciseDisciplineClassification20260909(seedURL: url, context: context)

        XCTAssertEqual(thruster.canonicalName, "Thruster（教練改過的名字）")
        XCTAssertEqual(thruster.nameZh, "教練自己填的")
        XCTAssertEqual(thruster.recordingMetric, .time)
        XCTAssertEqual(thruster.equipment, .dumbbell)
        XCTAssertEqual(thruster.discipline, .both, "只有 discipline 該被改回種子裡的值")
    }

    /// 教练自己新增的动作（`ex-local-…`，不在种子文件里）不受影响，保持默认的
    /// 「力量」，要改成 CrossFit 由他在動作庫里点。
    func testCoachCreatedExercisesAreLeftAlone() throws {
        let context = try emptyContext()
        let custom = Exercise(
            id: "ex-local-abcd1234", canonicalName: "教練自創動作", aliases: [],
            movementPattern: .unknown, equipment: .other, loadDirection: .higherIsStronger,
            isUnilateral: false, occurrenceCount: 0, needsReview: true, reviewReason: "錄入時新建"
        )
        context.insert(custom)
        try context.save()

        try SeedImporter.applyExerciseDisciplineClassification20260909(seedURL: try seedURL(), context: context)
        XCTAssertEqual(custom.discipline, .strength)
    }

    // MARK: - belongs(to:)

    func testBothBelongsToEitherSide() {
        XCTAssertTrue(ExerciseDiscipline.both.belongs(to: .strength))
        XCTAssertTrue(ExerciseDiscipline.both.belongs(to: .crossfit))
        XCTAssertTrue(ExerciseDiscipline.strength.belongs(to: .strength))
        XCTAssertFalse(ExerciseDiscipline.strength.belongs(to: .crossfit))
        XCTAssertTrue(ExerciseDiscipline.crossfit.belongs(to: .crossfit))
        XCTAssertFalse(ExerciseDiscipline.crossfit.belongs(to: .strength))
    }
}
