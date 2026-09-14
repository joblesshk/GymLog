import SwiftUI
import SwiftData
import GymLogKit

/// 选动作面板（2026-09-04 改造，取代原来的 `ExerciseSearchSheet`）。
///
/// 原来的版本是一整条按字母排序的全库列表 + 一个搜索框，教练的原话是"默认是
/// 按字母排列的全体运动筛选界面"，要找一个动作得一路滚。本轮按三条要求重做：
///
/// 1. **分类筛选**——顶部一行分类胶囊，跟"修改动作"用的 `ExercisePickerWheel`
///    左列同源（都走 `FrequencyAnalyzer.visibleCategories`），点「推」「拉」就
///    只剩那一类。额外多一个「常用」，按这个学员自己的历史频次排（和滚轮的
///    「常用」是同一份 `FrequencyAnalyzer.frequentExercises` 结果）。
/// 2. **全局搜索**——搜索框一旦有输入就**跨越当前分类**在全库里找（名称、中文
///    名、别名都匹配），因为"我记得叫 face pull 但不确定它被归到哪一类"正是要
///    用搜索的场景；清空搜索则回到所选分类。
/// 3. **就地新增动作**——右上角的 ＋ 常驻（不再是"搜不到才出现"的兜底入口），
///    新增时可以直接选分类/器械/记录方式，创建即写入动作库（`modelContext
///    .save()`），不用等课次保存。
struct ExercisePickerSheet: View {
    let allExercises: [Exercise]
    /// 用来算「常用」分类。传 nil（例如动作库那种与学员无关的场景）时这一栏
    /// 就不显示。
    var clientID: String? = nil
    /// 打开时预选的「訓練體系」筛选（2026-09-09）。WOD 的动作行传 `.crossfit`
    /// ——教练在 WOD 里找的是 Toes-to-bar、Double-under，不是器械飛鳥；力量录入
    /// 那一侧不传，保持「全部」。教练随时可以点别的胶囊改回来。
    var initialDiscipline: ExerciseDiscipline? = nil
    /// 「库里没有这个动作，就直接用我打的这个名字」——非 nil 时，搜索框有内容
    /// 就会多出一行「直接使用「…」」。
    ///
    /// 只有 WOD 会传：WOD 的动作名一直允许是自由文本（`WODMovementDraft
    /// .nameText`，教练可以记「Assault Bike Sprints」而不必先把它建成一个正式
    /// 动作）。力量录入必须落到一个真的 `Exercise` 上才有历史/PR 可言，所以那
    /// 一侧不给这个出口。
    var onUseRawName: ((String) -> Void)? = nil
    /// 打开时预填进搜索框的文字。用于「这个动作名是教练自己打的，现在想改一个
    /// 字」——不预填就得整句重打。从动作库里选过的动作不预填（见调用处）。
    var initialQuery: String = ""
    var onSelect: (Exercise) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    @State private var query = ""
    @State private var category: Category = .all
    /// `initialDiscipline` 只在面板第一次出现时生效一次——之后教练自己点过的
    /// 分类不能被重新覆盖掉。
    @State private var didSeedCategory = false
    @State private var showingCreate = false
    @State private var createErrorMessage: String?

    /// 分类胶囊。`all`/`frequent` 是两个不对应 `MovementPattern` 的固定项，
    /// 其余由库里实际存在的分类决定。
    private enum Category: Hashable {
        case all
        case frequent
        /// 2026-09-09：力量 / CrossFit 两个体系筛选。`.both` 的动作两边都出现
        /// （见 `ExerciseDiscipline.belongs(to:)`）。
        case discipline(ExerciseDiscipline)
        case pattern(MovementPattern)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !trimmedQuery.isEmpty }

    private var categories: [Category] {
        var items: [Category] = [.all]
        if clientID != nil { items.append(.frequent) }
        items += [.discipline(.strength), .discipline(.crossfit)]
        items += FrequencyAnalyzer.visibleCategories(allExercises: allExercises).map { Category.pattern($0) }
        return items
    }

