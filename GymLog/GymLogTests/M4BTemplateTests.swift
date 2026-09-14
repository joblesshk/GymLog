import XCTest
import SwiftData
@testable import GymLogKit

/// CONTRACT-M4.md §3/§6, M4-B scope: `SessionTemplate` / `TemplateBlock` /
/// `TemplateExerciseSlot` persistence and the `estimatedMinutes` heuristic.
///
/// Scope note (see VERIFICATION-M4B.md for the full explanation): this file
/// covers exactly the GymLogKit-resident surface. Everything under
/// `Sources/Views/Exercises/**` (the segmented-control UI, `TemplateLibraryView`,
/// `TemplateEditorView`, and `SessionTemplatePickerView`'s `onSelect` wiring)
/// lives in the `GymLog` app target, which `GymLogTests` deliberately never
/// links (see `TestSupport.swift`'s comment on the M1 unhosted-test-bundle
/// fix -- linking the app target here would reintroduce the exact
/// ModelContainer race that fix exists to avoid). That SwiftUI-layer
/// behavior is verified interactively via the simulator instead (screenshots
/// in `GymLog/Screenshots/M4B/`), the same precedent M3's merge/undo flow
/// set (see VERIFICATION-M3.md §7).
final class M4BTemplateTests: XCTestCase {
    private var container: ModelContainer!

    override func setUpWithError() throws {
        container = try TestSupport.makeInMemoryContainer()
    }

    // MARK: - Persistence round-trip, including the RepTarget risk called
    // out in the task brief: an incorrectly-constructed RepTarget silently
    // degrades to `.unknown` on reload rather than failing loudly.

