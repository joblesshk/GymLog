import Foundation

/// 2026-09-13 真機試用反饋：使用者說中文，語音候選按鈕卻顯示動作的英文
/// `canonicalName`（例如"Back Squat"而不是"槓鈴背蹲"）。這裡不是全 App
/// 通用的 `Exercise.displayName`（那個是雙語格式"中文（English）"，給
/// 選動作面板等其他畫面用，且會跟著 `AppLanguage` 界面顯示語言走）——
/// 語音候選只用「使用者說的是中文」這個更直接的訊號，一律優先顯示中文名，
/// 沒有中文名的自建動作才退回英文 `canonicalName`，不受界面顯示語言
/// 影響（語音模式本來就獨立於界面語言，見 `VoiceLanguageMode`）。
extension Exercise {
    public var voiceCandidateDisplayName: String {
        nameZh.isEmpty ? canonicalName : nameZh
    }
}

/// How a spoken exercise name locates something -- either an existing entry
/// already in today's draft (`replaceExercise`/`setPlan`/`setActual`/
/// `addMember`-adjacent commands) or a library exercise not yet in the draft
/// (`addExercise`). `occurrenceOrdinal` disambiguates "第二個深蹲" when the
/// name matches more than once.
public struct ExerciseTargetSpec: Equatable {
    public let spokenName: String
    public let occurrenceOrdinal: Int?

    public init(spokenName: String, occurrenceOrdinal: Int? = nil) {
        self.spokenName = spokenName
        self.occurrenceOrdinal = occurrenceOrdinal
    }
}

/// One candidate entry shown to the user when a spoken exercise name matches
/// more than one entry currently in the draft.
public struct DraftEntryCandidate: Equatable {
    public let blockID: UUID
    public let entryID: UUID
    public let displayName: String

    public init(blockID: UUID, entryID: UUID, displayName: String) {
        self.blockID = blockID
        self.entryID = entryID
        self.displayName = displayName
    }
}

public enum ResolvedTarget: Equatable {
    case entry(blockID: UUID, entryID: UUID)
    /// §6.2: "重複同名動作需定位第幾項" -- surfaced rather than guessed.
    case ambiguous(candidates: [DraftEntryCandidate])
    case notFound
}

/// Resolves an `ExerciseTargetSpec` against entries already in today's
/// draft, using `Exercise.matches(searchText:)` (`Exercise.swift:128-134`)
/// -- the SAME single matching rule every picker in the app already uses, so
/// voice and manual search agree on what "找到叫深蹲的動作" means.
/// `@MainActor`: reads `TodayDraftStore.blocks`/`BlockDraft.entries`/
/// `EntryDraft.exercise`, all themselves `@MainActor`-isolated -- matches
/// where every call site already runs (UI code, or `VoiceCommandService`,
/// itself `@MainActor`), same reasoning as `ExchangeExporter`'s own
/// `@MainActor` marking (P2, 2026-09-11).
@MainActor
public enum VoiceCommandTargetResolver {
    /// `occurrenceOrdinal` (1-based) picks among matches in block/entry
    /// display order. No ordinal + exactly one match -> resolved. No
    /// ordinal + 2+ matches, OR an ordinal that's out of range for however
    /// many actually matched -> `.ambiguous` (never a silent guess). Zero
    /// matches -> `.notFound`.
    public static func resolve(_ spec: ExerciseTargetSpec, in draft: TodayDraftStore) -> ResolvedTarget {
        var matches: [DraftEntryCandidate] = []
        for block in draft.blocks {
            for entry in block.entries where entry.exercise.matches(searchText: spec.spokenName) {
                matches.append(DraftEntryCandidate(blockID: block.id, entryID: entry.id, displayName: entry.exercise.voiceCandidateDisplayName))
            }
        }
        guard !matches.isEmpty else { return .notFound }
        if let ordinal = spec.occurrenceOrdinal {
            guard matches.indices.contains(ordinal - 1) else { return .ambiguous(candidates: matches) }
            let picked = matches[ordinal - 1]
            return .entry(blockID: picked.blockID, entryID: picked.entryID)
        }
        guard matches.count == 1 else { return .ambiguous(candidates: matches) }
        return .entry(blockID: matches[0].blockID, entryID: matches[0].entryID)
    }
}

public enum LibraryExerciseResolution {
    case matched(Exercise)
    /// §1.4/用戶確認：同名但對到 2+ 個不同的庫內動作時，永遠彈澄清，不自動選
    /// 最常用那個——寧可多問一句，也不要有機會寫錯動作。
    case ambiguous(candidates: [Exercise])
    case notFound
}

/// Resolves a spoken exercise name against the WHOLE exercise library (for
/// `addExercise`, which by definition targets something not yet in the
/// draft). Distinct `Exercise.id`s that both match are always `.ambiguous`;
/// `FrequencyAnalyzer.frequentExercises` (`GymLog/Sources/AppState/
/// FrequencyAnalyzer.swift`) may be used by a caller to ORDER the candidate
/// list shown for clarification, but this resolver itself never uses it to
/// auto-pick.
///
/// 2026-09-13：召回改走 `ExerciseVoiceIndex.recallExercises` 而不是直接
/// `exercises.filter { $0.matches(...) }`──後者漏掉「深蹲」這種只出現在
/// `notes` 而非正式別名的泛用詞（見 `ExerciseVoiceIndex` 的說明）。名稱／
/// 別名命中優先於 notes 命中，但兩者合起來計數決定 matched/ambiguous，
/// 不因為 notes 命中排序較低就被忽略成「唯一匹配」。
public enum VoiceCommandLibraryResolver {
    public static func resolve(spokenName: String, in exercises: [Exercise]) -> LibraryExerciseResolution {
        let matches = ExerciseVoiceIndex.recallExercises(spokenName: spokenName, in: exercises)
        guard !matches.isEmpty else { return .notFound }
        guard matches.count == 1, let only = matches.first else { return .ambiguous(candidates: matches) }
        return .matched(only)
    }
}
