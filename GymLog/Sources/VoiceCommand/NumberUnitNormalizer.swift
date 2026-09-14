import Foundation

/// P3/M3a (2026-09-12): number/unit normalization for `VoiceCommandParser`
/// -- 執行Prompt與實施計劃.md §6.2's "支持簡繁、常見別名、中文數字、kg/lb/秒/
/// 分鐘/米/公里歸一化；負重形式不兼容時拒絕猜測". Numeral parsing/unit
/// extraction are a small, hand-written algorithm scoped to exactly what
/// this grammar needs (reps/kg/seconds/minutes/meters/km, set counts 1-4,
/// quantities typically well under 1000). Simplified/Traditional folding
/// (`foldSynonyms`) DOES lean on the system's general ICU "Hans-Hant"
/// transform -- a spoken exercise name itself (e.g. 計劃書 §6.2's own
/// canonical example, simplified "卧推") needs to fold to match this app's
/// Traditional-Chinese exercise library, not just this file's own grammar
/// keywords, so a narrow hand-written table alone isn't enough here.
public enum NumberUnitNormalizer {

    // MARK: - Chinese numerals

    private static let digitMap: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "兩": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
    ]
    private static let magnitudeMap: [Character: Int] = ["十": 10, "百": 100, "千": 1000]

    public static func isNumeralCharacter(_ ch: Character) -> Bool {
        ch.isASCII && ch.isNumber || digitMap[ch] != nil || magnitudeMap[ch] != nil
    }

    /// Parses a numeral RUN (every character must be a digit/magnitude
    /// character, or a plain ASCII digit string) -- e.g. "四十" -> 40,
    /// "一百二十三" -> 123, "40" -> 40. Returns `nil` if any character in
    /// `s` isn't part of a numeral (callers extract the numeral run first,
    /// e.g. via `numberImmediatelyBefore(_:in:)`, before calling this on a
    /// full sentence).
    public static func parseChineseNumeral(_ s: Substring) -> Int? {
        guard !s.isEmpty else { return nil }
        if let direct = Int(s) { return direct }
        var section = 0
        var lastDigit: Int?
        var sawAny = false
        for ch in s {
            if let d = digitMap[ch] {
                lastDigit = d
                sawAny = true
            } else if let m = magnitudeMap[ch] {
                let multiplier = lastDigit ?? 1
                section += multiplier * m
                lastDigit = nil
                sawAny = true
            } else {
                return nil
            }
        }
        if let d = lastDigit { section += d }
        return sawAny ? section : nil
    }

    /// Scans `text` for the first maximal contiguous run of numeral
    /// characters (ASCII digits or the CJK digit/magnitude characters
    /// above) and parses it. Only useful when a sentence has exactly one
    /// number of interest -- for anything with multiple numbers (a set
    /// count AND a rep target AND a weight, all in one sentence), use
    /// `numberImmediatelyBefore(_:in:)` instead so each number is picked out
    /// by the unit word that actually follows it, not by scan order.
    public static func firstNumber(in text: String) -> (value: Int, range: Range<String.Index>)? {
        var index = text.startIndex
        while index < text.endIndex {
            if isNumeralCharacter(text[index]) {
                var end = index
                while end < text.endIndex, isNumeralCharacter(text[end]) {
                    end = text.index(after: end)
                }
                let run = text[index..<end]
                if let value = parseChineseNumeral(run) {
                    return (value, index..<end)
                }
                index = end
            } else {
                index = text.index(after: index)
            }
        }
        return nil
    }

    /// Finds the LAST occurrence of `keyword` in `text` that has a numeral
    /// run immediately preceding it, and returns that number -- e.g. against
    /// "三組，每組十次，四十公斤", `numberImmediatelyBefore("組", in:)` finds
    /// "三組" (3), correctly skipping over "每組" (no numeral run immediately
    /// before that particular "組") rather than failing outright. This is
    /// the core mechanism `parseLoad`/`parseQuantity` and the command
    /// parser's ordinal extraction all build on, so a sentence naming
    /// several different numbers (set count, target quantity, weight,
    /// ordinal) resolves each one against the unit word actually next to it
    /// instead of scan order.
    ///
    /// LAST (not first) occurrence deliberately -- 2026-09-13 全局語音改造
    /// 要求支持改口/糾正："重量改成四十……不是，四十五公斤"/"唔係四十，係
    /// 四十五公斤" 都是同一個單位詞在句子裡出現兩次，糾正的那個數字永遠
    /// 說在後面。既有句子每個單位詞只出現一次，取最後一次等同取第一次，
    /// 不影響任何既有行為。
    public static func numberImmediatelyBefore(_ keyword: String, in text: String) -> (value: Int, range: Range<String.Index>)? {
        var searchStart = text.startIndex
        var lastFound: (value: Int, range: Range<String.Index>)?
        while let keywordRange = text.range(of: keyword, range: searchStart..<text.endIndex) {
            var start = keywordRange.lowerBound
            while start > text.startIndex, isNumeralCharacter(text[text.index(before: start)]) {
                start = text.index(before: start)
            }
            if start < keywordRange.lowerBound, let value = parseChineseNumeral(text[start..<keywordRange.lowerBound]) {
                lastFound = (value, start..<keywordRange.upperBound)
            }
            searchStart = keywordRange.upperBound
        }
        return lastFound
    }

    // MARK: - Simplified/traditional + synonym folding

    /// Fixed table for exactly the keywords this grammar matches on --
    /// folds a handful of simplified/alias spellings to the traditional
    /// form the parser's own keyword lists use (the app's default UI
    /// language). NOT a general 简繁转换 pass over free text (e.g. an
    /// exercise name typed in simplified Chinese is left untouched here;
    /// exercise-name matching itself goes through `Exercise.matches
    /// (searchText:)`, which already does case-insensitive substring
    /// matching against both `canonicalName`/`nameZh`/`aliases`).
    private static let synonymTable: [String: String] = [
        "组": "組", "动作": "動作", "换成": "換成", "换": "換", "撤销": "撤銷",
        "撤回": "撤銷", "设置": "設置", "调整": "調整", "变成": "變成", "实际": "實際",
        "计划": "計劃", "轮": "輪", "千克": "公斤", "分钟": "分鐘", "厘米": "公分",
        "为": "為", "个": "個", "边": "邊", "侧": "側", "级": "級", "数": "數"
    ]

    /// A general Simplified->Traditional pass (ICU's "Hans-Hant" transform)
    /// runs FIRST -- this is what actually makes an exercise name spoken in
    /// Simplified (e.g. 计划书 §6.2's own canonical example, "卧推") match
    /// against this app's Traditional-Chinese exercise library
    /// (`Exercise.matches(searchText:)` is a literal substring check with
    /// no simplified/traditional awareness of its own). The fixed
    /// `synonymTable` below then still runs on top for anything ICU's
    /// transform doesn't normalize the way this specific grammar needs
    /// (verified empirically against the current SDK by this file's own
    /// `NumberUnitNormalizerTests`, not merely assumed).
    public static func foldSynonyms(_ text: String) -> String {
        var result = text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
        // Longest keys first so multi-character entries fold before any
        // single-character overlap could partially match.
        for key in synonymTable.keys.sorted(by: { $0.count > $1.count }) {
            guard let replacement = synonymTable[key] else { continue }
            result = result.replacingOccurrences(of: key, with: replacement)
        }
        return result
    }

    // MARK: - Load (weight) parsing

    /// "四十公斤" -> `.absolute(kg: 40, raw: ...)`; "每邊二十公斤"/"二十公斤
    /// 每邊" -> `.perSide(kg: 20, ...)`; "一百磅" -> `.absolute(kg: 45.36,
    /// ...)` (lb converted to kg, the unit `LoadValue` actually stores).
    /// Returns `nil` -- never a guess -- when no recognized weight unit
    /// follows a number anywhere in `text`.
    public static func parseLoad(_ text: Substring) -> LoadValue? {
        let full = String(text)
        for (keyword, isLb) in [("公斤", false), ("磅", true), ("kg", false), ("KG", false), ("lb", true)] {
            guard let (value, range) = numberImmediatelyBefore(keyword, in: full) else { continue }
            let isPerSide = perSideMarkerNearby(range: range, in: full)
            let kg = isLb ? (Double(value) * 0.45359237 * 100).rounded() / 100 : Double(value)
            return isPerSide ? .perSide(kg: kg, raw: full) : .absolute(kg: kg, raw: full)
        }
        return nil
    }

    private static func perSideMarkerNearby(range: Range<String.Index>, in text: String) -> Bool {
        let before = text[text.startIndex..<range.lowerBound]
        let after = text[range.upperBound...]
        return before.hasSuffix("每邊") || before.hasSuffix("每边") || before.hasSuffix("每側") || before.hasSuffix("每侧")
            || after.hasPrefix("每邊") || after.hasPrefix("每边")
    }

    // MARK: - Quantity (reps/time/distance/rounds) parsing

    /// Parses a quantity strictly in the unit `metric` requires -- e.g.
    /// against a `.time` exercise, only "秒"/"分鐘"/"分钟" are accepted; "八
    /// 次" (a reps unit) against a `.time` exercise returns `nil` rather
    /// than reinterpreting 8 as seconds. This extends `EntryDraft
    /// .setExercise`'s existing "never carry a raw number across an
    /// incompatible unit" discipline into the voice layer.
    public static func parseQuantity(_ text: Substring, metric: RecordingMetric) -> Int? {
        let full = String(text)
        switch metric {
        case .reps, .unknown:
            return numberImmediatelyBefore("次", in: full)?.value
        case .time:
            if let (v, _) = numberImmediatelyBefore("分鐘", in: full) { return v * 60 }
            if let (v, _) = numberImmediatelyBefore("分钟", in: full) { return v * 60 }
            return numberImmediatelyBefore("秒", in: full)?.value
        case .distance:
            if let (v, _) = numberImmediatelyBefore("公里", in: full) { return v * 1000 }
            return numberImmediatelyBefore("米", in: full)?.value
        case .rounds:
            if let (v, _) = numberImmediatelyBefore("輪", in: full) { return v }
            if let (v, _) = numberImmediatelyBefore("轮", in: full) { return v }
            return numberImmediatelyBefore("組", in: full)?.value
        }
    }

    /// Like `parseQuantity(_:metric:)`, but the metric ISN'T known ahead of
    /// time -- used when parsing a command before its target entry (and
    /// therefore that entry's `recordingMetric`) has been resolved.
    /// Scans for whichever recognized unit keyword actually appears and
    /// returns both the value (already normalized to the metric's base
    /// unit -- minutes to seconds, km to meters) and which `RecordingMetric`
    /// dimension the spoken unit implies, so the caller can check it against
    /// the ACTUAL resolved entry's metric once known, and reject a mismatch
    /// rather than silently reinterpreting the number.
    public static func parseAnyQuantity(_ text: Substring) -> (value: Int, metric: RecordingMetric)? {
        let full = String(text)
        if let (v, _) = numberImmediatelyBefore("分鐘", in: full) { return (v * 60, .time) }
        if let (v, _) = numberImmediatelyBefore("分钟", in: full) { return (v * 60, .time) }
        if let (v, _) = numberImmediatelyBefore("秒", in: full) { return (v, .time) }
        if let (v, _) = numberImmediatelyBefore("公里", in: full) { return (v * 1000, .distance) }
        if let (v, _) = numberImmediatelyBefore("米", in: full) { return (v, .distance) }
        if let (v, _) = numberImmediatelyBefore("輪", in: full) { return (v, .rounds) }
        if let (v, _) = numberImmediatelyBefore("轮", in: full) { return (v, .rounds) }
        if let (v, _) = numberImmediatelyBefore("次", in: full) { return (v, .reps) }
        return nil
    }
}
