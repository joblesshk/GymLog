import Foundation

/// 把一节**已经落库**的 `WorkoutSession` 还原成「今天」里可继续编辑的
/// `BlockDraft` 列表（2026-09-09 教练要求：「暫時保存」之后能回来接着录，
/// 以及「所有生成的 section 都可以方便地进行修改」）。
///
/// 与 `TodayView.copyLastSession` 的关键区别——那是**复制处方去做新一次**，
/// 这是**打开同一次继续改**：
///
/// 1. 复制只带出每个动作的第一组（下一次训练从上次的重量起步就够了）；这里
///    必须把整条 `SetLog` 序列原样还原成 Round，否则「保存 → 重新打开 → 再
///    保存」会把 Round 2/3/4 悄悄抹掉。
/// 2. 复制会把 WOD 成绩清空（同标准复测，成绩不能带过去）；这里必须连成绩一
///    起带回来，教练打开的就是那一次本身。
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
                            RoundDraft(setsCount: 1, load: round.load, targetQuantity: round.targetQuantity, actualQuantity: round.actualQuantity, actualRecorded: round.actualRecorded)
                        }
                    }
                }
                entries.append(EntryDraft(
                    exercise: exercise,
                    rounds: loadedRounds,
                    restSeconds: block.restSeconds,
                    // 单位从这一次**实际存下来的** RepTarget 反推，不读动作库
                    // 当前的分类：教练可能在这次训练之后把动作改成了别的记录
                    // 方式，按新分类去解释旧数字就会把「500 公尺」读成「500
                    // 次」（2026-09-07 审阅 B02 已经在草稿快照那条路径上踩过
                    // 一次，这里是同一个坑的另一个入口）。
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
    static func rounds(from sets: [SetLog], metric: RecordingMetric, equipment: Equipment) -> [RoundDraft] {
        guard !sets.isEmpty else {
            let fallback = RepTargetToRoundQuantity.defaultQuantity(for: metric)
            return [RoundDraft(
                setsCount: 1, load: PrefillResolver.defaultLoad(for: equipment),
                targetQuantity: fallback, actualQuantity: fallback, actualRecorded: false
            )]
        }
        var result: [RoundDraft] = []
        var runLoad: LoadValue?
        var runTarget: RepTarget?
        var runActual: RepTarget?

        for set in sets {
            if set.load == runLoad, set.target == runTarget, set.actual == runActual, !result.isEmpty {
                result[result.count - 1].setsCount += 1
                continue
            }
            runLoad = set.load
            runTarget = set.target
            runActual = set.actual
            result.append(RoundDraft(
                setsCount: 1,
                load: set.load,
                targetQuantity: RepTargetToRoundQuantity.quantity(from: set.target, metric: metric),
                actualQuantity: RepTargetToRoundQuantity.quantity(from: set.actual, metric: metric),
                actualRecorded: { if case .unknown = set.actual { return false }; return true }()
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
