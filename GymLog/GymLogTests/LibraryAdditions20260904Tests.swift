import XCTest
import SwiftData
@testable import GymLogKit

/// 2026-09-04 加进标准动作库的两个动作（器械反向飛鳥 / 坐姿繩索臉拉），以及
/// 让已装机设备也拿到它们的 `SeedImporter.applyExerciseLibraryAdditions20260904`。
///
/// 与 `SeedCorrections202609Tests` 的分工：那一轮验证的是"存量库按 id 全量刷新
/// + 合并/删除旧行"，这一轮验证的是"只塞两行新的，别的一概不碰"——因为这次
/// 刻意没有走 `importSeed` 全量 upsert，正是为了不覆盖教练在动作库里手改过的
/// 分类。
final class LibraryAdditions20260904Tests: XCTestCase {

    private final class BundleToken {}

    private func seedURL() throws -> URL {
        try XCTUnwrap(Bundle(for: BundleToken.self).url(forResource: "exercise_library_seed", withExtension: "json"))
    }

    private func emptyContext() throws -> ModelContext {
        ModelContext(try TestSupport.makeInMemoryContainer())
    }

    /// 教练在真机上手打出来的那种行：`ex-local-` 前缀、没分类、待复核。
    @discardableResult
    private func insertCoachTypedExercise(named name: String, into context: ModelContext) -> Exercise {
        let exercise = Exercise(
            id: "ex-local-\(UUID().uuidString.prefix(8))",
            canonicalName: name,
            aliases: [],
            movementPattern: .unknown,
            equipment: .other,
            loadDirection: .higherIsStronger,
            isUnilateral: false,
            occurrenceCount: 0,
            needsReview: true,
            reviewReason: "錄入時新建"
        )
        context.insert(exercise)
        return exercise
    }

    /// 给一个动作挂一条真实的训练记录，用来验证合并时历史确实被搬走了。
    private func attachEntry(to exercise: Exercise, in context: ModelContext) -> ExerciseEntry {
        let client = Client(id: "cl-test", name: "測試學員")
        let session = WorkoutSession(
            id: "se-test-\(UUID().uuidString.prefix(6))",
            date: Date(timeIntervalSince1970: 1_756_900_000),
            dateOrigin: .asRecorded,
            dateRaw: "2026-09-03",
            weekNumber: 1,
            sourceSheet: "App",
            sourceRow: 0
        )
        session.client = client
        let block = SessionBlock(order: 0, blockType: .single, restSeconds: 60, sourceRow: 0)
        block.session = session
        let entry = ExerciseEntry(
            order: 0,
            exerciseIdRef: exercise.id,
            exerciseRaw: exercise.canonicalName,
            plannedSets: 3,
            exercise: exercise
        )
        entry.block = block
        context.insert(client)
        context.insert(session)
        context.insert(block)
        context.insert(entry)
        return entry
    }

    // MARK: - 种子文件本身

    func testSeedShipsBothNewExercisesFullyFilledIn() throws {
        let context = try emptyContext()
        _ = try SeedImporter.importSeed(from: try seedURL(), into: context)
        let exercises = try context.fetch(FetchDescriptor<Exercise>())

        let reverseFly = try XCTUnwrap(exercises.first { $0.id == "ex-d134356d" })
        XCTAssertEqual(reverseFly.canonicalName, "Machine reverse fly")
        XCTAssertEqual(reverseFly.nameZh, "器械反向飛鳥")
        XCTAssertEqual(reverseFly.movementPattern, .pull, "後三角/上背是拉，不是推")
        XCTAssertEqual(reverseFly.equipment, .machine)
        XCTAssertEqual(reverseFly.recordingMetric, .reps)
        XCTAssertFalse(reverseFly.isUnilateral)
        XCTAssertEqual(reverseFly.loadDirection, .higherIsStronger)

        let facepull = try XCTUnwrap(exercises.first { $0.id == "ex-f68651c5" })
        XCTAssertEqual(facepull.canonicalName, "Seated cable facepull")
        XCTAssertEqual(facepull.nameZh, "坐姿繩索臉拉")
        XCTAssertEqual(facepull.movementPattern, .pull)
        XCTAssertEqual(facepull.equipment, .cable)
        XCTAssertEqual(facepull.recordingMetric, .reps)

        // 和库里其他 166 个一样：分类已确认、双语齐全、说明不超长。
        for exercise in [reverseFly, facepull] {
            XCTAssertFalse(exercise.needsReview, "\(exercise.canonicalName) 应该是已复核状态")
            XCTAssertFalse(exercise.notes.isEmpty)
            XCTAssertLessThanOrEqual(exercise.notes.count, 50)
            XCTAssertTrue(exercise.displayName.contains(exercise.nameZh))
        }
    }

