import XCTest
@testable import GymLogKit

/// P3/M3a (2026-09-12)：執行Prompt與實施計劃.md §6.3 要求的「至少建立 60 條
/// 中文/混合動作名測試語料」——這裡只斷言解析結果的**類別**（識別成哪種
/// 命令 / 需要澄清 / 拒絕），不深入到每個欄位的精確值（那是
/// `VoiceCommandParserTests.swift`/`VoiceCommandServiceTests.swift` 的範圍），
/// 因為 M3a 本來就沒有真實錄音，文字解析與真實語音端到端結果本來就要分開
/// 報告。
final class VoiceCommandParserCorpusTests: XCTestCase {

    private enum ExpectedCategory: Equatable {
        case addExercise, replaceExercise, setPlan, setActual, setSupersetRest, undo
        case clarification
        case rejected
    }

    private static let corpus: [(utterance: String, expected: ExpectedCategory)] = [
        // MARK: 添加庫內動作
        ("添加深蹲，三组，每组十次，四十公斤", .addExercise),
        ("添加臥推三組十次四十公斤", .addExercise),
        ("加入硬舉，五組，每組五次，一百公斤", .addExercise),
        ("新增啞鈴划船，三組，每組十二次", .addExercise),
        ("添加平板支撐三十秒", .addExercise),
        ("添加划船機五百米", .addExercise),
        ("加入農夫走路兩分鐘", .addExercise),
        ("添加深蹲每邊二十公斤", .addExercise),
        ("新增肩推三組八次二十公斤", .addExercise),
        ("加入引體向上三組八次", .addExercise),
        ("添加深蹲，三组，每组十次，四十公斤，感謝", .addExercise),
        ("添加，三組十次", .clarification),
        ("加入", .clarification),

        // MARK: 替換指定動作
        ("把臥推換成啞鈴臥推", .replaceExercise),
        ("把深蹲換成箭步蹲", .replaceExercise),
        ("把第一個動作換成硬舉", .replaceExercise),
        ("把第二個動作換為划船", .replaceExercise),
        ("臥推替換成上斜臥推", .replaceExercise),
        ("硬舉替換為羅馬尼亞硬舉", .replaceExercise),
        ("把肩推換成阿諾德推舉", .replaceExercise),
        ("把臥推換成", .clarification),
        ("換成硬舉", .clarification),

        // MARK: 設置計劃組數/目標/重量
        ("把臥推改成三組十二次", .setPlan),
        ("臥推改成五十公斤", .setPlan),
        ("把深蹲設置成四組八次六十公斤", .setPlan),
        ("硬舉改為五組五次一百公斤", .setPlan),
        ("把肩推調整成三組十次", .setPlan),
        ("把平板支撐計劃改成四十五秒", .setPlan),
        ("划船機計劃改成八百米", .setPlan),
        ("把臥推變成三組十次", .setPlan),
        ("把深蹲組數改成四組", .setPlan),
        ("把臥推調整一下", .clarification),
        ("設置一下", .clarification),

        // MARK: 修改指定組的實際次數/時間/距離
        ("把卧推第二组实际次数改为八次", .setActual),
        ("把深蹲第一組實際次數改為十次", .setActual),
        ("硬舉第三組實際改為五次", .setActual),
        ("把平板支撐第一組實際時間改為四十秒", .setActual),
        ("划船機第二組實際距離改為四百米", .setActual),
        ("臥推第二組實際次數十次", .setActual),
        ("把深蹲第四組完成了八次", .setActual),
        ("硬舉第一組做了五次", .setActual),
        ("把肩推第二組結果是六次", .setActual),
        ("把臥推實際次數改為八次", .clarification),
        ("第二組實際次數改為八次", .clarification),

        // MARK: 設置 Superset 輪間休息
        ("把第一个超级组的休息改为九十秒", .setSupersetRest),
        ("把第二個超級組休息改成六十秒", .setSupersetRest),
        ("超級組休息改為一百二十秒", .setSupersetRest),
        ("把超級組的休息設置成九十秒", .setSupersetRest),
        ("把第一個超級組休息調整為四十五秒", .setSupersetRest),
        ("把超級組的休息改一下", .clarification),
        ("超級組休息", .clarification),

        // MARK: 撤銷上一條語音操作
        ("撤銷剛才的修改", .undo),
        ("撤销", .undo),
        ("撤回上一次", .undo),
        ("撤銷上一條指令", .undo),
        ("撤銷", .undo),

        // MARK: 背景對話/雜訊/單位錯誤（拒絕，不是澄清——沒有任何語法標記）
        ("今天天氣真好", .rejected),
        ("你好啊", .rejected),
        ("等一下我喝口水", .rejected),
        ("這個動作有點難", .rejected),
        ("嗯……那個……", .rejected),
        ("教練我們休息一下聊聊天", .rejected),
        ("", .rejected),
        ("   ", .rejected),
        ("random background noise transcription", .rejected),
        ("笑死我了", .rejected),
    ]

    func testCorpusParsesIntoExpectedCategory() {
        XCTAssertGreaterThanOrEqual(Self.corpus.count, 60, "計劃書§6.3 要求至少 60 條語料")

        var failures: [String] = []
        for (utterance, expected) in Self.corpus {
            let actual = category(for: VoiceCommandParser.parse(utterance))
            if actual != expected {
                failures.append("\"\(utterance)\": 預期 \(expected)，實際 \(actual)")
            }
        }
        XCTAssertTrue(failures.isEmpty, "語料解析結果跟預期不符：\n" + failures.joined(separator: "\n"))
    }

    private func category(for result: VoiceCommandParseResult) -> ExpectedCategory {
        switch result {
        case .recognized(let kind):
            switch kind {
            case .addExercise: return .addExercise
            case .replaceExercise: return .replaceExercise
            case .setPlan: return .setPlan
            case .setActual: return .setActual
            case .setSupersetRest: return .setSupersetRest
            case .undoLastVoiceCommand: return .undo
            }
        case .needsClarification:
            return .clarification
        case .rejected:
            return .rejected
        }
    }
}
