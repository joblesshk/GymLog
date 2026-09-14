import XCTest
@testable import GymLogKit

/// P3/M3a (2026-09-12)：`VoiceCommandParser` 的語法形狀——6 種命令各自能被
/// 正確識別、缺欄位時要求澄清、無法識別時拒絕，都在這裡覆蓋。純語法測試，
/// 不需要 `ModelContext`（目標/單位是否真的能對到草稿裡的東西，屬於
/// `VoiceCommandServiceTests` 的範圍）。
final class VoiceCommandParserTests: XCTestCase {

    // MARK: - 撤銷

    func testUndoRecognizedRegardlessOfQualifier() {
        XCTAssertEqual(VoiceCommandParser.parse("撤銷剛才的修改"), .recognized(.undoLastVoiceCommand))
        XCTAssertEqual(VoiceCommandParser.parse("撤销"), .recognized(.undoLastVoiceCommand))
        XCTAssertEqual(VoiceCommandParser.parse("撤回上一次"), .recognized(.undoLastVoiceCommand))
    }

    // MARK: - 添加庫內動作 (計劃書 §6.2 原文例子)

    func testAddExercisePlanCanonicalExample() {
        guard case .recognized(.addExercise(let payload)) = VoiceCommandParser.parse("添加深蹲，三组，每组十次，四十公斤") else {
            return XCTFail("應該識別成 addExercise")
        }
        XCTAssertEqual(payload.exerciseSpokenName, "深蹲")
        XCTAssertEqual(payload.setsCount, 3)
        XCTAssertEqual(payload.targetQuantity, 10)
        XCTAssertEqual(payload.spokenMetricForTargetQuantity, .reps)
        guard let load = payload.load, case .absolute(let kg, _) = load else { return XCTFail("應該解析出絕對重量") }
        XCTAssertEqual(kg, 40)
    }

    func testAddExerciseWithoutNameNeedsClarification() {
        XCTAssertEqual(VoiceCommandParser.parse("添加，三組，十次"), .needsClarification(reason: .missingExerciseName))
    }

    /// 真機測試時發現的真實回歸：口語常見的客套開場白（"請幫我"）+ "增加"
    /// （而非計劃書例句慣用的"添加"）+ 泛用量詞"一個"，三者疊加在一起
    /// 之前會整句失敗（"無法識別的指令"）——"增加"根本不在觸發詞表裡，
    /// 就算加上"增加"，原本的 `removeSubrange` 只挖掉關鍵詞本身，開場白
    /// 和量詞都會被誤當成動作名稱的一部分。
    func testAddExerciseWithConversationalPrefixAndGenericClassifier() {
        guard case .recognized(.addExercise(let payload)) = VoiceCommandParser.parse("請幫我增加一個深蹲，三組，十次") else {
            return XCTFail("應該識別成 addExercise，開場白和量詞都不應該混進動作名稱")
        }
        XCTAssertEqual(payload.exerciseSpokenName, "深蹲")
        XCTAssertEqual(payload.setsCount, 3)
        XCTAssertEqual(payload.targetQuantity, 10)
        XCTAssertEqual(payload.spokenMetricForTargetQuantity, .reps)
    }

    func testAddExerciseRecognizesZengJiaSynonymWithoutClassifier() {
        guard case .recognized(.addExercise(let payload)) = VoiceCommandParser.parse("增加臥推三組十次") else {
            return XCTFail("「增加」應該跟「添加/加入/新增」一樣被識別")
        }
        XCTAssertEqual(payload.exerciseSpokenName, "臥推")
    }

    // MARK: - 修改指定組的實際成績 (計劃書 §6.2 原文例子)

    func testSetActualCanonicalExample() {
        guard case .recognized(.setActual(let payload)) = VoiceCommandParser.parse("把卧推第二组实际次数改为八次") else {
            return XCTFail("應該識別成 setActual")
        }
        XCTAssertEqual(payload.target.spokenName, "臥推")
        XCTAssertEqual(payload.physicalSetIndex, 2)
        XCTAssertEqual(payload.actualQuantity, 8)
        XCTAssertEqual(payload.spokenMetric, .reps)
    }

    func testSetActualWithoutSetIndexNeedsClarification() {
        XCTAssertEqual(VoiceCommandParser.parse("把臥推實際次數改為八次"), .needsClarification(reason: .missingSetIndex))
    }

    // MARK: - 設置 Superset 輪間休息 (計劃書 §6.2 原文例子)

    func testSetSupersetRestCanonicalExample() {
        guard case .recognized(.setSupersetRest(let payload)) = VoiceCommandParser.parse("把第一个超级组的休息改为九十秒") else {
            return XCTFail("應該識別成 setSupersetRest")
        }
        XCTAssertEqual(payload.supersetOrdinal, 1)
        XCTAssertEqual(payload.restSeconds, 90)
    }

    func testSetSupersetRestWithoutSecondsNeedsClarification() {
        XCTAssertEqual(VoiceCommandParser.parse("把超級組的休息改一下"), .needsClarification(reason: .missingQuantity))
    }

    // MARK: - 替換指定動作

    func testReplaceExerciseWithNamedTarget() {
        guard case .recognized(.replaceExercise(let payload)) = VoiceCommandParser.parse("把臥推換成啞鈴臥推") else {
            return XCTFail("應該識別成 replaceExercise")
        }
        XCTAssertEqual(payload.target.spokenName, "臥推")
        XCTAssertEqual(payload.newExerciseSpokenName, "啞鈴臥推")
    }