    private func categoryLabel(_ category: Category) -> String {
        switch category {
        case .all: return language.t("全部", "All")
        case .frequent: return language.t("常用", "Frequent")
        case .discipline(let discipline): return discipline.displayName
        case .pattern(let pattern): return pattern.displayName
        }
    }

    /// 搜索优先于分类：有输入就在全库里找，没有才按分类过滤。
    private var results: [Exercise] {
        guard !isSearching else { return searchResults }
        switch category {
        case .all:
            return allExercises
        case .discipline(let discipline):
            return allExercises.filter { $0.discipline.belongs(to: discipline) }
        case .frequent:
            guard let clientID else { return allExercises }
            return FrequencyAnalyzer.frequentExercises(clientID: clientID, in: modelContext)
        case .pattern(let pattern):
            guard let clientID else {
                return allExercises.filter { $0.movementPattern == pattern }
            }
            return FrequencyAnalyzer.exercises(
                in: pattern,
                allExercises: allExercises,
                clientID: clientID,
                in: modelContext
            )
        }
    }

    private var searchResults: [Exercise] {
        allExercises.filter { $0.matches(searchText: trimmedQuery) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(results, id: \.id) { ex in
                        Button {
                            onSelect(ex)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ex.displayName)
                                    .font(DS.F.listRow)
                                    .foregroundStyle(DS.C.textHi)
                                Text(subtitle(for: ex))
                                    .font(DS.F.subtitle)
                                    .foregroundStyle(DS.C.textLow)
                            }
                        }
                        .listRowBackground(DS.C.surface)
                        .accessibilityIdentifier("exercise-row-\(ex.id)")
                    }
                } header: {
                    Text(resultsHeader)
                        .sectionLabelStyle()
                }

                // 搜不到时把"新增"直接推到眼前——右上角的 ＋ 一直都在，但教练
                // 打完一个库里没有的名字时，这里点一下就能沿用它建新动作。
                //
                // 2026-09-09：WOD 那一侧再多一个「直接使用」——教练的原话是
                // 「选不到时，再在弹出的页面里选择添加或输入运动名」，两条路
                // 摆在一起，不必先想清楚"这个动作值不值得入库"再动手。它在有
                // 搜索结果时也显示（只是排在结果后面）：库里存在一个近似名字，
                // 不等于教练想用的就是它。
                if isSearching {
                    Section {
                        if let onUseRawName {
                            Button {
                                onUseRawName(trimmedQuery)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Label(
                                        language.t("直接使用「\(trimmedQuery)」", "Just use \"\(trimmedQuery)\""),
                                        systemImage: "text.cursor"
                                    )
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(DS.C.textHi)
                                    Text(language.t("只作為這個 WOD 的動作名，不寫進動作庫", "Used as this WOD's movement name only, not added to the library"))
                                        .font(DS.F.subtitle)
                                        .foregroundStyle(DS.C.textLow)
                                }
                            }
                            .listRowBackground(DS.C.surface)
                        }
                        Button {
                            showingCreate = true
                        } label: {
                            Label(
                                language.t("新增動作「\(trimmedQuery)」到動作庫", "Add \"\(trimmedQuery)\" to the library"),
                                systemImage: "plus.circle.fill"
                            )
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DS.C.accent)
                        }
                        .listRowBackground(DS.C.surface)
                    } header: {
                        Text(language.t("找不到想要的？", "Not what you're looking for?")).sectionLabelStyle()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.C.canvas)
            .safeAreaInset(edge: .top) { categoryBar }
            .onAppear {
                guard !didSeedCategory else { return }
                didSeedCategory = true
                if let initialDiscipline { category = .discipline(initialDiscipline) }
                if query.isEmpty { query = initialQuery }
            }
            .searchable(text: $query, prompt: language.t("搜索全部動作（中英文、別名）", "Search all exercises (name or alias)"))
            .navigationTitle(language.t("選擇動作", "Select Exercise"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.t("取消", "Cancel")) { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.C.textHi)
                        .accessibilityIdentifier("exercise-picker-cancel-button")
                }
            }
            .sheet(isPresented: $showingCreate) {
                NewExerciseSheet(initialName: trimmedQuery) { draft in
                    createAndSelect(draft)
                }
            }
            .alert(language.t("新增失敗", "Create Failed"), isPresented: Binding(
                get: { createErrorMessage != nil },
                set: { if !$0 { createErrorMessage = nil } }
            )) {
                Button(language.t("好", "OK"), role: .cancel) { createErrorMessage = nil }
            } message: {
                Text(createErrorMessage ?? "")
            }
        }
    }

    /// 分类胶囊（横向滚动）+ 固定在右端的「新增動作」。
    ///
    /// ＋ 特意放在这条常驻栏里而不是导航栏：`.searchable` 一旦聚焦，导航栏
    /// 连同它上面的按钮会整条收起，教练正想"搜了半天没有，那就新建一个"的
    /// 时候恰好按不到——而这正是教练要求"在该界面保留增加运动的选项"的场景。
    private var categoryBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(categories, id: \.self) { item in
                        let isSelected = category == item && !isSearching
                        Button {
                            category = item
                            query = ""
                        } label: {
                            Text(categoryLabel(item))
                                .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                                .lineLimit(1)
                                .foregroundStyle(isSelected ? DS.C.onAccent : DS.C.textMid)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(isSelected ? DS.C.accent : DS.C.inset, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, DS.Space.pageMargin)
                .padding(.trailing, 4)
            }
            Button {
                showingCreate = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(DS.C.onAccent)
                    .frame(width: 32, height: 32)
                    .background(DS.C.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, DS.Space.pageMargin)
            .accessibilityLabel(language.t("新增動作", "Add Exercise"))
        }
        .padding(.vertical, 8)
        .background(DS.C.canvas)
    }

    private var resultsHeader: String {
        if isSearching {
            return language.t("搜索全庫 · \(results.count) 個結果", "All exercises · \(results.count) result(s)")
        }
        return language.t("\(results.count) 個動作", "\(results.count) exercises")
    }

    private func subtitle(for exercise: Exercise) -> String {
        // 搜索是跨分类的，所以结果行必须自己说明属于哪一类，否则教练看不出
        // 为什么这个动作会出现在当前这一屏。
        // 「訓練體系」只在不是纯力量时才写出来：库里 148/240 是纯力量动作，
        // 每行都缀一个「力量」等于什么都没说。
        let base = "\(exercise.movementPattern.displayName) · \(exercise.equipment.displayName)"
        guard exercise.discipline != .strength else { return base }
        return "\(base) · \(exercise.discipline.displayName)"
    }

    /// 新建动作并立刻选中。与 `ExerciseLibraryView.createCustomExercise` 的
    /// 区别：那边只是入库，这边入库之后还要回填到当前正在录入的课次里。
    /// 分类由教练在 `NewExerciseSheet` 里当场选，所以不再像旧版那样一律落成
    /// `unknown` + `needsReview`——只有教练自己没改动默认值时才标记待复核。
    private func createAndSelect(_ draft: NewExerciseDraft) {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        // 名字撞库时不再建一个重复行，直接选中已有的那个——教练手动新增出
        // 重复动作、再回头找我合并，正是这一轮要修的问题之一。
        if let existing = allExercises.first(where: {
            $0.canonicalName.caseInsensitiveCompare(trimmedName) == .orderedSame
                || $0.nameZh.caseInsensitiveCompare(trimmedName) == .orderedSame
                || $0.aliases.contains { $0.caseInsensitiveCompare(trimmedName) == .orderedSame }
        }) {
            onSelect(existing)
            dismiss()
            return
        }

        let needsReview = draft.movementPattern == .unknown
        let exercise = Exercise(
            id: "ex-local-\(UUID().uuidString.prefix(8))",
            canonicalName: trimmedName,
            aliases: [trimmedName],
            movementPattern: draft.movementPattern,
            equipment: draft.equipment,
            loadDirection: .higherIsStronger,
            isUnilateral: draft.isUnilateral,
            occurrenceCount: 0,
            needsReview: needsReview,
            reviewReason: needsReview
                ? language.t("錄入時新增，未選擇動作分類", "Added during entry without a movement category")
                : nil,
            recordingMetric: draft.recordingMetric,
            discipline: draft.discipline,
            nameZh: draft.nameZh.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        modelContext.insert(exercise)
        do {
            // 立刻落盘，这样新动作马上出现在动作库里，而不是等这堂课保存了才有
            // ——教练要的"同步记录到动作库中"。
            try modelContext.save()
            onSelect(exercise)
            dismiss()
        } catch {
            modelContext.rollback()
            createErrorMessage = error.localizedDescription
        }
    }
}

