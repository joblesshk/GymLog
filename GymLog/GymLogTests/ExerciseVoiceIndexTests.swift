import XCTest
@testable import GymLogKit

/// 2026-09-13 全局語音改造：驗證語音專用的召回層修好了源碼審閱發現的真實
/// 缺口——種子 Back Squat 的中文名「槓鈴背蹲」／別名「BS」「后蹲」都不含
/// 「深蹲」二字，「深蹲」只出現在 `notes`（"槓鈴置於背後深蹲，CrossFit常見
/// 基礎力量動作"），而 `Exercise.matches` 不搜索 `notes`——語音使用者說
/// 「深蹲」時，Back Squat 完全召回不到。
final class ExerciseVoiceIndexTests: XCTestCase {

    private func makeExercise(id: String, name: String, nameZh: String = "", aliases: [String] = [], notes: String = "") -> Exercise {
        let ex = Exercise(
            id: id, canonicalName: name, aliases: aliases, movementPattern: .squat, equipment: .barbell,
            loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 0, needsReview: false, reviewReason: nil
        )
        ex.nameZh = nameZh
        ex.notes = notes
        return ex
    }

    func testNotesOnlyMatchIsRecalledButRankedAfterNameMatches() {
        let backSquat = makeExercise(id: "ex-back-squat", name: "Back Squat", nameZh: "槓鈴背蹲", aliases: ["BS", "后蹲"], notes: "槓鈴置於背後深蹲，CrossFit常見基礎力量動作")
        let airSquat = makeExercise(id: "ex-air-squat", name: "Air Squat", nameZh: "徒手深蹲")
        let exercises = [backSquat, airSquat]

        let recalled = ExerciseVoiceIndex.recallExercises(spokenName: "深蹲", in: exercises)

        XCTAssertEqual(Set(recalled.map(\.id)), ["ex-back-squat", "ex-air-squat"], "Back Squat 必須被召回，不能因為「深蹲」只出現在 notes 就漏掉")
        XCTAssertEqual(recalled.first?.id, "ex-air-squat", "名稱/別名直接命中必須排在只靠 notes 命中的前面")
    }

    func testLibraryResolverNowFindsBackSquatViaNotes() {
        let backSquat = makeExercise(id: "ex-back-squat", name: "Back Squat", nameZh: "槓鈴背蹲", aliases: ["BS", "后蹲"], notes: "槓鈴置於背後深蹲，CrossFit常見基礎力量動作")

        // 只有一個動作、且只能靠 notes 召回時，仍然應該被找到（回報唯一
        // 匹配），不是「找不到」。
        guard case .matched(let exercise) = VoiceCommandLibraryResolver.resolve(spokenName: "深蹲", in: [backSquat]) else {
            return XCTFail("Back Squat 應該能經由 notes 被召回為唯一匹配")
        }
        XCTAssertEqual(exercise.id, "ex-back-squat")
    }

    func testNameMatchDoesNotSuppressNotesMatchIntoFalseSingleResult() {
        // 名稱命中 1 個、notes 額外命中 1 個 -- 合計 2 個，必須是 ambiguous，
        // 不能因為名稱那邊剛好只有 1 個就誤判成「唯一匹配」而漏掉 notes
        // 命中的那個候選。
        let backSquat = makeExercise(id: "ex-back-squat", name: "Back Squat", nameZh: "槓鈴背蹲", notes: "槓鈴置於背後深蹲")
        let airSquat = makeExercise(id: "ex-air-squat", name: "Air Squat", nameZh: "深蹲")

        guard case .ambiguous(let candidates) = VoiceCommandLibraryResolver.resolve(spokenName: "深蹲", in: [backSquat, airSquat]) else {
            return XCTFail("名稱命中 + notes 命中合計兩個動作，必須澄清")
        }
        XCTAssertEqual(Set(candidates.map(\.id)), ["ex-back-squat", "ex-air-squat"])
    }

    func testNoMatchAtAllIsStillNotFound() {
        let bench = makeExercise(id: "ex-bench", name: "Bench Press", nameZh: "臥推")
        guard case .notFound = VoiceCommandLibraryResolver.resolve(spokenName: "深蹲", in: [bench]) else {
            return XCTFail("完全沒有任何召回時應該是 notFound")
        }
    }

    func testLocalizedNamePairFollowsAppLanguageAndCollapsesMissingOrDuplicateNames() {
        let bilingual = makeExercise(id: "ex-back-squat", name: "Back Squat", nameZh: "槓鈴背蹲")
        XCTAssertEqual(bilingual.localizedNamePair(for: .zhHant).primary, "槓鈴背蹲")
        XCTAssertEqual(bilingual.localizedNamePair(for: .zhHant).secondary, "Back Squat")
        XCTAssertEqual(bilingual.localizedNamePair(for: .en).primary, "Back Squat")
        XCTAssertEqual(bilingual.localizedNamePair(for: .en).secondary, "槓鈴背蹲")

        let englishOnly = makeExercise(id: "ex-row", name: "Seal Row")
        XCTAssertEqual(englishOnly.localizedNamePair(for: .zhHant).primary, "Seal Row")
        XCTAssertNil(englishOnly.localizedNamePair(for: .zhHant).secondary)

        let duplicate = makeExercise(id: "ex-same", name: "Burpee", nameZh: "Burpee")
        XCTAssertEqual(duplicate.localizedNamePair(for: .en).primary, "Burpee")
        XCTAssertNil(duplicate.localizedNamePair(for: .en).secondary)
    }
}