    func testReplaceExerciseWithOrdinalOnlyTarget() {
        guard case .recognized(.replaceExercise(let payload)) = VoiceCommandParser.parse("把第一個動作換成硬舉") else {
            return XCTFail("應該識別成 replaceExercise")
        }
        XCTAssertEqual(payload.target.occurrenceOrdinal, 1)
        XCTAssertEqual(payload.newExerciseSpokenName, "硬舉")
    }

    func testReplaceExerciseWithoutNewNameNeedsClarification() {
        XCTAssertEqual(VoiceCommandParser.parse("把臥推換成"), .needsClarification(reason: .missingExerciseName))
    }

    // MARK: - 設置計劃組數/目標/重量

    func testSetPlanWithoutActualKeywordDefaultsToPlan() {
        guard case .recognized(.setPlan(let payload)) = VoiceCommandParser.parse("把臥推改成三組十二次") else {
            return XCTFail("沒有「實際/完成了」關鍵詞時必須是 setPlan，不是 setActual")
        }
        XCTAssertEqual(payload.target.spokenName, "臥推")
        XCTAssertEqual(payload.setsCount, 3)
        XCTAssertEqual(payload.targetQuantity, 12)
    }

    func testSetPlanSetsOnlyLoad() {
        guard case .recognized(.setPlan(let payload)) = VoiceCommandParser.parse("把臥推改成五十公斤") else {
            return XCTFail()
        }
        guard let load = payload.load, case .absolute(let kg, _) = load else { return XCTFail("應該解析出絕對重量") }
        XCTAssertEqual(kg, 50)
        XCTAssertNil(payload.setsCount)
        XCTAssertNil(payload.targetQuantity)
    }

    func testSetPlanWithoutAnyQuantityNeedsClarification() {
        XCTAssertEqual(VoiceCommandParser.parse("把臥推調整一下"), .needsClarification(reason: .missingQuantity))
    }

    // MARK: - 計劃 vs 實際的關鍵詞切分

    func testActualKeywordTriggersSetActualEvenWithoutSetPrefix() {
        guard case .recognized(.setActual) = VoiceCommandParser.parse("臥推第一組實際次數十次") else {
            return XCTFail("出現「實際」關鍵詞時必須走 setActual")
        }
    }

    // MARK: - 2026-09-13 全局語音改造：否定語氣不執行添加

    func testNegatedAddIsRejectedNotSilentlyAdded() {
        guard case .rejected = VoiceCommandParser.parse("不要添加深蹲") else {
            return XCTFail("「不要添加」不能因為含有「添加」關鍵詞就照樣執行")
        }
        guard case .rejected = VoiceCommandParser.parse("唔好加深蹲") else {
            return XCTFail("粵語否定「唔好加」同樣必須拒絕")
        }
        guard case .rejected = VoiceCommandParser.parse("不用加入硬舉") else {
            return XCTFail()
        }
    }

    func testNonNegatedAddStillWorksAfterNegationFix() {
        guard case .recognized(.addExercise(let payload)) = VoiceCommandParser.parse("添加深蹲，三組，十次") else {
            return XCTFail("加入否定語氣的判斷後，正常的添加指令不能被誤傷")
        }
        XCTAssertEqual(payload.exerciseSpokenName, "深蹲")
    }

    // MARK: - 2026-09-13 全局語音改造：改口/糾正取最後一個數字

    func testCorrectionTakesLastMentionedNumber() {
        guard case .recognized(.setPlan(let payload)) = VoiceCommandParser.parse("把臥推改成四十公斤，不是，改成四十五公斤") else {
            return XCTFail("應該識別成 setPlan")
        }
        guard let load = payload.load, case .absolute(let kg, _) = load else { return XCTFail("應該解析出絕對重量") }
        XCTAssertEqual(kg, 45, "改口後應該採用最後說的那個數字，不是先說的那個")
    }

    // MARK: - 2026-09-13 真機試用反饋：開課次意圖判斷

    func testLooksLikeSessionStartRequestRecognizesCommonPhrasings() {
        XCTAssertTrue(VoiceCommandParser.looksLikeSessionStartRequest("新建空課次"))
        XCTAssertTrue(VoiceCommandParser.looksLikeSessionStartRequest("开始训练"))
        XCTAssertTrue(VoiceCommandParser.looksLikeSessionStartRequest("新建空課次，添加深蹲三組十次"))
    }

    func testLooksLikeSessionStartRequestRejectsUnrelatedText() {
        XCTAssertFalse(VoiceCommandParser.looksLikeSessionStartRequest("添加深蹲三組十次"))
        XCTAssertFalse(VoiceCommandParser.looksLikeSessionStartRequest("深蹲"))
        XCTAssertFalse(VoiceCommandParser.looksLikeSessionStartRequest(""))
    }

    // MARK: - 無法識別 / 空白輸入

    func testGarbledInputIsRejected() {
        guard case .rejected = VoiceCommandParser.parse("今天天氣真好") else {
            return XCTFail("沒有任何語法標記的句子應該被拒絕，不是猜成某個命令")
        }
    }

    func testEmptyInputIsRejected() {
        guard case .rejected = VoiceCommandParser.parse("   ") else {
            return XCTFail()
        }
    }
}
