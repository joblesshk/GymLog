import Foundation

/// 2026-09-13 全局語音改造：語音專用的動作召回層，疊加在 `Exercise.matches
/// (searchText:)`（全 App 每個選動作面板共用的同一條規則，`Exercise.swift`）
/// 之上，不改動那個共用函式本身──改了它會連帶影響動作庫列表、合併目標
/// 選擇器等一切既有的手動搜索行為，語音的召回缺陷不該外溢成那些地方的
/// 行為變化。
///
/// 源碼審閱發現的真實缺口（`全局語音控制方案.md` §2）：種子 Back Squat
/// 的中文名是「槓鈴背蹲」、別名是 `BS`／「后蹲」，「深蹲」只出現在
/// `notes`（"槓鈴置於背後深蹲，CrossFit常見基礎力量動作"），而
/// `Exercise.matches` 不搜索 `notes`──使用者說「深蹲」時，動作庫裡真正
/// 最常指的目標之一完全召回不到。這裡在 `matches` 之外，把 `notes` 也
/// 納入召回範圍，但只用於「排序較低的候選補充」，不讓 notes 命中蓋過
/// 名稱／別名的精確匹配。
///
/// 這不是語義向量召回──約數百個動作規模的子字串＋分層排序已經足夠
/// （執行 Prompt §5.3：「約數百動作的規模優先內存檢索，不先部署向量
/// 數據庫」）；只有這條路線被真實語料證明不足時才升級。
public enum ExerciseVoiceIndex {
    public enum MatchTier: Int, Comparable {
        /// 完整名稱／別名子字串命中──跟其他選動作面板看到的候選集合一致。
        case nameOrAlias = 0
        /// 只有 `notes`（動作簡述）命中──常見於「深蹲」這種泛用詞被某個
        /// 更精確變式的動作簡介提到，但沒有進正式別名表的情況。
        case notes = 1

        public static func < (lhs: MatchTier, rhs: MatchTier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct ScoredExercise {
        public let exercise: Exercise
        public let tier: MatchTier
    }

    /// 對 `exercises` 依照 `spokenName` 召回並排序：`nameOrAlias` 命中永遠排
    /// 在 `notes` 命中前面；同一層內維持原始（呼叫方傳入）順序，不额外
    /// 按使用頻率重排──候選集合一旦生成就必須在同一輪澄清內凍結順序
    /// （執行 Prompt §4.3「候選集在這輪澄清中凍結順序」），頻率排序留給
    /// 呼叫方在生成候選前先排好 `exercises` 本身的順序。
    public static func recall(spokenName: String, in exercises: [Exercise]) -> [ScoredExercise] {
        let q = spokenName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return exercises.map { ScoredExercise(exercise: $0, tier: .nameOrAlias) } }

        var nameHits: [Exercise] = []
        var notesHits: [Exercise] = []
        for exercise in exercises {
            if exercise.matches(searchText: spokenName) {
                nameHits.append(exercise)
            } else if exercise.notes.lowercased().contains(q) {
                notesHits.append(exercise)
            }
        }
        return nameHits.map { ScoredExercise(exercise: $0, tier: .nameOrAlias) }
            + notesHits.map { ScoredExercise(exercise: $0, tier: .notes) }
    }

    /// `recall` 的扁平版本──保留分層排序後的動作清單，不附帶 tier 資訊。
    /// `VoiceCommandLibraryResolver` 用這個取代原本單純的 `exercises.filter
    /// { $0.matches(...) }`，讓「深蹲」這類召回缺口在 addExercise／
    /// replaceExercise 兩條命令上同時修好。
    public static func recallExercises(spokenName: String, in exercises: [Exercise]) -> [Exercise] {
        recall(spokenName: spokenName, in: exercises).map(\.exercise)
    }
}