/// `NewExerciseSheet` 的表单状态。
struct NewExerciseDraft {
    var name = ""
    var nameZh = ""
    var movementPattern: MovementPattern = .unknown
    var equipment: Equipment = .other
    var recordingMetric: RecordingMetric = .reps
    var discipline: ExerciseDiscipline = .strength
    var isUnilateral = false
}

/// 就地新增动作。比动作库里那个只有一个名称输入框的 `AddExerciseSheet` 多出
/// 分类/器械/记录方式——这几项决定了这个动作在滚轮里被归到哪一类、录入时该
/// 弹次数还是时间轮，让教练当场填掉，好过事后再去动作库一个个纠正。
struct NewExerciseSheet: View {
    var initialName: String = ""
    var onCreate: (NewExerciseDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant
    @State private var draft = NewExerciseDraft()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(language.t("英文名稱（如 Seated cable facepull）", "English name"), text: $draft.name)
                    TextField(language.t("中文名稱（選填，如 坐姿繩索臉拉）", "Chinese name (optional)"), text: $draft.nameZh)
                } header: {
                    Text(language.t("名稱", "Name")).sectionLabelStyle()
                } footer: {
                    Text(language.t(
                        "兩個都填的話，動作在 App 裡會顯示成「中文名（English name）」，和內建動作庫一致。",
                        "Fill in both and the exercise shows as \"Chinese name (English name)\", the same as the built-in library."
                    ))
                    .font(DS.F.subtitle)
                    .foregroundStyle(DS.C.textLow)
                }

