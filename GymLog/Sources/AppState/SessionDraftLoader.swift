import Foundation

/// 把一节**已经落库**的 `WorkoutSession` 还原成「今天」里可继续编辑的
/// `BlockDraft` 列表（2026-09-09 教练要求：「暫時保存」之后能回来接着录，
/// 以及「所有生成的 section 都可以方便地进行修改」）。
///
/// `load` 与 `copy`（2026-09-16 新增）的关键区别——两者现在都完整还原每个
/// Round（不再有「只带第一组」的简化版），差别在于是**打开同一次继续改**
/// 还是**复制成新的一次**：
///
/// 1. `load` 把 WOD 成绩原样带回来，教练打开的就是那一次本身；`copy` 沿用
///    `WODBlockDraft.fromPrescription` 本来的行为，把成绩清空（同标准复测）。
/// 2. `load` 保留每个 Round 原本的 `actualRecorded`；`copy` 把所有 Round 的
///    `actualRecorded` 重置为 `false`（`actual` 的数值仍然带过去当参考，只是
///    标成待确认）——新的一天不能假装教练已经确认过还没发生的成绩。
///
/// 纯逻辑、不碰 `ModelContext`，所以放在 GymLogKit 里可以直接单测。日期的
/// UTC/本地换算留在视图层（`TrainingDayEncoding` 在 App target 里），这里只
/// 负责块与动作。
@MainActor
public enum SessionDraftLoader {

    /// `session` 的每个块对应一个 `BlockDraft`。动作已从动作库里删掉的条目会
    /// 被跳过（与 `TodayDraftStore.restore` 的处理一致），整块都没剩下时这一
    /// 块也不再出现——所以调用方要用返回的 `droppedEntryCount` 告诉教练，而不
    /// 是让内容悄悄变少。
    public static func load(from session: WorkoutSession, exercises: [Exercise]) -> (blocks: [BlockDraft], droppedEntryCount: Int) {
        var droppedTotal = 0
        var blocks: [BlockDraft] = []

        for block in session.orderedBlocks {
            if block.sectionKind == .wod, let payload = block.wodPayload {
                let wodDraft = WODBlockDraft.fromPrescription(payload.prescription, exercises: exercises)
                // `fromPrescription` 按「复测」的规则把成绩清空了；继续编辑要的
                // 是原样，所以把这一次的成绩再填回去。
                apply(payload.result, to: wodDraft)
                let loaded = BlockDraft(
                    blockType: block.blockType, restSeconds: block.restSeconds,
                    sectionKind: .wod, wodDraft: wodDraft
                )
                loaded.source = sourceFields(of: block)
                blocks.append(loaded)
                continue
            }

            var entries: [EntryDraft] = []
            for entry in block.orderedEntries {
                guard let exercise = entry.exercise else {
                    droppedTotal += 1
                    continue
                }
                let sets = entry.orderedSets
                let metric = recordingMetric(for: sets, fallback: exercise.recordingMetric)
                var loadedRounds = rounds(from: sets, metric: metric, equipment: exercise.equipment)
                // P1 (2026-09-11): Superset 的「一輪」＝一個 setsCount=1 的
                // RoundDraft；`rounds(from:...)` 把連續且三個值都相同的
                // SetLog 合併成 setsCount>1 的一個 RoundDraft，這在一般動作
                // 上是正確的還原，對 Superset 卻會把本來各自獨立的幾輪（剛
                // 好同一個重量/目標/實際，例如三輪都是 60kg x 8 下）誤判成
                // 「一輪、組數變多」，導致重新打開後這個成員的輪數比其他成
                // 員少、UI 顯示對不上。按 `setsCount` 拆回等量、全部
                // setsCount=1 的獨立輪即可精確還原（見
                // `SupersetBlockDraftTests
                // .testSaveLoadResaveRoundTripsUnevenRoundSupersetLosslessly`）。
                if block.blockType == .superset {
                    loadedRounds = loadedRounds.flatMap { round in
                        (0..<max(round.setsCount, 1)).map { _ in
                            RoundDraft(setsCount: 1, load: round.load, target: round.target, actual: round.actual, actualRecorded: round.actualRecorded, isInferred: round.isInferred)
                        }
                    }
                }
                let loadedEntry = EntryDraft(
                    exercise: exercise,
                    rounds: loadedRounds,
                    restSeconds: block.restSeconds,
                    // 单位从这一次**实际存下来的** RepTarget 反推，不读动作库
                    // 当前的分类：教练可能在这次训练之后把动作改成了别的记录
                    // 方式，按新分类去解释旧数字就会把「500 公尺」读成「500
                    // 次」（2026-09-07 审阅 B02 已经在草稿快照那条路径上踩过
                    // 一次，这里是同一个坑的另一个入口）。
                    recordingMetric: metric
                )
                loadedEntry.source = EntrySourceFields(exerciseID: exercise.id, exerciseRaw: entry.exerciseRaw)
                entries.append(loadedEntry)
            }
            guard !entries.isEmpty else { continue }
            let loaded = BlockDraft(
                blockType: block.blockType, restSeconds: block.restSeconds,
                entries: entries, sectionKind: block.sectionKind
            )
            loaded.source = sourceFields(of: block)
            blocks.append(loaded)
        }
        return (blocks, droppedTotal)
    }

