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
    var onDelete: () -> Void

    @State private var timer: WODTimerModel?
    @State private var showingAddMovementPicker = false
    /// Which round's "加一個動作" was tapped -- the sheet itself is shared
    /// across all rounds (one `.sheet` modifier), so this is how it knows
    /// which round to append into when the picker returns.
    @State private var addMovementRoundIndex = 0
    @State private var notificationsDenied = false
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            formatParameters
            movementsSection
            timerSection
            resultSection
        }
        .padding(.top, 12)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .gymCard()
        // Same "recompute from the wall-clock deadline the instant we're
        // back in the foreground" discipline `TodayView`'s own
        // `RestTimerBar` uses -- the ticker's next 200ms tick would
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
            }
            Spacer()
            Menu {
                ForEach(WODFormat.allCases.filter { $0 != .unknown }, id: \.self) { format in
                    Button(format.displayName) { wodDraft.applyFormatDefaults(format) }
                }
            } label: {
                Text(wodDraft.format.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.C.accent)
            }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(DS.C.danger)
            }
        }
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
            ForEach(Array(wodDraft.rounds.enumerated()), id: \.element.id) { index, round in
                roundSection(round, index: index)
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

    @ViewBuilder
    private func roundSection(_ round: WODRoundDraft, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if wodDraft.rounds.count > 1 {
                HStack(spacing: 8) {
                    Text(language.t("第 \(index + 1) 輪", "Round \(index + 1)"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.C.textMid)
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
            }
            ForEach(round.movements) { movement in
                WODMovementRow(movement: movement, allExercises: allExercises) {
                    wodDraft.removeMovement(fromRoundAt: index, id: movement.id)
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
        }
        .padding(.vertical, wodDraft.rounds.count > 1 ? 8 : 0)
        .padding(.horizontal, wodDraft.rounds.count > 1 ? 8 : 0)
        .background(wodDraft.rounds.count > 1 ? DS.C.inset.opacity(0.5) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Result (manual entry, no timer -- M3 adds live timing)

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language.t("成績", "Result")).sectionLabelStyle()

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
            Text(language.t("現場計時", "Live Timer")).sectionLabelStyle()
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
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(timer.displayText)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(DS.C.textHi)
                if let current = timer.currentPhase, timer.phases.count > 1 {
                    VStack(alignment: .leading, spacing: 2) {
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
/// 2026-09-09 按教练的两条反馈重做（原来是名称、单位、数量、删除四样挤在一行）：
///
/// 1. **单位选择器会被折行**——教练的截图里 `Reps` 被断成上下两行的 `Rep`/`s`。
///    根因是 `Picker(.menu)` 的标签宽度由系统按可用空间压缩，一行 402pt 里排完
///    名称输入框就没剩多少了。这里改成两行：名称独占第一行，数量／单位／选动作
///    在第二行；单位换成自绘的胶囊 `Menu`，标签用 `WorkoutQuantityKind.shortName`
///    并锁死 `lineLimit(1) + fixedSize()`，宽度由内容决定，不再被压。
/// 2. **动作名只能手打**——选库里的动作原本只有最左边一个不起眼的列表图标。
///    现在是一个写着「選動作」的按钮，而且打开的面板默认就落在 CrossFit 筛选上
///    （`initialDiscipline:`），教练要的「主流 CrossFit movement 作为备选」在
///    这里才真正够得着。名称仍然可以直接手打——库里没有的动作照样录得进去。
private struct WODMovementRow: View {
    @Bindable var movement: WODMovementDraft
    let allExercises: [Exercise]
    var onDelete: () -> Void

    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant
    @State private var showingExercisePicker = false
    /// 负重/动作标准折进这个展开区——简单 WOD（大多数 bodyweight 动作）不需要
    /// 天天看见这两个字段，要用的时候点开就有（反馈原文：简单 WOD 保持简洁，
    /// 把负重和标准等附加字段放在适当的展开区域）。有值时自动展开一次，避免
    /// 教练录了负重、切换视图再回来发现"看起来消失了"。
    @State private var showingMore = false

    private var hasName: Bool {
        !movement.nameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasLoadOrStandard: Bool {
        movement.loadKg != nil || !movement.standard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                    HStack(spacing: 6) {
                        Text(hasName ? movement.nameText : language.t("選擇動作", "Choose a movement"))
                            .font(.system(size: 15, weight: hasName ? .semibold : .regular))
                            .foregroundStyle(hasName ? DS.C.textHi : DS.C.textLow)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(DS.C.accent)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(language.t("動作名稱", "Movement name"))
                .accessibilityValue(hasName ? movement.nameText : language.t("未選擇", "Not chosen"))

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(DS.C.danger)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(language.t("刪除這個動作", "Delete movement"))
            }

            HStack(spacing: 8) {
                TextField(language.t("數量", "Qty"), value: $movement.quantityValue, format: .number)
                    .keyboardType(.numberPad)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(DS.C.textHi)
                    .multilineTextAlignment(.center)
                    .frame(width: 62)
                    .padding(.vertical, 5)
                    .background(DS.C.inset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

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
                    HStack(spacing: 3) {
                        Text(movement.quantityKind.shortName)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    // 这两行是这次修版面的核心：宽度由内容决定，永远不折行。
                    .lineLimit(1)
                    .fixedSize()
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.C.textMid)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(DS.C.inset, in: Capsule())
                }
                .accessibilityLabel(language.t("記錄單位", "Unit"))
                .accessibilityValue(movement.quantityKind.displayName)

                Spacer(minLength: 0)

                // 负重/动作标准折进展开区——大多数 bodyweight 动作用不到，天天
                // 露在外面只会让最简单的 WOD 也显得复杂（反馈原文：简单 WOD 保持
                // 简洁）。有值时圆点常亮，提醒教练"这里其实填了东西"。
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showingMore.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Text(language.t("負重／標準", "Load/Standard"))
                        Image(systemName: showingMore ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .lineLimit(1)
                    .fixedSize()
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hasLoadOrStandard ? DS.C.accent : DS.C.textLow)
                }
                .buttonStyle(.plain)
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
                .background(DS.C.inset.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            // 已经带负重/标准的既有记录（比如从历史打开继续编辑）默认展开，
            // 不让教练以为数据不见了。
            if hasLoadOrStandard { showingMore = true }
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
