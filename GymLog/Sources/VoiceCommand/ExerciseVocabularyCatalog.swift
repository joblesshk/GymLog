import Foundation

/// 2026-09-13 全局語音改造，Apple 端側熱詞前置評測第一步（執行 Prompt
/// §5.2.1）：完整健身領域詞庫──覆蓋當前動作庫「全部」項目的中英文名、
/// 等價別名，加上普通話／粵語共用的訓練術語、單位詞、常見操作短語。這是
/// 全量詞庫，本身不直接餵給任何一次辨識請求（Apple `contextualStrings`
/// 建議上限 100 個短語，見 `ContextualHotwordSelector`）；全量詞庫的用途
/// 是：(1) 動態熱詞子集的來源池，(2) 未來 `SFSpeechLanguageModel` 自訂
/// 語言模型的訓練材料，(3) 覆蓋率統計的分母。
///
/// 每次動作庫增刪合併後重新從 `[Exercise]` 建構（呼叫方負責何時重建，
/// 例如動作庫頁面保存後）──不是寫死在種子檔案裡的固定列表，使用者自建
/// 動作一樣會被收進來。
public struct ExerciseVocabularyCatalog {
    public struct Entry: Equatable {
        public let exerciseID: String
        public let phrases: [String]
    }

    /// 每個動作各自的詞條（供覆蓋率統計精確到「哪個動作」）。
    public let entries: [Entry]
    /// 跟動作庫無關、兩種語言模式通用的固定訓練術語/單位詞/操作短語。
    public let commonPhrases: [String]
    public let builtAt: Date
    public let sourceExerciseCount: Int

    /// 版本標識──動作庫內容變了，這個字串就會變。用內容而非時間戳記做
    /// hash，同一份動作庫任何時候重建都得到同一個版本號，方便交付報告裡
    /// 引用「這次評測用的是詞庫版本 X」而不是每次重建都换一個新版本號。
    public var version: String {
        var hasher = Hasher()
        for entry in entries {
            hasher.combine(entry.exerciseID)
            for phrase in entry.phrases { hasher.combine(phrase) }
        }
        for phrase in commonPhrases { hasher.combine(phrase) }
        // Hasher 的輸出跨進程/跨啟動不穩定（Swift 官方文件明確說明），這裡
        // 只需要「同一次評測報告裡引用同一個穩定字串」，用內容本身算一個
        // 簡單、確定性的校驗碼取代 Hasher。
        let all = (entries.flatMap { [$0.exerciseID] + $0.phrases } + commonPhrases).sorted().joined(separator: "|")
        var checksum: UInt64 = 1469598103934665603
        for byte in all.utf8 {
            checksum ^= UInt64(byte)
            checksum = checksum &* 1099511628211
        }
        return "v\(entries.count + commonPhrases.count)-\(String(checksum, radix: 16))"
    }

    public var totalPhraseCount: Int {
        entries.reduce(commonPhrases.count) { $0 + $1.phrases.count }
    }

    /// 固定的、跟動作庫無關的訓練術語/單位詞/常見操作短語──普通話與粵語
    /// 各自的說法都收進來（同一份熱詞池，供兩種語言模式的動態子集各自
    /// 抽取，不是兩份分開維護的詞庫）。這只是首版覆蓋，不是窮舉；後續按
    /// 真實語料的錯誤分析補充。
    public static let baseCommonPhrases: [String] = [
        // 單位詞
        "組", "次", "下", "公斤", "斤", "磅", "秒", "分鐘", "米", "公里", "輪", "個",
        // 普通話常見操作短語
        "添加", "加入", "新增", "增加", "換成", "替換成", "改成", "改為", "設置",
        "調整", "撤銷", "實際", "計劃", "完成了", "做了", "休息", "超級組",
        // 2026-09-13 新增：開課次意圖（見 `VoiceCommandParser
        // .looksLikeSessionStartRequest`）——沒有進行中課次時，這幾個詞是
        // 使用者唯一能靠語音觸發的東西，理應優先進熱詞。
        "新建", "開始", "課次", "訓練", "新建空課次",
        // 粵語常見操作短語（口語，非書面轉寫）
        "加個", "換做", "改做", "唔好加", "唔使", "做咗", "嗰個", "第幾組",
        // 常見器械/訓練術語
        "槓鈴", "啞鈴", "壺鈴", "史密斯機", "繩索", "彈力帶", "自重", "徒手",
        "深蹲", "硬舉", "臥推", "划船", "推舉", "彎舉", "卷腹", "平板支撐",
    ]

    public init(exercises: [Exercise], commonPhrases: [String] = ExerciseVocabularyCatalog.baseCommonPhrases, builtAt: Date = Date()) {
        self.entries = exercises.map { exercise in
            var phrases: Set<String> = []
            if !exercise.canonicalName.isEmpty { phrases.insert(exercise.canonicalName) }
            if !exercise.nameZh.isEmpty { phrases.insert(exercise.nameZh) }
            for alias in exercise.aliases where !alias.isEmpty { phrases.insert(alias) }
            return Entry(exerciseID: exercise.id, phrases: Array(phrases).sorted())
        }
        self.commonPhrases = commonPhrases
        self.builtAt = builtAt
        self.sourceExerciseCount = exercises.count
    }

    /// 全部詞條攤平成一個陣列（動作詞條 + 通用詞條），供
    /// `ContextualHotwordSelector` 當抽取來源池、或供未來自訂語言模型當
    /// 訓練材料清單。不去重跨動作重複的別名（例如兩個動作剛好共用一個
    /// 別名字串），去重交給消費端依需要決定。
    public var allPhrases: [String] {
        entries.flatMap(\.phrases) + commonPhrases
    }
}