    /// Blocks whose stored WOD payload this build cannot decode. `load` would
    /// drop them, and saving would then delete them, so callers must refuse a
    /// full edit of such a session instead.
    public static func unsupportedBlockCount(in session: WorkoutSession) -> Int {
        session.orderedBlocks.filter(\.hasUnsupportedWODPayload).count
    }

    private static func sourceFields(of block: SessionBlock) -> BlockSourceFields {
        BlockSourceFields(note: block.note, restRaw: block.restRaw, restSeconds: block.restSeconds, sourceRow: block.sourceRow)
    }

    /// 2026-09-16：把一節歷史課次**複製**成今天全新一節的起點——跟 `load`
    /// 保留完全一樣的 Round 結構（含 `.range`/`.perSide`，不因為「只是複製」
    /// 就退回單輪簡化版），差別只在於這是新的一天，不是接著同一節課繼續
    /// 錄：每一輪的「實際」都重置為未確認（`actualRecorded = false`，但
    /// `actual` 的數值原樣保留，UI 上顯示成教練可以直接確認或微調的參考值，
    /// 例如「上次是 8 下」），WOD 沿用 `fromPrescription` 本來就會清空成績
    /// 的行為（跟 `copyLastSession` 原本的 WOD 處理一致）。不回傳
    /// `existingSessionID`——呼叫端必須當成一節全新課次寫入，不能覆蓋原本
    /// 那一節。
    public static func copy(from session: WorkoutSession, exercises: [Exercise]) -> (blocks: [BlockDraft], droppedEntryCount: Int) {
        var droppedTotal = 0
        var blocks: [BlockDraft] = []

        for block in session.orderedBlocks {
            if block.sectionKind == .wod, let payload = block.wodPayload {
                // 不呼叫 `apply(payload.result, to:)`——複製到新的一天要的正是
                // `fromPrescription` 本來就會做的「只帶處方、成績從零開始」。
                let wodDraft = WODBlockDraft.fromPrescription(payload.prescription, exercises: exercises)
                blocks.append(BlockDraft(
                    blockType: block.blockType, restSeconds: block.restSeconds,
                    sectionKind: .wod, wodDraft: wodDraft
                ))
                continue
            }

            var entries: [EntryDraft] = []
            for entry in block.orderedEntries {
                guard let exercise = entry.exercise else {
                    droppedTotal += 1
                    continue
                }
                let sets = entry.orderedSets
                let metric = recordingMetric(for: sets, fallback: exercise.recordingMetric)
                var copiedRounds = rounds(from: sets, metric: metric, equipment: exercise.equipment).map {
                    RoundDraft(setsCount: $0.setsCount, load: $0.load, target: $0.target, actual: $0.actual, actualRecorded: false)
                }
                // 跟 `load` 同一個 P1 (2026-09-11) 修正：Superset 的一輪固定
                // `setsCount == 1`，`rounds(from:...)` 合併同重量/目標/實際的
                // 連續組會誤判成同一輪、組數變多。
                if block.blockType == .superset {
                    copiedRounds = copiedRounds.flatMap { round in
                        (0..<max(round.setsCount, 1)).map { _ in
                            RoundDraft(setsCount: 1, load: round.load, target: round.target, actual: round.actual, actualRecorded: false)
                        }
                    }
                }
                entries.append(EntryDraft(
                    exercise: exercise,
                    rounds: copiedRounds,
                    restSeconds: block.restSeconds,
                    recordingMetric: metric
                ))
            }
            guard !entries.isEmpty else { continue }
            blocks.append(BlockDraft(
                blockType: block.blockType, restSeconds: block.restSeconds,
                entries: entries, sectionKind: block.sectionKind
            ))
        }
        return (blocks, droppedTotal)
    }

