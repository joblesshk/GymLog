import Foundation

/// Why a raw utterance couldn't be turned directly into a `VoiceCommandKind`
/// -- surfaced to the UI as a clarification prompt, never silently guessed.
public enum ClarificationReason: Equatable {
    case missingExerciseName
    case missingSetIndex
    case missingQuantity
    case noReliableContext
}

public enum VoiceCommandParseResult: Equatable {
    case recognized(VoiceCommandKind)
    case needsClarification(reason: ClarificationReason)
    case rejected(reason: String)
}

/// P3/M3a (2026-09-12): hand-written rule-based grammar (執行Prompt與實施計劃
/// .md §6.1: "首版用本地受限語法/同義詞/數字與單位歸一化") -- keyword/pattern
/// spotting, NOT any NLP/ML model. Can only ever construct one of
/// `VoiceCommandKind`'s 6 whitelisted cases, or fail with
/// `.needsClarification`/`.rejected`; there is no path from here to
/// arbitrary code or database access.
///
/// Numbers are picked out by the unit word immediately next to them
/// (`NumberUnitNormalizer.numberImmediatelyBefore`), not by scan order, so a
/// sentence naming several different numbers ("三組，每組十次，四十公斤")
/// resolves each one against its own unit word correctly. Simplified/
/// traditional + a handful of synonym spellings are folded once up front
/// (`NumberUnitNormalizer.foldSynonyms`) so every keyword check below only
/// has to look for the traditional spelling.
public enum VoiceCommandParser {
    /// 2026-09-13 真機試用反饋：使用者在還沒有進行中的課次時按語音完全
    /// 沒有反應，必須先手動點「新建空課次」按鈕。開課次本身不是六種白名單
    /// 命令之一（它是建立草稿本身，不是修改已存在的草稿內容），所以獨立
    /// 於 `VoiceCommandKind`，只是一個給 `VoiceCommandCoordinator` 用的
    /// 文字判斷式——偵測到「新建/開始/新增/建立」+「課次/訓練」同時出現
    /// 就當作開課次意圖。
    public static func looksLikeSessionStartRequest(_ rawText: String) -> Bool {
        let text = NumberUnitNormalizer.foldSynonyms(rawText.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty else { return false }
        let hasStartVerb = ["新建", "開始", "新增", "建立"].contains { text.contains($0) }
        let hasSessionNoun = ["課次", "訓練", "空課"].contains { text.contains($0) }
        return hasStartVerb && hasSessionNoun
    }

    public static func parse(_ rawText: String) -> VoiceCommandParseResult {
        let text = NumberUnitNormalizer.foldSynonyms(rawText.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty else { return .rejected(reason: "空白輸入") }

        if text.contains("撤銷") {
            return .recognized(.undoLastVoiceCommand)
        }
        if let result = parseSetSupersetRest(text) {
            return result
        }
        if let result = parseReplaceExercise(text) {
            return result
        }
        if text.contains("添加") || text.contains("加入") || text.contains("新增") || text.contains("增加") {
            // 2026-09-13 全局語音改造驗收案例："不要添加深蹲"/"唔好加深蹲"
            // ──句子裡確實有"添加"這個關鍵詞，但前面帶了否定語氣，不能
            // 只因為 contains 命中就照樣執行添加。只在緊挨著加入關鍵詞的
            // 這一個場景下判斷否定，不是全句掃描任意位置的否定詞（避免
            // 誤傷"深蹲不要用槓鈴，用啞鈴，添加深蹲"這種否定詞在別處、
            // 跟添加本身無關的句子）。
            if containsNegationBeforeAddKeyword(text) {
                return .rejected(reason: "偵測到否定語氣，未執行添加")
            }
            return parseAddExercise(text)
        }

        // 沒有明確的「加入/替換/休息/撤銷」關鍵詞時，判斷是設置計劃還是修改
        // 實際成績——§6.2「默認『做三組十次』是計劃，只有明確『實際/完成了』等
        // 表達才寫實際」，在語法層直接落實，不是跑時猜。
        let isActual = containsAny(text, ["實際", "完成了", "做了", "結果"])
        if isActual {
            return parseSetActual(text)
        }
        if containsAny(text, ["組", "次", "公斤", "磅", "秒", "分鐘", "米", "公里", "改成", "改為", "設置", "調整", "變成"]) {
            return parseSetPlan(text)
        }
        return .rejected(reason: genericUnrecognizedReason)
    }

    /// `VoiceCommandService` 對照這個字串，判斷一個 `.rejected` 結果是不是
    /// 「完全沒認出任何語法」這一種——2026-09-13 真機試用反饋：使用者只是
    /// 說出一個運動名稱（沒有「添加/改成」之類的動詞），這裡目前就是走到
    /// 這一句而回報「無法識別的指令」，不能跟 `applySetPlan`/`applySetActual`
    /// 那些"語法認出來了、但單位不符/組不存在"之類另有明確原因的拒絕
    /// 混在一起用同一個容錯機制。
    public static let genericUnrecognizedReason = "無法識別的指令"

    // MARK: - 設置 Superset 輪間休息

    private static func parseSetSupersetRest(_ text: String) -> VoiceCommandParseResult? {
        guard text.contains("超級組") else { return nil }
        guard text.contains("休息") else { return nil }
        guard let (seconds, _) = NumberUnitNormalizer.numberImmediatelyBefore("秒", in: text) else {
            return .needsClarification(reason: .missingQuantity)
        }
        let ordinal = extractOrdinal(before: "個超級組", in: text) ?? extractOrdinal(before: "超級組", in: text)
        return .recognized(.setSupersetRest(SetSupersetRestPayload(supersetOrdinal: ordinal, restSeconds: seconds)))
    }

    // MARK: - 替換指定動作

    private static func parseReplaceExercise(_ text: String) -> VoiceCommandParseResult? {
        // 較長、較具體的關鍵詞排前面 -- "替換成"/"替換為" 本身就包含
        // "換成"/"換為" 作為子字串，短的排前面會把 targetPart 多吃進一個
        // "替" 字。
        let keywords = ["替換為", "替換成", "換成", "換為"]
        guard let keyword = keywords.first(where: { text.contains($0) }), let range = text.range(of: keyword) else { return nil }
        let targetPart = text[text.startIndex..<range.lowerBound]
        let newNamePart = text[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "，,。 "))
        guard !newNamePart.isEmpty else { return .needsClarification(reason: .missingExerciseName) }
        let target = extractTarget(from: targetPart)
        guard !target.spokenName.isEmpty || target.occurrenceOrdinal != nil else {
            return .needsClarification(reason: .missingExerciseName)
        }
        return .recognized(.replaceExercise(ReplaceExercisePayload(target: target, newExerciseSpokenName: newNamePart)))
    }

    // MARK: - 否定語氣（僅套用在「添加」關鍵詞前）

    private static let addKeywords = ["添加", "加入", "新增", "增加"]
    private static let negationMarkers = ["不要", "不用", "不需要", "別", "别", "唔好", "唔使", "咪"]

    private static func containsNegationBeforeAddKeyword(_ text: String) -> Bool {
        guard let keywordRange = addKeywords.compactMap({ text.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else { return false }
        let before = text[text.startIndex..<keywordRange.lowerBound]
        return negationMarkers.contains { before.contains($0) }
    }

    // MARK: - 添加庫內動作

    private static func parseAddExercise(_ text: String) -> VoiceCommandParseResult {
        var body = Substring(text)
        for keyword in ["添加", "加入", "新增", "增加"] {
            if let range = body.range(of: keyword) {
                // 只取關鍵詞之後的內容──口語常見的客套開場白（"請幫我"/
                // "麻煩"等）落在關鍵詞前面，不是動作名稱的一部分，之前用
                // `removeSubrange` 只挖掉關鍵詞本身、前後兩段接起來，開場
                // 白會被誤當成名稱的一部分。
                body = body[range.upperBound...]
                break
            }
        }
        body = stripLeadingGenericClassifier(body)
        guard let name = extractLeadingExerciseName(from: body), !name.isEmpty else {
            return .needsClarification(reason: .missingExerciseName)
        }
        let setsCount = NumberUnitNormalizer.numberImmediatelyBefore("組", in: String(body))?.value
        let load = NumberUnitNormalizer.parseLoad(body)
        let quantity = NumberUnitNormalizer.parseAnyQuantity(body)
        return .recognized(.addExercise(AddExercisePayload(
            exerciseSpokenName: name, setsCount: setsCount, targetQuantity: quantity?.value,
            spokenMetricForTargetQuantity: quantity?.metric, load: load
        )))
    }

    /// 口語常見的"增加一個/一个 XXX"這種泛用量詞開場──量詞本身不是動作
    /// 名稱的一部分。只在緊跟在關鍵詞之後、且「個」前面全部是數字/中文
    /// 數字時才剝掉，保守起見不處理「個」前面混雜其他字的情況，避免誤傷
    /// 真的以數字開頭的動作名稱。
    private static func stripLeadingGenericClassifier(_ text: Substring) -> Substring {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: "個") else { return text }
        let prefix = trimmed[trimmed.startIndex..<range.lowerBound]
        guard !prefix.isEmpty, prefix.allSatisfy({ NumberUnitNormalizer.isNumeralCharacter($0) }) else { return text }
        return trimmed[range.upperBound...]
    }

    // MARK: - 設置計劃組數/目標/重量

    private static func parseSetPlan(_ text: String) -> VoiceCommandParseResult {
        let target = extractTarget(from: Substring(text))
        guard !target.spokenName.isEmpty || target.occurrenceOrdinal != nil else {
            return .needsClarification(reason: .missingExerciseName)
        }
        let setsCount = NumberUnitNormalizer.numberImmediatelyBefore("組", in: text)?.value
        let load = NumberUnitNormalizer.parseLoad(Substring(text))
        let quantity = NumberUnitNormalizer.parseAnyQuantity(Substring(text))
        guard setsCount != nil || load != nil || quantity != nil else {
            return .needsClarification(reason: .missingQuantity)
        }
        return .recognized(.setPlan(SetPlanPayload(
            target: target, setsCount: setsCount, targetQuantity: quantity?.value,
            spokenMetricForTargetQuantity: quantity?.metric, load: load
        )))
    }

    // MARK: - 修改指定組的實際成績

    private static func parseSetActual(_ text: String) -> VoiceCommandParseResult {
        let target = extractTarget(from: Substring(text))
        guard !target.spokenName.isEmpty || target.occurrenceOrdinal != nil else {
            return .needsClarification(reason: .noReliableContext)
        }
        guard let setIndex = extractOrdinal(before: "組", in: text) ?? extractOrdinal(before: "輪", in: text) else {
            return .needsClarification(reason: .missingSetIndex)
        }
        guard let quantity = NumberUnitNormalizer.parseAnyQuantity(Substring(text)) else {
            return .needsClarification(reason: .missingQuantity)
        }
        return .recognized(.setActual(SetActualPayload(
            target: target, physicalSetIndex: setIndex, actualQuantity: quantity.value, spokenMetric: quantity.metric
        )))
    }

    // MARK: - Shared extraction helpers

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    /// "第<N>個"/"第<N>組"/"第<N>輪" -- extracts N from immediately before
    /// `suffix`, requiring "第" immediately before the numeral run (so a
    /// bare "三組" without "第" in front is never mistaken for an ordinal).
    private static func extractOrdinal(before suffix: String, in text: String) -> Int? {
        guard let suffixRange = text.range(of: suffix) else { return nil }
        var start = suffixRange.lowerBound
        while start > text.startIndex, NumberUnitNormalizer.isNumeralCharacter(text[text.index(before: start)]) {
            start = text.index(before: start)
        }
        guard start < suffixRange.lowerBound else { return nil }
        guard start > text.startIndex, text[text.index(before: start)] == "第" else { return nil }
        return NumberUnitNormalizer.parseChineseNumeral(text[start..<suffixRange.lowerBound])
    }

    /// Splits a target phrase like "把深蹲第二個" or "把第一個動作" into a
    /// (possibly empty) exercise name plus an optional occurrence ordinal.
    /// An empty name with a non-nil ordinal means "the Nth entry in the
    /// draft, whichever exercise it is" (`ExerciseTargetSpec`/
    /// `VoiceCommandTargetResolver` treat an empty `spokenName` as matching
    /// every entry, per `Exercise.matches(searchText:)`'s own "empty query
    /// matches everything" rule).
    private static func extractTarget(from text: Substring) -> ExerciseTargetSpec {
        var text = text
        if text.hasPrefix("把") { text = text.dropFirst() }
        let fullText = String(text)
        let ordinal = extractOrdinal(before: "個", in: fullText)
        let name = extractLeadingExerciseName(from: text) ?? ""
        return ExerciseTargetSpec(spokenName: name, occurrenceOrdinal: ordinal)
    }

    /// A fixed list of markers that end a leading free-text exercise name --
    /// the parser's one genuinely fuzzy heuristic (exercise names have no
    /// clean delimiter in spoken Chinese), scoped by stopping at the first
    /// grammar keyword this parser otherwise recognizes.
    private static let stopMarkers = [
        "第", "改成", "改為", "變成", "換成", "換為", "替換為", "替換成", "設為",
        "設置", "調整", "的", "組", "次", "公斤", "磅", "秒", "分鐘", "米",
        "公里", "實際", "計劃", "休息", "超級組", "，", ",", "。"
    ]

    /// 這幾個單位詞前面緊跟的是數量（"三組"/"十次"/"四十公斤"），真機測試
    /// 時發現："添加臥推三組十次"（動作名和數量之間沒有逗號隔開）之前會把
    /// 數字也吃進名稱裡（切在"組"本身，而不是"組"前面那個數字之前），變成
    /// "臥推三"。這裡的單位詞在計算切點時，額外往回跳過緊接在前面的整段
    /// 數字/中文數字，切點落在數字之前，不是單位詞本身之前。
    private static let numeralPrecededMarkers: Set<String> = [
        "組", "次", "公斤", "磅", "秒", "分鐘", "米", "公里"
    ]

    /// 2026-09-13：從 `private` 改為 `public`——`VoiceCommandService` 的
    /// 「模糊輸入回退」需要用同一套（已經測過的）停止詞/量詞裁切規則，從
    /// 一句完全沒被語法認出來的原始文字裡，抽出「聽起來像動作名稱」的
    /// 那一段，再拿去跟動作庫比對，不重新發明一套規則。
    public static func extractLeadingExerciseName(from text: Substring) -> String? {
        var text = text
        if text.hasPrefix("把") { text = text.dropFirst() }
        guard !text.isEmpty else { return nil }
        var endIndex = text.endIndex
        for marker in stopMarkers {
            guard let range = text.range(of: marker) else { continue }
            var cut = range.lowerBound
            if numeralPrecededMarkers.contains(marker) {
                while cut > text.startIndex, NumberUnitNormalizer.isNumeralCharacter(text[text.index(before: cut)]) {
                    cut = text.index(before: cut)
                }
            }
            if cut < endIndex { endIndex = cut }
        }
        let name = text[text.startIndex..<endIndex].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