                Section {
                    Picker(language.t("動作分類", "Movement"), selection: $draft.movementPattern) {
                        ForEach(MovementPattern.allCases) { pattern in
                            Text(pattern.displayName).tag(pattern)
                        }
                    }
                    Picker(language.t("器械", "Equipment"), selection: $draft.equipment) {
                        ForEach(Equipment.allCases) { equipment in
                            Text(equipment.displayName).tag(equipment)
                        }
                    }
                    Picker(language.t("記錄方式", "Recorded as"), selection: $draft.recordingMetric) {
                        ForEach(RecordingMetric.allCases.filter { $0 != .unknown }) { metric in
                            Text(metric.displayName).tag(metric)
                        }
                    }
                    Picker(language.t("訓練體系", "Discipline"), selection: $draft.discipline) {
                        ForEach(ExerciseDiscipline.allCases) { discipline in
                            Text(discipline.displayName).tag(discipline)
                        }
                    }
                    Toggle(language.t("單側動作", "Unilateral"), isOn: $draft.isUnilateral)
                } header: {
                    Text(language.t("分類", "Classification")).sectionLabelStyle()
                } footer: {
                    Text(language.t(
                        "「記錄方式」決定錄入時彈出的是次數還是時間／距離／輪次。「訓練體系」決定它出現在選動作面板的「力量」還是「CrossFit」篩選裡，兩邊都會用到就選「兩者皆是」。分類留在「未分類」的話，這個動作會被標記為待復核。",
                        "\"Recorded as\" decides whether entry asks for reps, time, distance or rounds. \"Discipline\" decides whether it shows under the Strength or CrossFit filter in the picker — pick Both if you use it in either. Leaving the movement uncategorized flags the exercise for review."
                    ))
                    .font(DS.F.subtitle)
                    .foregroundStyle(DS.C.textLow)
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.C.canvas)
            .font(DS.F.listRow)
            .foregroundStyle(DS.C.textHi)
            .navigationTitle(language.t("新增動作", "New Exercise"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.t("取消", "Cancel")) { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.C.textHi)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.t("創建", "Create")) {
                        onCreate(draft)
                        dismiss()
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.C.accent)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if draft.name.isEmpty { draft.name = initialName }
            }
        }
    }
}