    /// 连续的、三个值都相同的 `SetLog` 合成一个 Round——正是保存时
    /// `EntryDraft.resolvedSets()` 展开动作的逆运算，所以「打开 → 不改 → 再
    /// 保存」得到的 `SetLog` 序列与原来逐条相同。
    ///
    /// 不设 4 个 Round 的上限：`EntryDraft.maxRounds` 管的是教练**新加**多少
    /// 个 Round，而 Excel 导入的历史课次一个动作出现 6 种不同重量是真实存在的。
    /// 强行折叠会丢数据，截断更糟；多出来的 Round 照样显示、照样能改，只是
    /// 「加一組」按钮在删到 4 个以下之前不可用。
    /// R01 (2026-09-16): `set.target`/`set.actual` are carried straight into
    /// the `RoundDraft` as-is -- no more `RepTargetToRoundQuantity.quantity(
    /// from:metric:)` here. That call used to be the exact point where a
    /// historical `.range(8,12)`/`.perSide(left,right)` actual got collapsed
    /// to its midpoint `Int` the moment a saved course was merely opened for
    /// editing, before the coach had touched anything -- "打开 → 不改 → 保存"
    /// was silently lossy. `RoundDraft.target`/`.actual` now hold the real
    /// `RepTarget`, so this function is a direct passthrough (still merging
    /// consecutive identical-triple `SetLog`s into one multi-set Round,
    /// unchanged).
    static func rounds(from sets: [SetLog], metric: RecordingMetric, equipment: Equipment) -> [RoundDraft] {
        guard !sets.isEmpty else {
            let fallback = RepTargetToRoundQuantity.repTarget(quantity: RepTargetToRoundQuantity.defaultQuantity(for: metric), metric: metric)
            return [RoundDraft(
                setsCount: 1, load: PrefillResolver.defaultLoad(for: equipment),
                target: fallback, actual: fallback, actualRecorded: false
            )]
        }
        var result: [RoundDraft] = []
        var runLoad: LoadValue?
        var runTarget: RepTarget?
        var runActual: RepTarget?
        var runInferred: Bool?

        for set in sets {
            if set.load == runLoad, set.target == runTarget, set.actual == runActual, set.isInferred == runInferred, !result.isEmpty {
                result[result.count - 1].setsCount += 1
                continue
            }
            runLoad = set.load
            runTarget = set.target
            runActual = set.actual
            runInferred = set.isInferred
            result.append(RoundDraft(
                setsCount: 1,
                load: set.load,
                target: set.target,
                actual: set.actual,
                actualRecorded: { if case .unknown = set.actual { return false }; return true }(),
                isInferred: set.isInferred
            ))
        }
        return result
    }

    /// 这一条记录当初是按什么单位存的，由它自己的 `RepTarget` 说了算。全部组
    /// 都没有可辨认的单位（空记录）时才退回动作库当前的分类。
    static func recordingMetric(for sets: [SetLog], fallback: RecordingMetric) -> RecordingMetric {
        for set in sets {
            switch set.target {
            case .time: return .time
            case .distance: return .distance
            case .rounds: return .rounds
            case .fixed, .range, .perSide: return .reps
            case .unknown: continue
            }
        }
        return fallback
    }

    /// `WODBlockDraft.fromPrescription` 只带处方；这里把这一次的成绩填回草稿
    /// ——`applyExistingResult` 同时把完整原始成绩存进 `originalResult`，这样
    /// 这版 UI 没有编辑入口的字段（`actualMovements`/`rpe`/超時定位/間歇明細/
    /// 多單位總量）在「打开→不改→保存」之后仍然原样还在，而不是被
    /// `resolvedResult()` 悄悄清空或覆盖成默认值。
    private static func apply(_ result: WODResult, to draft: WODBlockDraft) {
        draft.applyExistingResult(result)
    }
}