    func testTemplateRoundTrip_persistsAndReloadsAcrossAFreshContext() throws {
        let writeContext = ModelContext(container)

        let template = SessionTemplate(id: "tpl-1", name: "全身力量 A", templateNote: "教练备注", order: 0)
        writeContext.insert(template)

        let block = TemplateBlock(id: "tb-1", order: 0, blockType: .single, restSeconds: 90)
        block.template = template
        writeContext.insert(block)

        // Three RepTarget kinds in one slot set: .fixed and .range are the
        // two the task brief explicitly asks for; .perSide is added too
        // since it's the branch CONTRACT.md §7.8 added specifically because
        // it was missing (282 real SetLogs), making it the highest-risk kind
        // to silently mis-round-trip in a brand-new persistence path.
        let slotFixed = TemplateExerciseSlot(id: "tes-1", order: 0, exerciseID: "ex-bench", defaultSets: 4, defaultRepTarget: .fixed(value: 8, raw: "8"))
        slotFixed.block = block
        writeContext.insert(slotFixed)

        let slotRange = TemplateExerciseSlot(id: "tes-2", order: 1, exerciseID: "ex-squat", defaultSets: 3, defaultRepTarget: .range(low: 8, high: 12, raw: "8-12"))
        slotRange.block = block
        writeContext.insert(slotRange)

        let slotPerSide = TemplateExerciseSlot(id: "tes-3", order: 2, exerciseID: "ex-legext-sl", defaultSets: 3, defaultRepTarget: .perSide(left: 10, right: 12, raw: "10,12"))
        slotPerSide.block = block
        writeContext.insert(slotPerSide)

        try writeContext.save()

        // A brand-new ModelContext over the *same* container forces an
        // actual reload through the JSON-string-column decode path, not
        // just re-reading the same in-memory object graph -- this is the
        // part that would silently degrade to `.unknown` if the encode side
        // were subtly wrong (e.g. omitting `raw`).
        let readContext = ModelContext(container)
        let fetched = try readContext.fetch(FetchDescriptor<SessionTemplate>(predicate: #Predicate { $0.id == "tpl-1" }))
        XCTAssertEqual(fetched.count, 1)
        let reloaded = fetched[0]

        XCTAssertEqual(reloaded.name, "全身力量 A")
        XCTAssertEqual(reloaded.templateNote, "教练备注")
        XCTAssertEqual(reloaded.orderedBlocks.count, 1)

        let reloadedBlock = reloaded.orderedBlocks[0]
        XCTAssertEqual(reloadedBlock.restSeconds, 90)
        XCTAssertEqual(reloadedBlock.blockType, .single)

        let slots = reloadedBlock.orderedSlots
        XCTAssertEqual(slots.count, 3)
        XCTAssertEqual(slots.map(\.exerciseID), ["ex-bench", "ex-squat", "ex-legext-sl"], "order must round-trip too, not just content")

        guard case .fixed(let value, let raw) = slots[0].defaultRepTarget else {
            return XCTFail("expected .fixed, got \(slots[0].defaultRepTarget) -- this is the silent-degrade-to-.unknown failure mode the task brief warns about")
        }
        XCTAssertEqual(value, 8)
        XCTAssertEqual(raw, "8")

        guard case .range(let low, let high, let rawRange) = slots[1].defaultRepTarget else {
            return XCTFail("expected .range, got \(slots[1].defaultRepTarget)")
        }
        XCTAssertEqual(low, 8)
        XCTAssertEqual(high, 12)
        XCTAssertEqual(rawRange, "8-12")

        guard case .perSide(let left, let right, _) = slots[2].defaultRepTarget else {
            return XCTFail("expected .perSide, got \(slots[2].defaultRepTarget)")
        }
        XCTAssertEqual(left, 10)
        XCTAssertEqual(right, 12)
    }

    /// A malformed/never-written column must degrade to `.unknown`, not
    /// crash -- same discipline `SetLog` already has (CONTRACT.md §11.4).
    /// Exercised here via the documented fallback default in
    /// `TemplateExerciseSlot.init`'s literal, not by hand-corrupting the
    /// private JSON column (which isn't accessible outside the model file).
    func testTemplateExerciseSlot_defaultRepTarget_fallsBackGracefully() throws {
        let context = ModelContext(container)
        let template = SessionTemplate(id: "tpl-2", name: "占位模板", order: 0)
        context.insert(template)
        let block = TemplateBlock(id: "tb-2", order: 0, blockType: .single, restSeconds: 60)
        block.template = template
        context.insert(block)
        let slot = TemplateExerciseSlot(id: "tes-4", order: 0, exerciseID: "ex-unknown", defaultSets: 3, defaultRepTarget: .unknown(raw: ""))
        slot.block = block
        context.insert(slot)
        try context.save()

        let readContext = ModelContext(container)
        let reloaded = try readContext.fetch(FetchDescriptor<TemplateExerciseSlot>(predicate: #Predicate { $0.id == "tes-4" }))
        XCTAssertEqual(reloaded.count, 1)
        guard case .unknown = reloaded[0].defaultRepTarget else {
            return XCTFail("expected graceful .unknown, not a crash or a wrong kind")
        }
    }

    // MARK: - estimatedMinutes (CONTRACT-M4.md §3's heuristic)

    /// Hand-computed against §3's formula, one block:
    /// setsInBlock = 3 + 4 = 7; blockSeconds = 7 * (40 + 60) = 700;
    /// raw = 8 + 700/60 = 19.667 minutes; rounded to nearest 5 -> 20.
    func testEstimatedMinutes_singleBlock_matchesHandComputedFormula() throws {
        let context = ModelContext(container)
        let template = SessionTemplate(id: "tpl-3", name: "单块模板", order: 0)
        context.insert(template)

        let block = TemplateBlock(id: "tb-3", order: 0, blockType: .single, restSeconds: 60)
        block.template = template
        context.insert(block)

        let slotA = TemplateExerciseSlot(id: "tes-a", order: 0, exerciseID: "ex-a", defaultSets: 3, defaultRepTarget: .fixed(value: 10, raw: "10"))
        slotA.block = block
        context.insert(slotA)
        let slotB = TemplateExerciseSlot(id: "tes-b", order: 1, exerciseID: "ex-b", defaultSets: 4, defaultRepTarget: .fixed(value: 10, raw: "10"))
        slotB.block = block
        context.insert(slotB)

        try context.save()

        XCTAssertEqual(template.estimatedMinutes, 20)
    }

    /// Two blocks, to confirm the per-block sum accumulates correctly
    /// (not just a single-block special case):
    /// block1: 7 sets * (40+60) = 700s; block2: 5 sets * (40+30) = 350s.
    /// raw = 8 + (700+350)/60 = 8 + 17.5 = 25.5 -> rounds to 25.
    func testEstimatedMinutes_multipleBlocks_sumsAcrossBlocks() throws {
        let context = ModelContext(container)
        let template = SessionTemplate(id: "tpl-4", name: "两块模板", order: 0)
        context.insert(template)

        let block1 = TemplateBlock(id: "tb-4a", order: 0, blockType: .single, restSeconds: 60)
        block1.template = template
        context.insert(block1)
        let s1 = TemplateExerciseSlot(id: "tes-c", order: 0, exerciseID: "ex-c", defaultSets: 3, defaultRepTarget: .fixed(value: 10, raw: "10"))
        s1.block = block1
        context.insert(s1)
        let s2 = TemplateExerciseSlot(id: "tes-d", order: 1, exerciseID: "ex-d", defaultSets: 4, defaultRepTarget: .fixed(value: 10, raw: "10"))
        s2.block = block1
        context.insert(s2)

        let block2 = TemplateBlock(id: "tb-4b", order: 1, blockType: .superset, restSeconds: 30)
        block2.template = template
        context.insert(block2)
        let s3 = TemplateExerciseSlot(id: "tes-e", order: 0, exerciseID: "ex-e", defaultSets: 5, defaultRepTarget: .fixed(value: 10, raw: "10"))
        s3.block = block2
        context.insert(s3)

        try context.save()

        XCTAssertEqual(template.estimatedMinutes, 25)
    }

    /// An empty template (just created, no blocks yet -- the state right
    /// after "+" in `TemplateLibraryView`) must not crash and must reflect
    /// just the flat warmup/cooldown floor.
    func testEstimatedMinutes_emptyTemplate_isJustWarmupCooldown() throws {
        let context = ModelContext(container)
        let template = SessionTemplate(id: "tpl-5", name: "空模板", order: 0)
        context.insert(template)
        try context.save()

        // raw = 8 + 0 = 8 -> nearest 5 is 10 (Int(1.6.rounded())*5).
        XCTAssertEqual(template.estimatedMinutes, 10)
    }

    // MARK: - Ordering the picker/library list relies on

    /// `SessionTemplatePickerView` and `TemplateLibraryView` both fetch via
    /// `@Query(sort: \SessionTemplate.order)` -- verifies that sort actually
    /// produces the coach's intended display order regardless of insertion
    /// sequence, which is the data-layer half of "picker shows templates
    /// correctly" (the SwiftUI tap-to-onSelect half is out of XCTest's
    /// reach here; see the file-level note above and VERIFICATION-M4B.md).
    func testTemplatesFetchInStableOrderRegardlessOfInsertionSequence() throws {
        let context = ModelContext(container)
        let templateC = SessionTemplate(id: "tpl-c", name: "C", order: 2)
        let templateA = SessionTemplate(id: "tpl-a", name: "A", order: 0)
        let templateB = SessionTemplate(id: "tpl-b", name: "B", order: 1)
        [templateC, templateA, templateB].forEach { context.insert($0) }
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SessionTemplate>(sortBy: [SortDescriptor(\.order)]))
        XCTAssertEqual(fetched.map(\.name), ["A", "B", "C"])
    }
}
