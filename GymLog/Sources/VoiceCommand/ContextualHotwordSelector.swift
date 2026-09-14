import Foundation

/// 2026-09-13 全局語音改造，Apple 端側熱詞前置評測（執行 Prompt §5.2.1）：
/// 把 `ExerciseVocabularyCatalog` 的全量詞庫，按「當前訓練、用戶常用動作、
/// 選擇的語言模式與易錯詞」裁成一次請求可用的動態子集──Apple 官方文件
/// 對 `SFSpeechRecognitionRequest.contextualStrings` 的建議上限是 100 個
/// 短語，全量塞進去不是「已生效的熱詞注入」，只是超過供應商建議上限、
/// 效果無法保證的做法。
///
/// 選取優先序（高到低）：
/// 1. 當前訓練草稿裡已經有的動作──使用者這節課最可能接著念的名字。
/// 2. 該學員的常用動作（呼叫方傳入，例如 `FrequencyAnalyzer.frequentExercises`
///    的結果）。
/// 3. 已知易錯詞（呼叫方按錯誤分析持續補充，首版先給空清單，不假造）。
/// 4. 通用單位詞/操作短語（`ExerciseVocabularyCatalog.commonPhrases`）──
///    這些幾乎每一句命令都會用到，優先於「隨便排序的其餘動作庫」。
/// 剩餘名額才輪到全庫其餘動作按字典序遞補，直到達到 `limit`──不是「按
/// 正確答案反向挑選熱詞」（那樣的評測毫無意義），也不是「只取字典前
/// N 項」（執行 Prompt 明確點名的兩個反例）。
public enum ContextualHotwordSelector {
    /// 每次注入結果連同覆蓋率統計一起回報，交付報告用得到（執行 Prompt
    /// §5.2.1：「給出全庫條目與單請求注入的覆蓋統計」）。
    public struct Selection {
        public let phrases: [String]
        public let totalCatalogPhraseCount: Int
        public let uncoveredExerciseIDs: [String]

        public var injectedCount: Int { phrases.count }
    }

    public static let defaultLimit = 100

    public static func select(
        catalog: ExerciseVocabularyCatalog,
        currentDraftExerciseIDs: [String],
        frequentExerciseIDs: [String] = [],
        knownTrickyPhrases: [String] = [],
        limit: Int = ContextualHotwordSelector.defaultLimit
    ) -> Selection {
        var chosen: [String] = []
        var chosenSet: Set<String> = []
        func add(_ phrase: String) {
            guard !phrase.isEmpty, !chosenSet.contains(phrase), chosen.count < limit else { return }
            chosen.append(phrase)
            chosenSet.insert(phrase)
        }

        let entriesByID = Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.exerciseID, $0) })
        var coveredExerciseIDs: Set<String> = []

        func addExercise(_ id: String) {
            guard let entry = entriesByID[id] else { return }
            for phrase in entry.phrases { add(phrase) }
            if entry.phrases.contains(where: { chosenSet.contains($0) }) { coveredExerciseIDs.insert(id) }
        }

        for id in currentDraftExerciseIDs { addExercise(id) }
        for id in frequentExerciseIDs { addExercise(id) }
        for phrase in knownTrickyPhrases { add(phrase) }
        for phrase in catalog.commonPhrases { add(phrase) }
        // 剩餘名額按 exerciseID 字典序遞補其餘動作──確定性排序，方便
        // 評測報告重現同一次選取結果，不是「隨機」或「插入順序」這種每次
        // 重建都不一樣的排序。
        for entry in catalog.entries.sorted(by: { $0.exerciseID < $1.exerciseID }) where !coveredExerciseIDs.contains(entry.exerciseID) {
            addExercise(entry.exerciseID)
            if chosen.count >= limit { break }
        }

        let uncovered = catalog.entries.map(\.exerciseID).filter { !coveredExerciseIDs.contains($0) }
        return Selection(phrases: chosen, totalCatalogPhraseCount: catalog.totalPhraseCount, uncoveredExerciseIDs: uncovered)
    }
}
