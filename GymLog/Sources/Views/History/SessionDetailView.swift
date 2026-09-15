import SwiftUI
import SwiftData
import GymLogKit

/// Session detail: blocks -> entries -> sets. Supersets (and any
/// multi-entry block: dropset/circuit) are rendered as one visually grouped
/// card containing all their entries, never as separately-listed exercises
/// with a run-together name -- that's the whole point of CONTRACT.md §6
/// modeling blocks as structure.
struct SessionDetailView: View {
    let session: WorkoutSession
    /// 2026-09-09：把这一节载回「今天」做完整编辑（加/删动作、改 WOD、调段落），
    /// 由 `HistoryListView` 注入。`nil` 时不显示这个入口。
    var onEditInToday: (() -> Void)? = nil

    // 历史课次编辑及补录日期（2026-09-06 审查报告"适合当前范围的功能"第二批）。
    @State private var showingEditSheet = false

    // 课后摘要（同批次）：判断本次课里哪些动作创造了新 PR，需要该学员这个动作的
    // 完整跨课次历史，所以在这里查询，而不是在纯格式化的
    // `SessionSummaryGenerator` 里查询。
    @Query private var allEntries: [ExerciseEntry]
    // 2026-09-08 M3: WOD PR 判定同理需要该学员全部历史课次的 WOD 段。
    @Query private var allSessions: [WorkoutSession]
    @State private var summaryText: String?

    /// 首屏 = 課次摘要（GymLog 改版設計 §6）：總量／最大／時長 + PR 個數 +
    /// 練了什麼的模式色標，全部沿用既有的 `SessionSummaryMetrics`／
    /// `prPointIDs()`，不重新定義任何一條規則。
    private var summaryMetrics: SessionSummaryMetrics { SessionSummaryMetrics.compute(for: session) }

    private var nonWODEntries: [ExerciseEntry] {
        session.orderedBlocks.filter { $0.sectionKind != .wod }.flatMap(\.orderedEntries)
    }

    private var summaryMovementPatterns: [MovementPattern] {
        var seen: [MovementPattern] = []
        for entry in nonWODEntries {
            guard let pattern = entry.exercise?.movementPattern, !seen.contains(pattern) else { continue }
            seen.append(pattern)
            if seen.count >= 4 { break }
        }
        return seen
    }

