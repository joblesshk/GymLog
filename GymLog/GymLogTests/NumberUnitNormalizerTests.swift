import XCTest
@testable import GymLogKit

/// P3/M3a (2026-09-12)：中文數字、簡繁/同義詞折疊、負重與數量單位解析——
/// `VoiceCommandParser` 的每一個數字/單位判斷都經過這裡，錯了會連帶影響所有
/// 6 種語音命令。
final class NumberUnitNormalizerTests: XCTestCase {

    // MARK: - 中文數字

    func testParsesSimpleDigitsAndTens() {
        XCTAssertEqual(NumberUnitNormalizer.parseChineseNumeral("一"), 1)
        XCTAssertEqual(NumberUnitNormalizer.parseChineseNumeral("九"), 9)
        XCTAssertEqual(NumberUnitNormalizer.parseChineseNumeral("十"), 10)
        XCTAssertEqual(NumberUnitNormalizer.parseChineseNumeral("十一"), 11)
        XCTAssertEqual(NumberUnitNormalizer.parseChineseNumeral("二十"), 20)
        XCTAssertEqual(NumberUnitNormalizer.parseChineseNumeral("二十三"), 23)
        XCTAssertEqual(NumberUnitNormalizer.parseChineseNumeral("九十九"), 99)
    }

    func testParsesHundredsAndThousands() {
        XCTAssertEqual(NumberUnitNormalizer.parseChineseNumeral("一百"), 100)
        XCTAssertEqual(NumberUnitNormalizer.parseChineseNumeral("一百二十"), 120)
        XCTAssertEqual(NumberUnitNormalizer.parseChineseNumeral("一百二十三"), 123)
        XCTAssertEqual(NumberUnitNormalizer.parseChineseNumeral("一千二百三十四"), 1234)
    }

    func testParsesArabicDigitsDirectly() {
        XCTAssertEqual(NumberUnitNormalizer.parseChineseNumeral("40"), 40)
        XCTAssertEqual(NumberUnitNormalizer.parseChineseNumeral("8"), 8)
    }

    func testRejectsNonNumeralCharacters() {
        XCTAssertNil(NumberUnitNormalizer.parseChineseNumeral("深蹲"))
        XCTAssertNil(NumberUnitNormalizer.parseChineseNumeral(""))
    }

    // MARK: - 從句子裡按單位詞取出對應的數字，不受其他數字干擾

    func testNumberImmediatelyBeforeSkipsOccurrenceWithoutANumberPrefix() {
        // 「每組」前面沒有數字，必須跳過去找「三組」。
        let result = NumberUnitNormalizer.numberImmediatelyBefore("組", in: "三組，每組十次")
        XCTAssertEqual(result?.value, 3)
    }

    func testNumberImmediatelyBeforeReturnsNilWhenKeywordAbsent() {
        XCTAssertNil(NumberUnitNormalizer.numberImmediatelyBefore("秒", in: "三組十次"))
    }

    // MARK: - 簡繁/同義詞折疊

    func testFoldSynonymsNormalizesSimplifiedToTraditional() {
        XCTAssertEqual(NumberUnitNormalizer.foldSynonyms("三组"), "三組")
        XCTAssertEqual(NumberUnitNormalizer.foldSynonyms("超级组"), "超級組")
        XCTAssertEqual(NumberUnitNormalizer.foldSynonyms("撤销刚才的修改"), "撤銷剛才的修改")
        XCTAssertEqual(NumberUnitNormalizer.foldSynonyms("实际次数改为八次"), "實際次數改為八次")
    }

    /// 計劃書 §6.2 原文例子本身就是簡體："把卧推第二组实际次数改为八次"
    /// ——動作名稱「卧推」也得折成「臥推」才能對上動作庫（Traditional），
    /// 不能只折語法關鍵詞、放過動作名稱本身。
    func testFoldSynonymsAlsoNormalizesExerciseNamesNotJustGrammarKeywords() {
        XCTAssertEqual(NumberUnitNormalizer.foldSynonyms("卧推"), "臥推")
        XCTAssertEqual(NumberUnitNormalizer.foldSynonyms("深蹲"), "深蹲", "已經是繁體的動作名稱不受影響")
    }

    // MARK: - 負重解析

    func testParseLoadAbsoluteKg() {
        guard let load = NumberUnitNormalizer.parseLoad("四十公斤") else { return XCTFail() }
        XCTAssertEqual(load, .absolute(kg: 40, raw: "四十公斤"))
    }

    func testParseLoadConvertsLbToKg() {
        guard let load = NumberUnitNormalizer.parseLoad("一百磅"), case .absolute(let kg, _) = load else { return XCTFail() }
        XCTAssertEqual(kg, 45.36, accuracy: 0.01)
    }

    func testParseLoadPerSide() {
        guard let load = NumberUnitNormalizer.parseLoad("每邊二十公斤") else { return XCTFail() }
        XCTAssertEqual(load, .perSide(kg: 20, raw: "每邊二十公斤"))
    }

    func testParseLoadReturnsNilWithoutRecognizedUnit() {
        XCTAssertNil(NumberUnitNormalizer.parseLoad("四十"), "沒有單位詞時不能猜是公斤還是磅")
    }

    // MARK: - 數量解析：單位跟記錄方式不匹配時拒絕，不猜

    func testParseQuantityReps() {
        XCTAssertEqual(NumberUnitNormalizer.parseQuantity("十次", metric: .reps), 10)
    }

    func testParseQuantityTimeConvertsMinutesToSeconds() {
        XCTAssertEqual(NumberUnitNormalizer.parseQuantity("兩分鐘", metric: .time), 120)
        XCTAssertEqual(NumberUnitNormalizer.parseQuantity("三十秒", metric: .time), 30)
    }

    func testParseQuantityDistanceConvertsKmToMeters() {
        XCTAssertEqual(NumberUnitNormalizer.parseQuantity("一公里", metric: .distance), 1000)
        XCTAssertEqual(NumberUnitNormalizer.parseQuantity("五百米", metric: .distance), 500)
    }

    func testParseQuantityRejectsWrongUnitForMetric() {
        XCTAssertNil(NumberUnitNormalizer.parseQuantity("八次", metric: .time), "reps 單位不能套用到 time 動作上")
        XCTAssertNil(NumberUnitNormalizer.parseQuantity("三十秒", metric: .reps), "time 單位不能套用到 reps 動作上")
    }

    // MARK: - parseAnyQuantity：不知道 metric 時，回報數值連同它隱含的單位

    func testParseAnyQuantityReturnsImpliedMetric() {
        let reps = NumberUnitNormalizer.parseAnyQuantity("八次")
        XCTAssertEqual(reps?.value, 8)
        XCTAssertEqual(reps?.metric, .reps)

        let time = NumberUnitNormalizer.parseAnyQuantity("三十秒")
        XCTAssertEqual(time?.value, 30)
        XCTAssertEqual(time?.metric, .time)

        let distance = NumberUnitNormalizer.parseAnyQuantity("一公里")
        XCTAssertEqual(distance?.value, 1000)
        XCTAssertEqual(distance?.metric, .distance)
    }
}
