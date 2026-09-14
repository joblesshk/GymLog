import XCTest
@testable import GymLogKit

/// 2026-09-13 全局語音改造，Apple 端側熱詞前置評測：詞庫建構＋動態熱詞
/// 子集裁剪的邏輯測試。這兩個型別本身不需要真機/真實錄音就能完全驗證
/// 正確性——真正需要真機的是「熱詞注入之後辨識準確率有沒有變化」，屬於
/// `Apple端侧热词评测.md` 裡明確標注證據不足的部分。
final class ExerciseVocabularyCatalogTests: XCTestCase {

    private func makeExercise(id: String, name: String, nameZh: String = "", aliases: [String] = []) -> Exercise {
        Exercise(
            id: id, canonicalName: name, aliases: aliases, movementPattern: .squat, equipment: .barbell,
            loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 0, needsReview: false,
            reviewReason: nil, nameZh: nameZh
        )
    }

    func testCatalogCollectsNameAliasesAndCommonPhrasesWithoutDuplicatesPerExercise() {
        let squat = makeExercise(id: "ex-squat", name: "Back Squat", nameZh: "槓鈴背蹲", aliases: ["BS", "后蹲"])
        let catalog = ExerciseVocabularyCatalog(exercises: [squat], commonPhrases: ["組", "次"])

        XCTAssertEqual(catalog.entries.count, 1)
        XCTAssertEqual(Set(catalog.entries[0].phrases), ["Back Squat", "槓鈴背蹲", "BS", "后蹲"])
        XCTAssertEqual(catalog.commonPhrases, ["組", "次"])
        XCTAssertEqual(catalog.totalPhraseCount, 4 + 2)
    }

    func testVersionChangesWhenContentChangesAndStableWhenNot() {
        let squat = makeExercise(id: "ex-squat", name: "Back Squat", nameZh: "槓鈴背蹲")
        let catalogA = ExerciseVocabularyCatalog(exercises: [squat], commonPhrases: ["組"])
        let catalogB = ExerciseVocabularyCatalog(exercises: [squat], commonPhrases: ["組"])
        XCTAssertEqual(catalogA.version, catalogB.version, "同一份動作庫內容重建兩次，版本號必須一致")

        let bench = makeExercise(id: "ex-bench", name: "Bench Press", nameZh: "臥推")
        let catalogC = ExerciseVocabularyCatalog(exercises: [squat, bench], commonPhrases: ["組"])
        XCTAssertNotEqual(catalogA.version, catalogC.version, "動作庫內容變了，版本號必須跟著變")
    }
}

final class ContextualHotwordSelectorTests: XCTestCase {

    private func makeExercise(id: String, name: String) -> Exercise {
        Exercise(
            id: id, canonicalName: name, aliases: [], movementPattern: .squat, equipment: .barbell,
            loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 0, needsReview: false, reviewReason: nil
        )
    }

    func testCurrentDraftExercisesAreAlwaysIncludedEvenWhenOverLimit() {
        // 動作庫遠超過 100 個短語的容量，仍然必須優先納入當前訓練裡的動作。
        let manyExercises = (0..<200).map { makeExercise(id: "ex-\($0)", name: "Exercise \($0)") }
        let catalog = ExerciseVocabularyCatalog(exercises: manyExercises, commonPhrases: [])
        let currentID = "ex-150"

        let selection = ContextualHotwordSelector.select(catalog: catalog, currentDraftExerciseIDs: [currentID], limit: 10)

        XCTAssertLessThanOrEqual(selection.phrases.count, 10, "不能超過 Apple 建議的單次注入上限")
        XCTAssertTrue(selection.phrases.contains("Exercise 150"), "當前訓練裡的動作必須優先納入，不能被排序在後面的動作擠掉")
    }

    func testSelectionNeverExceedsLimitEvenWithHugeCatalog() {
        let manyExercises = (0..<500).map { makeExercise(id: "ex-\($0)", name: "Exercise \($0)") }
        let catalog = ExerciseVocabularyCatalog(exercises: manyExercises, commonPhrases: ["組", "次", "公斤"])

        let selection = ContextualHotwordSelector.select(catalog: catalog, currentDraftExerciseIDs: [], limit: 100)

        XCTAssertEqual(selection.phrases.count, 100, "全庫遠超上限時，選取結果必須被裁到剛好上限")
        XCTAssertEqual(selection.totalCatalogPhraseCount, catalog.totalPhraseCount, "覆蓋率統計的分母必須是全庫詞條數，不是被裁剪後的數量")
        XCTAssertFalse(selection.uncoveredExerciseIDs.isEmpty, "全庫遠超上限時，一定有動作沒被選進這次注入，必須如實回報")
    }

    func testSelectionIsDeterministicAcrossRebuilds() {
        let exercises = (0..<30).map { makeExercise(id: "ex-\($0)", name: "Exercise \($0)") }
        let catalog = ExerciseVocabularyCatalog(exercises: exercises, commonPhrases: ["組"])

        let first = ContextualHotwordSelector.select(catalog: catalog, currentDraftExerciseIDs: ["ex-5"], limit: 10)
        let second = ContextualHotwordSelector.select(catalog: catalog, currentDraftExerciseIDs: ["ex-5"], limit: 10)

        XCTAssertEqual(first.phrases, second.phrases, "同樣的輸入必須產生同樣的選取結果，評測報告才能重現")
    }
}
