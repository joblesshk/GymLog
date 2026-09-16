import SwiftUI
import GymLogKit

/// One WOD block in the active session draft -- the CrossFit counterpart to
/// `EntryRowView`/`BlockDraftCard`. M2 built manual (after-the-fact) entry;
/// M3 adds an optional live timer (`timerSection` below) -- starting it is
/// never required, a coach can always skip straight to typing the result in
/// manually. Still a single round of movements, not yet a per-round-varying
/// list (21-15-9's differing rep scheme) -- see `WODBlockDraft`'s own doc
/// comment, unchanged since M2.
struct WODBlockDraftCard: View {
    @Bindable var wodDraft: WODBlockDraft
    let allExercises: [Exercise]
    /// 工程审阅 §7: "只有一個主訓練計時器" -- shared across every WOD card in
    /// the current session (`TodayDraftStore.activeWODTimerOwnerID`) so a
    /// second card can't start its own timer while this one's is running.
    @Binding var activeWODTimerOwnerID: UUID?
    /// 整塊 WOD 的熱量估算（`≈N kcal`），資料不足時為 nil 不顯示。
    var energyText: String? = nil
    var onDelete: () -> Void

    @State private var timer: WODTimerModel?
    @State private var showingAddMovementPicker = false
    /// Which round's "加一個動作" was tapped -- the sheet itself is shared
    /// across all rounds (one `.sheet` modifier), so this is how it knows
    /// which round to append into when the picker returns.
    @State private var addMovementRoundIndex = 0
    @State private var notificationsDenied = false
    /// GymLog 改版設計 §4：計時一開始，處方收合成一行動作速覽，把畫面讓給
    /// 計時器；教練仍可點那一行「展開」看完整處方。只是顯示狀態，不影響
    /// `wodDraft` 本身的任何欄位。
    @State private var showPrescriptionDetail = true
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            prescriptionSection
            timerSection
            resultSection
        }
        .padding(.top, 12)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .gymCard()
        // Same "recompute from the wall-clock deadline the instant we're
        // back in the foreground" discipline `TodayView`'s own
        // `RestTimerHeaderRow` uses -- the ticker's next 200ms tick would
        // eventually self-correct on its own even without this, but a
        // coach glancing at the screen right after unlocking the phone
        // shouldn't have to wait for that.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { timer?.sync() }
        }
        .onAppear { resumeFromAnchorIfNeeded() }
        .onDisappear { releaseTimerIfOwned() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("WOD").sectionLabelStyle()
                TextField(language.t("名稱（選填）", "Name (optional)"), text: $wodDraft.name)
                    .font(DS.F.cardTitle)
                    .foregroundStyle(DS.C.textHi)
                if let energyText {
                    Text(energyText)
                        .font(DS.F.subtitle)
                        .foregroundStyle(DS.C.textLow)
                }
            }
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(DS.C.danger)
            }
        }
    }

    /// 6 圓角小徽章——三段各自的段落標題（GymLog 改版設計 §4 元件規格：處方
    /// 用 `accentSoft`，現場／成績用 `inset`）。
    private func sectionBadge(_ text: String, tinted: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tinted ? DS.C.accent : DS.C.textMid)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tinted ? DS.C.accentSoft : DS.C.inset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - Prescription (§4: 三段之一，計時開始後收合成一行速覽)

    /// 計時器一存在就收合——不論當下是跑著還是暫停，教練此刻要看的是計時器
    /// 而不是處方細節；點速覽那一行可以隨時展開回來核對。
    private var prescriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if timer == nil || showPrescriptionDetail {
                HStack(spacing: 8) {
                    sectionBadge(language.t("處方 · PRESCRIPTION", "PRESCRIPTION"), tinted: true)
                    GymSegmentedControl(
                        selection: Binding(
                            get: { wodDraft.format },
                            set: { wodDraft.applyFormatDefaults($0) }
                        ),
                        options: WODFormat.allCases.filter { $0 != .unknown },
                        label: { $0.displayName }
                    )
                }
                formatParameters
                movementsSection
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showPrescriptionDetail = true }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                sectionBadge(language.t("處方 · PRESCRIPTION", "PRESCRIPTION"), tinted: true)
                                Text(language.t("處方速覽", "Prescription summary"))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(DS.C.textHi)
                            }
                            Text(prescriptionSummaryText)
                                .font(.system(size: 12))
                                .foregroundStyle(DS.C.textMid)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 8)
                        Text(language.t("展開", "Expand") + " ⌄")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DS.C.accent)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: timer == nil) { _, isNil in
            if isNil { showPrescriptionDetail = true }
        }
    }

    /// 「10 cal 風阻單車 · 12 次 引體向上（胸碰槓）」這種一行摘要——把所有輪
    /// 次的動作攤平列出，逗號分隔到能塞進一行為止（其餘被系統的
    /// `lineLimit(1)` 截掉，不必自己算寬度）。
    private var prescriptionSummaryText: String {
        let items = wodDraft.rounds.flatMap { round in
            round.movements.map { movement -> String in
                let name = movement.nameText.trimmingCharacters(in: .whitespacesAndNewlines)
                let qty = "\(movement.quantityValue) \(movement.quantityKind.shortName)"
                return name.isEmpty ? qty : "\(qty) \(name)"
            }
        }
        return items.isEmpty
            ? language.t("尚未加入動作", "No movements yet")
            : items.joined(separator: " · ")
    }

    // MARK: - Format-specific prescription parameters

    @ViewBuilder
    private var formatParameters: some View {
        switch wodDraft.format {
        case .amrap:
            secondsField(language.t("時限", "Time Cap"), binding: Binding(
                get: { wodDraft.timeCapSeconds ?? 720 },
                set: { wodDraft.timeCapSeconds = $0 }
            ))
        case .forTime:
            secondsField(language.t("時間上限（選填）", "Time Cap (optional)"), binding: Binding(
                get: { wodDraft.timeCapSeconds ?? 0 },
                set: { wodDraft.timeCapSeconds = $0 > 0 ? $0 : nil }
            ), allowsZeroAsNone: true)
        case .emom, .interval:
            HStack(spacing: 16) {
                secondsField(language.t("間隔長度", "Interval"), binding: Binding(
                    get: { wodDraft.intervalSeconds ?? 60 },
                    set: { wodDraft.intervalSeconds = $0 }
                ))
                Stepper(
                    "\(language.t("共", "×"))\(wodDraft.intervalCount ?? 10)\(language.t("個間隔", ""))",
                    value: Binding(get: { wodDraft.intervalCount ?? 10 }, set: { wodDraft.intervalCount = $0 }),
                    in: 1...60
                )
            }
            if wodDraft.format == .interval {
                secondsField(language.t("每段休息", "Rest per Interval"), binding: Binding(
                    get: { wodDraft.restSeconds ?? 10 },
                    set: { wodDraft.restSeconds = $0 }
                ))
            }
        case .unknown:
            EmptyView()
        }
    }

    private func secondsField(_ label: String, binding: Binding<Int>, allowsZeroAsNone: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(DS.C.textMid)
            Stepper(RepTarget.formatSeconds(binding.wrappedValue), value: binding, in: 0...7200, step: 15)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.C.textHi)
        }
    }

    // MARK: - Movements (multi-round: 21-15-9 等)

    /// `showingAddMovementPicker` 记住"给哪一轮加动作"——多轮之后每一轮都有
    /// 自己的「加一個動作」按钮，不能只有一个全局 sheet 状态。
    private var movementsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(language.t("動作", "Movements")).sectionLabelStyle()
                Spacer()
                // 简单 WOD（只有一轮）不显示"第 1 輪"这种多余的标签和轮次管理
                // 按钮——多轮编排是进阶功能，不该让每一个普通 WOD 都多看见一层
                // 结构（反馈原文：简单 WOD 保持简洁）。
                if wodDraft.rounds.count > 1 {
                    Text(language.t("共 \(wodDraft.rounds.count) 輪", "\(wodDraft.rounds.count) rounds"))
                        .font(.system(size: 11))
                        .foregroundStyle(DS.C.textLow)
                }
            }
            // Round 容器之間 gap 16（卡片間距 10 的 1.6 倍）——組間明顯，跟組內
            // 動作行只靠 hairline 分隔、無額外間距的緊湊感拉開對比。
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(wodDraft.rounds.enumerated()), id: \.element.id) { index, round in
                    roundSection(round, index: index)
                }
            }
            Button {
                wodDraft.addRound()
            } label: {
                Label(
                    language.t("加一輪（不同數量，如 21-15-9）", "Add Round (different quantity, e.g. 21-15-9)"),
                    systemImage: "square.stack.3d.up.badge.plus"
                )
                .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.C.textMid)
        }
        // 与「添加 WOD」同一条规矩（2026-09-09）：先选动作再建行，不再先落一
        // 个空行等着教练回头去点它。
        .sheet(isPresented: $showingAddMovementPicker) {
            ExercisePickerSheet(
                allExercises: allExercises,
                initialDiscipline: .crossfit,
                onUseRawName: { name in wodDraft.addMovement(toRoundAt: addMovementRoundIndex, named: name, exercise: nil) }
            ) { exercise in
                wodDraft.addMovement(toRoundAt: addMovementRoundIndex, named: exercise.canonicalName, exercise: exercise)
            }
        }
    }

    /// GymLog 改版設計 §問題二：多輪 WOD（21-15-9 等）用編號徽章＋獨立「卡中卡」
    /// 容器分組，取代純文字「第 X 輪」，讓「組間明顯、組內緊湊」——組內動作行
    /// 之間只用 hairline 分隔、無額外間距，組與組之間才有明顯的 gap（見
    /// `movementsSection` 裡 `roundSection` 之間的 spacing）。簡單 WOD（單輪）
    /// 維持原樣不套這層容器（反饋原文：簡單 WOD 保持簡潔）。
    @ViewBuilder
    private func roundSection(_ round: WODRoundDraft, index: Int) -> some View {
        let isMultiRound = wodDraft.rounds.count > 1
        VStack(alignment: .leading, spacing: 0) {
            if isMultiRound {
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(DS.C.onAccent)
                        .frame(width: 20, height: 20)
                        .background(DS.C.accent, in: Circle())
                    Text(language.t("第 \(index + 1) 輪", "ROUND \(index + 1)"))
                        .sectionLabelStyle()
                    Spacer()
                    Button { wodDraft.moveRoundUp(id: round.id) } label: {
                        Image(systemName: "chevron.up").font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.C.textLow)
                    .disabled(index == 0)
                    Button { wodDraft.moveRoundDown(id: round.id) } label: {
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.C.textLow)
                    .disabled(index == wodDraft.rounds.count - 1)
                    Button(role: .destructive) { wodDraft.removeRound(id: round.id) } label: {
                        Image(systemName: "trash").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.C.danger)
                }
                .padding(.bottom, 8)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(round.movements.enumerated()), id: \.element.id) { movementIndex, movement in
                    if movementIndex > 0 {
                        Rectangle().fill(DS.C.hairlineSoft).frame(height: 1)
                    }
                    WODMovementRow(movement: movement, allExercises: allExercises) {
                        wodDraft.removeMovement(fromRoundAt: index, id: movement.id)
                    }
                }
            }
            Button {
                addMovementRoundIndex = index
                showingAddMovementPicker = true
            } label: {
                Label(language.t("加一個動作", "Add Movement"), systemImage: "plus.circle")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.C.accent)
            .padding(.top, 8)
        }
        .padding(isMultiRound ? 12 : 0)
        .background(isMultiRound ? DS.C.surfaceSunken : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Result (manual entry, no timer -- M3 adds live timing)

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionBadge(language.t("成績 · RESULT", "RESULT"), tinted: false)

            // 四段的标签都压到最短：分段控件把宽度平均分给四格，一格约 90pt，
            // 「未記錄／Not Recorded」和「超時 (Capped)」都会被截成「Not
            // Record…」「超時 (Capp…」——正是教练截图里那一行。上方的段落标题
            // 「成績」已经说清了这是什么，标签不必再重复解释。
            Picker(language.t("狀態", "Status"), selection: $wodDraft.status) {
                Text(language.t("未記錄", "Not Set")).tag(WODResultStatus.notRecorded)
                Text(language.t("完成", "Done")).tag(WODResultStatus.completed)
                Text(language.t("超時", "Capped")).tag(WODResultStatus.capped)
                Text(language.t("中止", "Stopped")).tag(WODResultStatus.stopped)
            }
            .pickerStyle(.segmented)

            if wodDraft.status != .notRecorded {
                resultFields
                Picker(language.t("版本", "Variant"), selection: $wodDraft.variant) {
                    Text("Rx").tag(WODVariant.rx)
                    Text(language.t("Scaled", "Scaled")).tag(WODVariant.scaled)
                    Text(language.t("未指定", "Unspecified")).tag(WODVariant.unknown)
                }
                .pickerStyle(.segmented)
                TextField(language.t("備註（選填）", "Notes (optional)"), text: $wodDraft.notes)
                    .font(.system(size: 13))
            }
        }
    }

    @ViewBuilder
    private var resultFields: some View {
        switch wodDraft.format {
        case .forTime:
            if wodDraft.status == .completed {
                secondsField(language.t("完成時間", "Finish Time"), binding: Binding(
                    get: { wodDraft.elapsedSeconds ?? 0 }, set: { wodDraft.elapsedSeconds = $0 }
                ))
            }
        case .amrap:
            HStack(spacing: 16) {
                Stepper(
                    "\(language.t("輪數", "Rounds"))：\(wodDraft.completedRounds ?? 0)",
                    value: Binding(get: { wodDraft.completedRounds ?? 0 }, set: { wodDraft.completedRounds = $0 }),
                    in: 0...999
                )
                Stepper(
                    "+\(wodDraft.partialRoundReps ?? 0)",
                    value: Binding(get: { wodDraft.partialRoundReps ?? 0 }, set: { wodDraft.partialRoundReps = $0 }),
                    in: 0...9999
                )
            }
        case .emom, .interval:
            HStack(spacing: 10) {
                Stepper(
                    "\(language.t("完成總量", "Total Completed"))：\(wodDraft.totalCompletedValue ?? 0)",
                    value: Binding(get: { wodDraft.totalCompletedValue ?? 0 }, set: { wodDraft.totalCompletedValue = $0 }),
                    in: 0...99999
                )
                // 总量的单位不能默认是「次」——划船的公尺、器械的卡、维持的秒
                // 都不是次数，混着记会让同一个 WOD 前后两次成绩没法比较
                // （工程审阅：「米和卡永遠是兩個獨立值」）。
                Menu {
                    ForEach(WorkoutQuantityKind.allCases) { kind in
                        Button {
                            wodDraft.totalCompletedQuantityKind = kind
                        } label: {
                            if wodDraft.totalCompletedQuantityKind == kind {
                                Label(kind.displayName, systemImage: "checkmark")
                            } else {
                                Text(kind.displayName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(wodDraft.totalCompletedQuantityKind.shortName)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .lineLimit(1)
                    .fixedSize()
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.C.textMid)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(DS.C.inset, in: Capsule())
                }
            }
        case .unknown:
            EmptyView()
        }
    }

    // MARK: - Live timer (M3)

    private var isTimerOwner: Bool { activeWODTimerOwnerID == wodDraft.id }
    private var timerBlockedByAnotherWOD: Bool { activeWODTimerOwnerID != nil && !isTimerOwner }

    @ViewBuilder
    private var timerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionBadge(language.t("現場計時 · LIVE TIMER", "LIVE TIMER"), tinted: false)
            if let timer {
                liveTimerControls(timer)
            } else {
                Button(language.t("開始計時", "Start Timer")) { startTimer() }
                    .buttonStyle(.gymSecondary)
                    .disabled(timerBlockedByAnotherWOD)
                if timerBlockedByAnotherWOD {
                    Text(language.t(
                        "同一時間只能有一個計時器在跑，請先結束另一個 WOD 的計時。",
                        "Only one timer can run at a time — finish the other WOD's timer first."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(DS.C.textLow)
                }
                if notificationsDenied {
                    Text(language.t(
                        "尚未授權通知，切到背景時不會收到提醒（畫面上的計時仍照常進行）。",
                        "Notifications aren't authorized — no alert will fire while backgrounded (the on-screen timer still runs normally)."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(DS.C.danger)
                }
            }
        }
    }

    /// 計時圓環——與 §1 組間休息、視覺語彙完全一致（GymLog 改版設計 §4）：
    /// AMRAP／EMOM 倒數遞減；計時完成（有上限）正著數，環反過來「填滿」代表
    /// 已用掉的比例；無上限的計時完成沒有環可畫，只顯示純數字。Interval 用
    /// `pr`（工作）／`textLow`（休息）換色，其餘一律 accent。
    private func timerRing(_ timer: WODTimerModel) -> some View {
        ZStack {
            Circle().stroke(DS.C.hairline, lineWidth: 8)
            if !timer.isCountUp {
                Circle()
                    .trim(from: 0, to: ringFraction(for: timer))
                    .stroke(ringColor(for: timer), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: timer.remainingSecondsInPhase)
            }
            VStack(spacing: 6) {
                Text(timer.displayText)
                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DS.C.textHi)
                if let cap = timer.currentPhase?.durationSeconds, wodDraft.format == .amrap || wodDraft.format == .forTime {
                    Text(language.t("時限 \(RepTarget.formatSeconds(cap))", "Cap \(RepTarget.formatSeconds(cap))"))
                        .font(.system(size: 11))
                        .foregroundStyle(DS.C.textLow)
                }
            }
        }
        .frame(width: 200, height: 200)
        .frame(maxWidth: .infinity)
    }

    private func ringFraction(for timer: WODTimerModel) -> Double {
        guard let phase = timer.currentPhase, phase.durationSeconds > 0 else { return 0 }
        let elapsedInPhase = phase.durationSeconds - timer.remainingSecondsInPhase
        let fraction = wodDraft.format == .forTime
            ? Double(elapsedInPhase) / Double(phase.durationSeconds)
            : Double(timer.remainingSecondsInPhase) / Double(phase.durationSeconds)
        return min(1, max(0, fraction))
    }

    private func ringColor(for timer: WODTimerModel) -> Color {
        guard wodDraft.format == .interval, let phase = timer.currentPhase else { return DS.C.accent }
        return phase.isWork ? DS.C.pr : DS.C.textLow
    }

    @ViewBuilder
    private func liveTimerControls(_ timer: WODTimerModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if timer.resumedFromPersistedState {
                Text(language.t(
                    "計時器已從上次的進度恢復，請核對讀數是否正確（App 可能曾被系統關閉或裝置時間曾變更）。",
                    "The timer resumed from where it left off — please double-check the reading (the app may have been killed, or the device clock may have changed)."
                ))
                .font(.system(size: 11))
                .foregroundStyle(DS.C.danger)
            }
            VStack(spacing: 10) {
                timerRing(timer)
                if let current = timer.currentPhase, timer.phases.count > 1 {
                    VStack(spacing: 2) {
                        Text(current.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.C.textHi)
                        if let next = timer.nextPhase {
                            Text(L("下一站：\(next.label)", "Next: \(next.label)"))
                                .font(.system(size: 11)).foregroundStyle(DS.C.textLow)
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                switch timer.state {
                case .idle, .paused:
                    Button(language.t("繼續", "Resume")) { resumeTimer() }
                        .buttonStyle(.gymSecondary)
                case .running:
                    Button(language.t("暫停", "Pause")) { pauseTimer() }
                        .buttonStyle(.gymSecondary)
                    if timer.phases.count > 1 {
                        Button(language.t("完成本輪", "Confirm Interval")) { confirmInterval() }
                            .buttonStyle(.gymSecondary)
                    }
                    if timer.canUndoLastAdvance {
                        Button(language.t("撤銷", "Undo")) { timer.undoLastAdvance(); wodDraft.timerAnchor = timer.makeAnchor() }
                            .buttonStyle(.gymTertiary)
                    }
                case .ended:
                    EmptyView()
                }
                Button(language.t("結束", "End")) { endTimer() }
                    .buttonStyle(.gymTertiary)
                    .foregroundStyle(DS.C.danger)
            }
        }
    }

    private func startTimer() {
        guard timer == nil, !timerBlockedByAnotherWOD else { return }
        let prescription = wodDraft.resolvedPrescription(prescriptionID: "wod-live-\(wodDraft.id.uuidString)")
        let model = WODTimerModel.forPrescription(prescription)
        model.onPhaseFinish = { [weak model] _ in
            guard let model else { return }
            wodDraft.timerAnchor = model.makeAnchor()
        }
        model.onAllPhasesFinished = {
            wodDraft.timerAnchor = nil
        }
        timer = model
        activeWODTimerOwnerID = wodDraft.id
        model.start()
        wodDraft.timerAnchor = model.makeAnchor()
        scheduleNotificationsIfPossible(model)
        withAnimation(.easeInOut(duration: 0.2)) { showPrescriptionDetail = false }
    }

    private func resumeTimer() {
        guard let timer else { return }
        timer.start()
        wodDraft.timerAnchor = timer.makeAnchor()
        scheduleNotificationsIfPossible(timer)
    }

    private func pauseTimer() {
        guard let timer else { return }
        timer.pause()
        wodDraft.timerAnchor = nil
        WODTimerNotificationScheduler.cancelAll()
    }

    private func confirmInterval() {
        guard let timer else { return }
        timer.advanceToNextPhase()
        wodDraft.timerAnchor = timer.makeAnchor()
        scheduleNotificationsIfPossible(timer)
    }

    private func endTimer() {
        guard let timer else { return }
        timer.end()
        applyTimerResultIfApplicable(timer)
        wodDraft.timerAnchor = nil
        if activeWODTimerOwnerID == wodDraft.id { activeWODTimerOwnerID = nil }
        WODTimerNotificationScheduler.cancelAll()
    }

    /// For Time reads its elapsed straight from the timer -- AMRAP/EMOM/
    /// interval keep their manual steppers as the source of truth (the
    /// timer only tells the coach WHEN to count, never auto-guesses WHAT
    /// was actually completed, per 工程审阅's "時鐘前進不改為10/10").
    private func applyTimerResultIfApplicable(_ timer: WODTimerModel) {
        guard wodDraft.format == .forTime else { return }
        wodDraft.elapsedSeconds = timer.elapsedSeconds
        if wodDraft.status == .notRecorded {
            wodDraft.status = .completed
        }
    }

    private func scheduleNotificationsIfPossible(_ timer: WODTimerModel) {
        guard !timer.isCountUp else { return }
        Task {
            let authorized = await WODTimerNotificationScheduler.requestAuthorizationIfNeeded()
            await MainActor.run { notificationsDenied = !authorized }
            guard authorized else { return }
            let deadline = Date().addingTimeInterval(TimeInterval(timer.remainingSecondsInPhase))
            WODTimerNotificationScheduler.schedulePhaseNotifications(phases: timer.phases, fromIndex: timer.currentPhaseIndex, firstPhaseDeadline: deadline)
        }
    }

    private func resumeFromAnchorIfNeeded() {
        guard timer == nil, let anchor = wodDraft.timerAnchor else { return }
        let prescription = wodDraft.resolvedPrescription(prescriptionID: "wod-live-\(wodDraft.id.uuidString)")
        let model = WODTimerModel.forPrescription(prescription)
        model.onPhaseFinish = { [weak model] _ in
            guard let model else { return }
            wodDraft.timerAnchor = model.makeAnchor()
        }
        model.onAllPhasesFinished = {
            wodDraft.timerAnchor = nil
        }
        model.restore(from: anchor)
        timer = model
        activeWODTimerOwnerID = wodDraft.id
        showPrescriptionDetail = false
        if model.state == .running {
            scheduleNotificationsIfPossible(model)
        } else {
            wodDraft.timerAnchor = nil
        }
    }

    /// Fires when this card's view identity actually goes away -- in
    /// practice that means the WOD block was deleted (`onDelete`) or the
    /// whole draft was reset (save/discard), NOT an ordinary tab switch or
    /// scroll (this app's `TabView`/plain `VStack` keep every tab's and
    /// every block's view state alive; see the file's own reasoning for why
    /// a disk-persisted anchor, not this callback, is what survives an
    /// actual app kill). Stops the ticker and releases the shared
    /// "one timer at a time" claim rather than leaving either dangling --
    /// `wodDraft` itself (and its `timerAnchor`) may already be gone too if
    /// the block was deleted, so there is nothing meaningful left to persist.
    private func releaseTimerIfOwned() {
        timer?.pause()
        if activeWODTimerOwnerID == wodDraft.id {
            activeWODTimerOwnerID = nil
        }
    }
}

/// WOD 里的一个动作行。
///
/// GymLog 改版設計 §問題二：主行合併成一行看完（動作名＋數量＋單位），「標準」
/// 常駐可見（教练现场要看动作要求，不该藏在展开区），「負重」收成徽章——未
/// 設置時是「＋ 負重」outline 膠囊、設置後換成實心徽章，兩種狀態都只是觸發
/// 展開輸入框，不常駐佔位。
///
/// 沿用 2026-09-09 的两条既有原则：
/// 1. 单位选择器自绘胶囊 `Menu`，`lineLimit(1) + fixedSize()`，宽度由内容
///    决定，不会被压到折行。
/// 2. 动作名这一行整条就是选动作的入口（`ExercisePickerSheet`，预设
///    CrossFit 筛选），自由文本仍然可用（`onUseRawName`）。
private struct WODMovementRow: View {
    @Bindable var movement: WODMovementDraft
    let allExercises: [Exercise]
    var onDelete: () -> Void

    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant
    @State private var showingExercisePicker = false
    /// 負重／標準的編輯輸入框折進這個展開區——「標準」的顯示文字本身不受這個
    /// 開關影響（見 body 裡的常駐 `standard` 文字），這裡只控制「負重 kg 輸入
    /// 框＋標準文字輸入框」這組編輯 UI 的展開/收合。有負重時自動展開一次，
    /// 避免教练录了负重、切换视图再回来发现"看起来消失了"。
    @State private var showingMore = false

    private var hasName: Bool {
        !movement.nameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var trimmedStandard: String {
        movement.standard.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var loadBadgeText: String? {
        guard let kg = movement.loadKg else { return nil }
        let raw = kg == kg.rounded() ? String(format: "%.0f", kg) : String(format: "%.1f", kg)
        return "\(raw)kg"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                // 2026-09-09 教练反馈：「默认的 Movement 点击后依然不可选，必须
                // 点 Pick 才能选……这个 Pick 应该以合适的方式直接放在默认的
                // Movement Name 选项里」。所以动作名这一行整条就是选动作的入口，
                // 右边那个单独的「選動作」胶囊随之取消——一个功能一个入口。
                //
                // 自由文本没有丢：面板里搜不到时可以选「直接使用「…」」，只当作
                // 这个 WOD 的动作名、不入库（`onUseRawName`）。已经手打过名字的
                // 动作再点进来时，把它填进搜索框，改一个字不用整句重打。
                Button {
                    showingExercisePicker = true
                } label: {
                    Text(hasName ? movement.nameText : language.t("選擇動作", "Choose a movement"))
                        .font(.system(size: 15, weight: hasName ? .semibold : .regular))
                        .foregroundStyle(hasName ? DS.C.textHi : DS.C.textLow)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(language.t("動作名稱", "Movement name"))
                .accessibilityValue(hasName ? movement.nameText : language.t("未選擇", "Not chosen"))

                // 數量＋單位與動作名合併在同一行「一眼看完」——移除原本的 inset
                // 膠囊底色，讓它們讀起來像動作名之後接續的次要信息，而不是三個
                // 各自獨立的控件。
                TextField(language.t("數量", "Qty"), value: $movement.quantityValue, format: .number)
                    .keyboardType(.numberPad)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(DS.C.textMid)
                    .multilineTextAlignment(.trailing)
                    .fixedSize()

                Menu {
                    ForEach(WorkoutQuantityKind.allCases) { kind in
                        Button {
                            movement.quantityKind = kind
                        } label: {
                            if movement.quantityKind == kind {
                                Label(kind.displayName, systemImage: "checkmark")
                            } else {
                                Text(kind.displayName)
                            }
                        }
                    }
                } label: {
                    Text(movement.quantityKind.shortName)
                        // 这一行是这次修版面的核心：宽度由内容决定，永远不折行。
                        .lineLimit(1)
                        .fixedSize()
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.C.textMid)
                }
                .accessibilityLabel(language.t("記錄單位", "Unit"))
                .accessibilityValue(movement.quantityKind.displayName)

                Spacer(minLength: 4)

                // 負重：未設置顯示 outline 膠囊觸發展開；已設置換成實心徽章，
                // 兩者都只是「展開輸入框」的入口，不是負重本身的展示終點。
                if let loadBadgeText {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showingMore.toggle() }
                    } label: {
                        HStack(spacing: 3) {
                            Text(loadBadgeText)
                            Image(systemName: showingMore ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .lineLimit(1)
                        .fixedSize()
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DS.C.onAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(DS.C.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showingMore = true }
                    } label: {
                        Text(language.t("＋ 負重", "+ Load"))
                            .lineLimit(1)
                            .fixedSize()
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(DS.C.accent)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .overlay(Capsule().stroke(DS.C.accent.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(DS.C.danger)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(language.t("刪除這個動作", "Delete movement"))
            }

            // 「標準」常駐顯示——教练现场扫一眼就能看到动作要求，不再需要多點
            // 一次展開（GymLog 改版設計 §問題二：标准不再藏进展开区）。
            if !trimmedStandard.isEmpty {
                Text(trimmedStandard)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DS.C.textLow)
            }

            if showingMore {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(language.t("負重", "Load")).font(.system(size: 11)).foregroundStyle(DS.C.textLow)
                        TextField(
                            "kg",
                            value: Binding(get: { movement.loadKg }, set: { movement.loadKg = $0 }),
                            format: .number
                        )
                        .keyboardType(.decimalPad)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DS.C.textHi)
                        .multilineTextAlignment(.center)
                        .frame(width: 56)
                        .padding(.vertical, 4)
                        .background(DS.C.inset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text("kg").font(.system(size: 11)).foregroundStyle(DS.C.textLow)
                        if movement.loadKg != nil {
                            Button(language.t("清除", "Clear")) { movement.loadKg = nil }
                                .font(.system(size: 11))
                                .foregroundStyle(DS.C.textLow)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(language.t("標準", "Standard")).font(.system(size: 11)).foregroundStyle(DS.C.textLow)
                        TextField(language.t("如 胸碰槓、24吋箱", "e.g. chest-to-bar, 24in box"), text: $movement.standard)
                            .font(.system(size: 12))
                            .foregroundStyle(DS.C.textHi)
                    }
                }
                .padding(8)
                .background(DS.C.inset.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.vertical, 7)
        .onAppear {
            // 已经带负重的既有记录（比如从历史打开继续编辑）默认展开输入框，
            // 不让教练以为数据不见了。
            if movement.loadKg != nil { showingMore = true }
        }
        .sheet(isPresented: $showingExercisePicker) {
            ExercisePickerSheet(
                allExercises: allExercises,
                initialDiscipline: .crossfit,
                // 只有"教练自己打的名字"才回填搜索框：从库里选过的动作再点进来
                // 时，预填它的名字会把列表过滤成只剩自己，反而挡住换一个动作。
                onUseRawName: { name in
                    movement.exercise = nil
                    movement.nameText = name
                },
                initialQuery: movement.exercise == nil ? movement.nameText : ""
            ) { exercise in
                movement.applyExercise(exercise)
            }
        }
    }
}