    /// 教练当初手打的名字必须能搜到，否则他下次还是找不到、又建一个新的。
    func testCoachesOwnWordingIsSearchableAsAnAlias() throws {
        let context = try emptyContext()
        _ = try SeedImporter.importSeed(from: try seedURL(), into: context)
        let exercises = try context.fetch(FetchDescriptor<Exercise>())

        let reverseFly = try XCTUnwrap(exercises.first { $0.id == "ex-d134356d" })
        XCTAssertTrue(reverseFly.aliases.contains("反向蝴蝶机展肩"), "简体原写法")
        XCTAssertTrue(reverseFly.aliases.contains("反向蝴蝶機展肩"), "繁体写法")
        XCTAssertTrue(reverseFly.aliases.contains("Reverse pec deck fly"), "最常见的英文别名")

        let facepull = try XCTUnwrap(exercises.first { $0.id == "ex-f68651c5" })
        XCTAssertTrue(facepull.aliases.contains("坐姿面拉"))
    }

    func testIDsAreDerivedFromTheNameLikeEveryOtherLibraryRow() {
        // 与 migration/migrate.py 的 stable_exercise_id 同一套规则：
        // sha1(小写动作名)[:8]。写死的 id 若和名字对不上，将来重跑迁移会重复。
        let reverseFlyKey = ExerciseNameCanonicalizer.normalizeKey("Machine reverse fly")
        XCTAssertEqual(ExerciseNameCanonicalizer.stableExerciseID(reverseFlyKey), "ex-d134356d")

        let facepullKey = ExerciseNameCanonicalizer.normalizeKey("Seated cable facepull")
        XCTAssertEqual(ExerciseNameCanonicalizer.stableExerciseID(facepullKey), "ex-f68651c5")
    }

    // MARK: - 存量设备的一次性迁移

    func testInsertsBothRowsIntoAnAlreadyPopulatedLibrary() throws {
        let context = try emptyContext()
        // 模拟"升级上来的设备"：库里已经有东西，但没有这两行。
        insertCoachTypedExercise(named: "Bench press", into: context)
        try context.save()

        let inserted = try SeedImporter.applyExerciseLibraryAdditions20260904(seedURL: try seedURL(), context: context)
        XCTAssertEqual(inserted, 2)

        let ids = Set(try context.fetch(FetchDescriptor<Exercise>()).map(\.id))
        XCTAssertTrue(ids.isSuperset(of: SeedImporter.libraryAdditionIDs20260904))
    }

    /// 本轮和 `applyExerciseLibraryReview202609` 最关键的区别：**不能**碰库里
    /// 其他任何一行。教练在动作库里手动纠正过的分类，不该被这次升级冲掉。
    func testDoesNotTouchAnyOtherExercise() throws {
        let context = try emptyContext()
        _ = try SeedImporter.importSeed(from: try seedURL(), into: context)

        // 教练手动把 Bench press 改成了"未分類"（随便一个和种子文件不同的值）
        let all = try context.fetch(FetchDescriptor<Exercise>())
        let bench = try XCTUnwrap(all.first { $0.id == "ex-bf3245ad" })
        bench.movementPattern = .core
        bench.nameZh = "教練自己改的名字"
        try context.save()

        try SeedImporter.applyExerciseLibraryAdditions20260904(seedURL: try seedURL(), context: context)

        let after = try context.fetch(FetchDescriptor<Exercise>())
        let benchAfter = try XCTUnwrap(after.first { $0.id == "ex-bf3245ad" })
        XCTAssertEqual(benchAfter.movementPattern, .core, "手改过的分类被覆盖了")
        XCTAssertEqual(benchAfter.nameZh, "教練自己改的名字")
    }

    // MARK: - 合并教练自己建的重复行

    func testFoldsTheCoachesHandTypedRowsIntoTheCanonicalOnes() throws {
        let context = try emptyContext()
        let handTyped = insertCoachTypedExercise(named: "反向蝴蝶机展肩", into: context)
        let handTypedID = handTyped.id
        let entry = attachEntry(to: handTyped, in: context)
        try context.save()
        // 必须在 save 之后取：save 之前拿到的是临时 PersistentIdentifier，
        // 存盘后会被换成永久 id，再拿旧的去 `context.model(for:)` 会直接 trap
        // （"This model instance was invalidated..."），而不是返回 nil。
        let entryID = entry.persistentModelID

        try SeedImporter.applyExerciseLibraryAdditions20260904(seedURL: try seedURL(), context: context)

        let after = try context.fetch(FetchDescriptor<Exercise>())
        XCTAssertNil(after.first { $0.id == handTypedID }, "教练手建的重复行应该被合并掉")

        let canonical = try XCTUnwrap(after.first { $0.id == "ex-d134356d" })
        XCTAssertEqual(canonical.entries?.count ?? 0, 1, "历史记录必须搬到正式行上，而不是跟着被删")

        // 记录本身还在，且指向的是新的正式动作。
        let movedEntry = try XCTUnwrap(context.model(for: entryID) as? ExerciseEntry)
        XCTAssertEqual(movedEntry.exercise?.id, "ex-d134356d")
        XCTAssertEqual(movedEntry.exerciseIdRef, "ex-d134356d")
    }