    var body: some View {
        let prIDs = prPointIDs()
        List {
            Section {
                sessionSummaryCard(prCount: prIDs.count)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section {
                TrainingInsightView(session: session)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if session.warmup != nil || session.warmupNote != nil {
                Section {
                    NoteRow(text: session.warmup, note: session.warmupNote)
                        .listRowBackground(DS.C.surface)
                } header: {
                    Text(L("熱身", "Warm-up")).sectionLabelStyle()
                }
            }

            ForEach(session.orderedBlocks, id: \.persistentModelID) { block in
                Section {
                    if block.sectionKind == .wod {
                        WODBlockCard(block: block, recordStatus: wodRecordStatuses["\(session.id)#\(block.order)"] ?? .none)
                            .listRowBackground(DS.C.surface)
                    } else {
                        BlockCard(block: block, sessionID: session.id, prPointIDs: prIDs)
                            .listRowBackground(DS.C.surface)
                    }
                    if let note = block.note, !note.isEmpty {
                        NoteCard(note: note)
                            .listRowBackground(DS.C.surface)
                    }
                } header: {
                    HStack {
                        Text(blockHeaderTitle(block))
                            .sectionLabelStyle()
                            .lineLimit(1)
                        Spacer()
                        if block.orderedEntries.contains(where: { $0.orderedSets.contains { $0.isInferred } }) {
                            // 「推斷」整塊只標一次，不再逐行出現。
                            HStack(spacing: 4) {
                                Circle().fill(DS.C.inferred).frame(width: 6, height: 6)
                                Text(L("推斷", "Inferred"))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(DS.C.inferred)
                            }
                        }
                        if let rest = block.restSeconds {
                            Text(L("休息 \(rest)s", "Rest \(rest)s"))
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(DS.C.textLow)
                        }
                    }
                }
            }

            Section {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        if session.cooldown != nil || session.cooldownNote != nil {
                            NoteRow(text: session.cooldown, note: session.cooldownNote)
                        }
                        LabeledContent(L("原始日期文本", "Original Date Text"), value: session.dateRaw)
                        LabeledContent(L("日期來源", "Date Source"), value: session.dateOrigin == .reconstructed ? L("還原", "Restored") : (session.dateOrigin == .asRecorded ? L("原樣採信", "As Recorded") : L("未知", "Unknown")))
                        LabeledContent(L("來源表", "Source Sheet"), value: L("\(session.sourceSheet) 第 \(session.sourceRow) 行", "\(session.sourceSheet) row \(session.sourceRow)"))
                    }
                    .padding(.top, 6)
                } label: {
                    Text(L("放鬆與資料來源", "Cooldown & Data Source"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.C.textMid)
                }
            }
            .listRowBackground(DS.C.surface)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(DS.C.textHi)
            .tint(DS.C.textLow)
        }
        .scrollContentBackground(.hidden)
        .background(DS.C.canvas)
        .navigationTitle(SessionDateFormat.display.string(from: session.date))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    if let onEditInToday {
                        // 放在第一位：教练说「所有生成的 section 都要能方便地
                        // 修改」，而下面那个「快速修正」只能改已有组的数字，
                        // 加不了动作也碰不了 WOD。
                        Button {
                            onEditInToday()
                        } label: {
                            Label(
                                session.isInProgress ? L("繼續記錄", "Continue Session") : L("在「今天」中完整編輯", "Full Edit in Today"),
                                systemImage: session.isInProgress ? "play.fill" : "square.and.pencil"
                            )
                        }
                    }
                    Button {
                        showingEditSheet = true
                    } label: {
                        Label(L("快速修正數字／日期", "Quick Fix Numbers / Date"), systemImage: "pencil")
                    }
                    Button {
                        summaryText = SessionSummaryGenerator.summary(
                            for: session,
                            clientName: session.client?.displayName ?? L("學員", "Client"),
                            prPointIDs: prPointIDs()
                        )
                    } label: {
                        Label(L("分享摘要", "Share Summary"), systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            SessionEditSheet(session: session)
        }
        .sheet(isPresented: Binding(get: { summaryText != nil }, set: { if !$0 { summaryText = nil } })) {
            if let summaryText {
                ActivityShareSheet(activityItems: [summaryText])
            }
        }
    }

    /// `ExerciseHistoryPoint.id`s (this client's full history for every
    /// exercise appearing in this session) that `ExerciseHistoryAnalyzer
    /// .prFlags` flagged as a new PR, restricted to points that belong to
    /// THIS session — i.e. "which of this session's own exercises hit a PR
    /// today", not the client's all-time PR list.
    private func prPointIDs() -> Set<String> {
        guard let clientID = session.client?.id else { return [] }
        let exerciseIDs = Set(session.orderedBlocks.flatMap { $0.orderedEntries.compactMap { $0.exercise?.id } })

        var result: Set<String> = []
        for exerciseID in exerciseIDs {
            let relevant = allEntries.filter { $0.exercise?.id == exerciseID && $0.block?.session?.client?.id == clientID }
            guard let direction = relevant.first?.exercise?.loadDirection else { continue }
            let points = ExerciseHistoryAnalyzer.points(from: relevant, loadDirection: direction, includeInferred: true)
            let flags = ExerciseHistoryAnalyzer.prFlags(points: points, direction: direction)
            for (point, isPR) in zip(points, flags) where isPR && point.sessionID == session.id {
                result.insert(point.id)
            }
        }
        return result
    }

    /// "\(session.id)#\(block.order)" -> `WODPRAnalyzer.RecordStatus` for
    /// this session's own WOD blocks, computed over this client's FULL WOD
    /// history so the comparison is against every past attempt, not just
    /// this session's own blocks. Distinguishes a group's first-ever
    /// comparable attempt (`.first`, a baseline -- nothing existed yet to
    /// improve on) from a later genuine improvement (`.improved`), per
    /// "首次有效成绩显示'首次成绩／基准'，后续真正改善才显示'新纪录'".
    private var wodRecordStatuses: [String: WODPRAnalyzer.RecordStatus] {
        guard let clientID = session.client?.id else { return [:] }
        var keys: [String] = []
        var entries: [WODPRAnalyzer.Entry] = []
        for candidate in allSessions where candidate.client?.id == clientID {
            for block in candidate.orderedBlocks where block.sectionKind == .wod {
                guard let payload = block.wodPayload else { continue }
                keys.append("\(candidate.id)#\(block.order)")
                entries.append(WODPRAnalyzer.Entry(date: candidate.date, payload: payload))
            }
        }
        let combined = zip(keys, entries).sorted { $0.1.date < $1.1.date }
        let statuses = WODPRAnalyzer.recordStatuses(entries: combined.map(\.1))
        var result: [String: WODPRAnalyzer.RecordStatus] = [:]
        for (index, pair) in combined.enumerated() where statuses[index] != .none {
            result[pair.0] = statuses[index]
        }
        return result
    }

    /// HANDOFF.md §6 (06_session_detail)：`单组 · MACHINE INCLINE CHEST PRESS`
    /// 全大写英文动作名，10pt +0.14em。
    private func blockHeaderTitle(_ block: SessionBlock) -> String {
        if block.sectionKind == .wod {
            return block.wodPayload?.prescription.name.map { "WOD · \($0.uppercased())" } ?? "WOD"
        }
        let names = block.orderedEntries.map(\.displayName).joined(separator: " + ")
        return "\(block.blockType.displayName) · \(names.uppercased())"
    }

    /// 課次摘要卡（GymLog 改版設計 §6）：總量／最大／時長 + 動作模式色標，
    /// 首屏先回答「這堂課練了什麼、表現如何」，其餘說明性卡片（
    /// `TrainingInsightView`）退到它後面。
    private func sessionSummaryCard(prCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("課次摘要", "Session Summary")).sectionLabelStyle()
                    if let name = session.client?.displayName {
                        Text(L("第 \(session.weekNumber) 週 · \(name)", "Week \(session.weekNumber) · \(name)"))
                            .font(.system(size: 12))
                            .foregroundStyle(DS.C.textLow)
                    }
                }
                Spacer()
                if prCount > 0 {
                    Text(L("PR ×\(prCount)", "PR ×\(prCount)"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DS.C.pr)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(DS.C.prBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            HStack(spacing: 8) {
                summaryStat(L("總訓練量", "Total Volume"), summaryMetrics.totalVolumeKg, unit: "kg")
                summaryStat(L("主項最大", "Top Load"), summaryMetrics.maxLoadKg, unit: "kg")
                summaryStat(L("時長", "Duration"), session.plannedDurationMinutes.map { Double($0) / 60 }, unit: "h", isDuration: true)
            }
            if !summaryMovementPatterns.isEmpty {
                HStack(spacing: 6) {
                    ForEach(summaryMovementPatterns, id: \.self) { pattern in
                        MovementPatternBadge(pattern: pattern, size: 22)
                    }
                    Text(L("\(session.orderedBlocks.count) 個訓練塊", "\(session.orderedBlocks.count) blocks"))
                        .font(.system(size: 12))
                        .foregroundStyle(DS.C.textMid)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gymCard()
        .padding(.horizontal, DS.Space.pageMargin)
    }

    private func summaryStat(_ title: String, _ value: Double?, unit: String, isDuration: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(DS.C.textLow)
                .textCase(.uppercase)
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                if let value {
                    Text(isDuration ? Self.formatHours(value) : Self.formatNumber(value))
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DS.C.textHi)
                } else {
                    Text("—")
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DS.C.textLow)
                }
                if value != nil, !isDuration {
                    Text(unit).font(.system(size: 11)).foregroundStyle(DS.C.textLow)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(DS.C.inset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(value == nil ? 0.6 : 1)
    }

    private static func formatNumber(_ value: Double) -> String {
        let rounded = value.rounded()
        return abs(value - rounded) < 0.05 ? Int(rounded).formatted(.number.grouping(.automatic)) : String(format: "%.1f", value)
    }

    private static func formatHours(_ hours: Double) -> String {
        let totalMinutes = Int((hours * 60).rounded())
        return String(format: "%d:%02d", totalMinutes / 60, totalMinutes % 60)
    }
}

private struct NoteRow: View {
    let text: String?
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DS.C.textHi)
            }
            if let note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.C.textLow)
            }
        }
    }
}