    /// 2026-09-07 审阅 B04 (实验确认): a template built from the coach's
    /// hand-typed duplicate must have its slot redirected onto the
    /// canonical row too, not just the exercise's own `ExerciseEntry`
    /// history -- `TemplateExerciseSlot.exerciseID` is a plain `String`
    /// with no relationship SwiftData could ever fix up on its own.
    func testFoldsTemplateSlotReferenceOntoCanonicalRow() throws {
        let context = try emptyContext()
        let handTyped = insertCoachTypedExercise(named: "坐姿面拉", into: context)
        let handTypedID = handTyped.id

        let template = SessionTemplate(id: "tpl-test", name: "測試模板", order: 0)
        context.insert(template)
        let block = TemplateBlock(id: "tpl-test-block0", order: 0, blockType: .single, restSeconds: 60)
        block.template = template
        context.insert(block)
        let slot = TemplateExerciseSlot(id: "tpl-test-block0-slot0", order: 0, exerciseID: handTypedID, defaultSets: 3, defaultRepTarget: .fixed(value: 10, raw: "10"))
        slot.block = block
        context.insert(slot)
        try context.save()
        let slotID = slot.persistentModelID

        try SeedImporter.applyExerciseLibraryAdditions20260904(seedURL: try seedURL(), context: context)

        let after = try context.fetch(FetchDescriptor<Exercise>())
        XCTAssertNil(after.first { $0.id == handTypedID }, "手建的重复行应该被合并掉")

        let survivingSlot = try XCTUnwrap(context.model(for: slotID) as? TemplateExerciseSlot)
        XCTAssertEqual(survivingSlot.exerciseID, "ex-f68651c5", "模板引用必须跟着重定向到正式行，不能悬空指向已删除的 id")
    }

    func testFoldsBothHandTypedRowsIncludingTheTraditionalSpelling() throws {
        let context = try emptyContext()
        insertCoachTypedExercise(named: "反向蝴蝶機展肩", into: context)   // 繁体
        insertCoachTypedExercise(named: " 坐姿面拉 ", into: context)       // 前后带空格
        try context.save()

        try SeedImporter.applyExerciseLibraryAdditions20260904(seedURL: try seedURL(), context: context)

        let after = try context.fetch(FetchDescriptor<Exercise>())
        XCTAssertTrue(after.filter { $0.id.hasPrefix("ex-local-") }.isEmpty, "两行都该被合并掉")
        XCTAssertEqual(after.filter { $0.movementPattern == .pull && $0.nameZh == "坐姿繩索臉拉" }.count, 1)
    }

    /// 名字对不上的自建动作绝对不能被顺手吞掉——宁可让教练在动作库里看到两行
    /// 自己合并，也不能猜。
    func testLeavesUnrelatedCoachExercisesAlone() throws {
        let context = try emptyContext()
        insertCoachTypedExercise(named: "反向蝴蝶机展肩（左手）", into: context)
        insertCoachTypedExercise(named: "站姿面拉", into: context)
        try context.save()

        try SeedImporter.applyExerciseLibraryAdditions20260904(seedURL: try seedURL(), context: context)

        let after = try context.fetch(FetchDescriptor<Exercise>())
        let survivors = after.filter { $0.id.hasPrefix("ex-local-") }.map(\.canonicalName).sorted()
        XCTAssertEqual(survivors, ["反向蝴蝶机展肩（左手）", "站姿面拉"])
    }

    /// 只吃 `ex-local-` 前缀的行。种子库里的正式行即使名字撞上别名，也不能被
    /// 当成重复行删掉。
    func testNeverSwallowsACanonicalSeedRow() throws {
        let context = try emptyContext()
        _ = try SeedImporter.importSeed(from: try seedURL(), into: context)
        let before = try context.fetchCount(FetchDescriptor<Exercise>())

        try SeedImporter.applyExerciseLibraryAdditions20260904(seedURL: try seedURL(), context: context)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Exercise>()), before)
        // 同名的既有繩索臉拉不该被当成"坐姿繩索臉拉"的重复行。
        let after = try context.fetch(FetchDescriptor<Exercise>())
        XCTAssertNotNil(after.first { $0.id == "ex-c49fa9b5" }, "Cable facepull 必须还在")
    }

    // MARK: - 幂等

    func testIsIdempotent() throws {
        let context = try emptyContext()
        insertCoachTypedExercise(named: "坐姿面拉", into: context)
        try context.save()

        let url = try seedURL()
        XCTAssertEqual(try SeedImporter.applyExerciseLibraryAdditions20260904(seedURL: url, context: context), 2)
        let countAfterFirst = try context.fetchCount(FetchDescriptor<Exercise>())

        XCTAssertEqual(try SeedImporter.applyExerciseLibraryAdditions20260904(seedURL: url, context: context), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Exercise>()), countAfterFirst)
    }

    /// 全新安装本来就通过 `importFixtureIfNeeded` 拿到了这两行，这个迁移在它
    /// 上面跑一遍必须是纯粹的空操作。
    func testIsANoOpOnAFreshInstall() throws {
        let context = try emptyContext()
        _ = try SeedImporter.importSeed(from: try seedURL(), into: context)
        let before = try context.fetchCount(FetchDescriptor<Exercise>())

        XCTAssertEqual(try SeedImporter.applyExerciseLibraryAdditions20260904(seedURL: try seedURL(), context: context), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Exercise>()), before)
    }
}