/// 备注卡（HANDOFF.md §4.5）：左侧 2px hairline 竖条 + 「备注」11pt textLow +
/// 内容 13/Medium。
private struct NoteCard: View {
    let note: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(DS.C.hairline)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("備註", "Note"))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(DS.C.textLow)
                Text(note)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.C.textHi)
            }
        }
    }
}

/// One card per SessionBlock. When `entries.count > 1` (superset/dropset/
/// circuit with multiple movements), each entry gets its own labeled
/// sub-section within the same card so the grouping is visually obvious.
private struct BlockCard: View {
    let block: SessionBlock
    let sessionID: String
    let prPointIDs: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(block.orderedEntries.enumerated()), id: \.element.persistentModelID) { index, entry in
                EntryView(
                    entry: entry,
                    showsLetter: block.isMultiEntry,
                    letterIndex: index,
                    isPR: prPointIDs.contains("\(sessionID)#\(block.order)#\(entry.order)")
                )
                if index < block.orderedEntries.count - 1 {
                    Divider().overlay(DS.C.hairlineSoft)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// 2026-09-07 M2 CrossFit extension: a `.wod` block's history card. Shows
/// the prescription snapshot (never the CURRENT template/exercise-library
/// state -- 工程审阅 §5.2's "已存歷史必須保存處方快照") and the result, or an
/// explicit "此裝置無法讀取" state for a payload from a future/incompatible
/// app version (`SessionBlock.hasUnsupportedWODPayload`) -- never a blank
/// card and never a crash.
private struct WODBlockCard: View {
    let block: SessionBlock
    /// 2026-09-08 M3, 2026-09-10 拆分：`.improved` 是 `WODPRAnalyzer` 判定的
    /// 真正新纪录（金色 PR 标签）；`.first` 是该分组第一条有效成绩——还没有
    /// 任何东西可比较，只是基准，用中性配色的「首次成績」标签，不与新纪录
    /// 混淆。
    var recordStatus: WODPRAnalyzer.RecordStatus = .none

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let payload = block.wodPayload {
                HStack(spacing: 6) {
                    Text(WODSummaryFormatter.compactSummary(payload))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.C.textHi)
                    switch recordStatus {
                    case .improved: DataTagView(kind: .pr)
                    case .first: DataTagView(kind: .baseline)
                    case .none: EmptyView()
                    }
                }
                // 多轮处方（21-15-9）逐轮显示；只有一轮时保持原来的平铺列表。
                let rounds = payload.prescription.rounds
                ForEach(Array(rounds.enumerated()), id: \.offset) { roundIndex, round in
                    if rounds.count > 1 {
                        Text(L("第 \(roundIndex + 1) 輪", "Round \(roundIndex + 1)"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DS.C.textLow)
                    }
                    ForEach(Array(round.movements.enumerated()), id: \.offset) { _, movement in
                        HStack(spacing: 6) {
                            Text(movement.exerciseNameSnapshot)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(DS.C.textHi)
                            Text("\u{00d7} \(movement.quantity.displayText)")
                                .font(.system(size: 12))
                                .foregroundStyle(DS.C.textMid)
                            if let load = movement.load {
                                Text("@ \(load.displayText)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(DS.C.textMid)
                            }
                            if let standard = movement.standard, !standard.isEmpty {
                                Text(standard)
                                    .font(.system(size: 11))
                                    .foregroundStyle(DS.C.textLow)
                            }
                        }
                    }
                }
                if let notes = payload.result.notes, !notes.isEmpty {
                    Text(L("備註：\(notes)", "Notes: \(notes)"))
                        .font(.system(size: 12))
                        .foregroundStyle(DS.C.textLow)
                }
            } else if block.hasUnsupportedWODPayload {
                Text(L("此裝置版本無法讀取這個 WOD 記錄（來自較新版本的 App），資料仍保留，更新 App 後可正常顯示。", "This device's app version can't read this WOD record (saved by a newer app version). The data is preserved and will display once you update."))
                    .font(.system(size: 12))
                    .foregroundStyle(DS.C.textLow)
            } else {
                Text(L("無 WOD 內容", "No WOD content"))
                    .font(.system(size: 12))
                    .foregroundStyle(DS.C.textLow)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct EntryView: View {
    let entry: ExerciseEntry
    let showsLetter: Bool
    let letterIndex: Int
    var isPR: Bool = false

    private var letter: String {
        let letters = ["A", "B", "C", "D", "E", "F"]
        return letterIndex < letters.count ? letters[letterIndex] : "\(letterIndex + 1)"
    }

    /// 這個 entry 真正達成最大可比較重量的那一組——`isPR` 只代表「這個 entry
    /// 這堂課有 PR」，不代表哪一組；沒有這個就只能瞎猜（例如猜最後一組），
    /// 猜錯了會誤導教練覺得破紀錄的是另一組。
    private var prSetIndex: Int? {
        guard isPR else { return nil }
        let direction = entry.exercise?.loadDirection ?? .higherIsStronger
        var bestIndex: Int?
        var bestValue: Double?
        for (index, set) in entry.orderedSets.enumerated() {
            guard AnalyticsMath.isEffectiveCompletion(actual: set.actual),
                  let kg = AnalyticsMath.comparableKg(set.load) else { continue }
            if let currentBest = bestValue {
                if AnalyticsMath.isImprovement(candidate: kg, overBest: currentBest, direction: direction) {
                    bestValue = kg
                    bestIndex = index
                }
            } else {
                bestValue = kg
                bestIndex = index
            }
        }
        return bestIndex
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if showsLetter {
                    Text(letter)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DS.C.onAccent)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(DS.C.accent))
                }
                Text(entry.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.C.textHi)
                if entry.exercise == nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DS.C.danger)
                        .help(L("動作庫中未找到該動作引用", "Exercise reference not found in library"))
                }
                if isPR {
                    DataTagView(kind: .pr)
                }
            }
            if entry.exerciseRaw != entry.displayName {
                Text(L("原始文本：\(entry.exerciseRaw)", "Original text: \(entry.exerciseRaw)"))
                    .font(.system(size: 11))
                    .foregroundStyle(DS.C.textLow)
                    .padding(.leading, showsLetter ? 28 : 0)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entry.orderedSets.enumerated()), id: \.element.persistentModelID) { index, set in
                    SetRow(set: set, isPR: index == prSetIndex)
                    if index < entry.orderedSets.count - 1 {
                        Divider().overlay(DS.C.hairlineSoft)
                    }
                }
            }
            .padding(.leading, showsLetter ? 28 : 0)
        }
    }
}

/// 课次详情行（HANDOFF.md §4.5）：网格 `46 | 62 | 1fr | auto`。
private struct SetRow: View {
    let set: SetLog
    var isPR: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Text(L("第\(set.setIndex + 1)組", "Set \(set.setIndex + 1)"))
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(DS.C.textMid)
                .frame(width: 46, alignment: .leading)

            loadValue

            Text(L("目標 \(set.target.displayText) · 完成 \(set.actual.displayText)", "Target \(set.target.displayText) · Actual \(set.actual.displayText)"))
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(DS.C.textMid)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isPR {
                DataTagView(kind: .pr)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, isPR ? 10 : 0)
        .background(isPR ? DS.C.prBg : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var loadValue: some View {
        if let numeric = set.load.numericDisplay {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(numeric.value)
                    .font(.system(size: 19, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(DS.C.textHi)
                Text(numeric.unit)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.C.textLow)
            }
            .frame(width: 62, alignment: .leading)
        } else {
            Text(set.load.displayText)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DS.C.textHi)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 62, alignment: .leading)
        }
    }
}
