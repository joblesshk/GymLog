import SwiftUI
import SwiftData
import GymLogKit

/// Single-exercise query page — CONTRACT-UI.md §4.3: "选动作 + 选时间范围 →
/// 复用 ExerciseHistoryView". Reached from 历史 Tab's toolbar
/// (HistoryListView, M3-owned). The exercise picker is a simplified
/// independent implementation (search + movementPattern filter, not the
/// full "常用 + 两列联动" wheel), per CONTRACT-UI.md §4.3's explicit
/// allowance: "M2 若已抽出可复用组件则复用，否则各自实现，不为此产生跨流依赖".
///
/// The date range is threaded into `ExerciseHistoryView` via the
/// `exerciseHistoryInitialDateRange` environment value (defined alongside
/// that view) rather than a constructor parameter, since CONTRACT-UI.md §2
/// freezes `init(clientID:exerciseID:)` exactly as M2 depends on it.
struct ExerciseQueryView: View {
    @Query(sort: \Client.name) private var clients: [Client]
    @Query(sort: \Exercise.canonicalName) private var exercises: [Exercise]

    // 打开这页前，历史 Tab 当前选中的学员；只有这个学员不存在时才回落到
    // 按姓名排序的第一位（2026-09-06 审查报告 #5）。
    let preselectedClientID: String?

    @State private var selectedClientID: String?
    @State private var selectedExerciseID: String?
    @State private var searchText = ""
    @State private var patternFilter: MovementPattern?
    @State private var useDateRange = false
    @State private var startDate: Date = Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()
    @State private var endDate: Date = Date()

    private var filteredExercises: [Exercise] {
        var list = exercises
        if let patternFilter {
            list = list.filter { $0.movementPattern == patternFilter }
        }
        if !searchText.isEmpty {
            list = list.filter { $0.matches(searchText: searchText) }
        }
        return list.sorted { $0.occurrenceCount > $1.occurrenceCount }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L("學員", "Client")) {
                    if clients.isEmpty {
                        Text(L("暫無學員", "No Clients")).foregroundStyle(DS.C.textLow)
                    } else {
                        Picker(L("學員", "Client"), selection: $selectedClientID) {
                            ForEach(clients, id: \.id) { client in
                                Text(client.displayName).tag(Optional(client.id))
                            }
                        }
                    }
                }

                Section(L("時間範圍", "Date Range")) {
                    Toggle(L("限定時間範圍", "Limit Date Range"), isOn: $useDateRange)
                    if useDateRange {
                        DatePicker(L("起始", "Start"), selection: $startDate, displayedComponents: .date)
                        DatePicker(L("結束", "End"), selection: $endDate, displayedComponents: .date)
                    }
                }

                Section {
                    Picker(L("分類", "Category"), selection: $patternFilter) {
                        Text(L("全部分類", "All Categories")).tag(MovementPattern?.none)
                        ForEach(MovementPattern.allCases.filter { $0 != .unknown }) { pattern in
                            Text(pattern.displayName).tag(Optional(pattern))
                        }
                    }
                    ForEach(filteredExercises, id: \.id) { exercise in
                        exerciseRow(exercise)
                    }
                } header: {
                    HStack {
                        Text(L("動作", "Exercise")).sectionLabelStyle()
                        Spacer()
                        Text(L("依出現次數排序", "Sorted by frequency"))
                            .font(.system(size: 11))
                            .foregroundStyle(DS.C.textLow)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.C.canvas)
            .font(DS.F.listRow)
            .foregroundStyle(DS.C.textHi)
            .searchable(text: $searchText, prompt: L("搜索動作名", "Search exercise name"))
            .navigationTitle(L("單項查詢", "Exercise Query"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard selectedClientID == nil else { return }
                if let preselectedClientID, clients.contains(where: { $0.id == preselectedClientID }) {
                    selectedClientID = preselectedClientID
                } else {
                    selectedClientID = clients.first?.id
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // 「查看」由文字按鈕升為 accent 實心膠囊（44pt 命中區），
                    // 未選滿學員 + 動作時 40% 透明的停用態（GymLog 改版設計
                    // §7C，沿用 §3 語彙）。
                    let isReady = selectedClientID != nil && selectedExerciseID != nil
                    NavigationLink {
                        destinationView
                    } label: {
                        Text(L("查看", "View"))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(DS.C.onAccent)
                            .padding(.horizontal, 18)
                            .frame(height: 44)
                            .background(DS.C.accent, in: Capsule())
                    }
                    .disabled(!isReady)
                    .opacity(isReady ? 1 : 0.4)
                }
            }
        }
    }

    /// 動作列——套上 §3「選擇動作」面板的語彙：模式方塊、中文主行、出現次數
    /// 抽成右對齊等寬數字欄、選中改 accent 實心勾 + 淡底、`loadDirection
    /// .isInverted` 補文字說明（GymLog 改版設計 §7C）。
    private func exerciseRow(_ exercise: Exercise) -> some View {
        let isSelected = exercise.id == selectedExerciseID
        let hasOccurred = exercise.occurrenceCount > 0
        return Button {
            selectedExerciseID = exercise.id
        } label: {
            HStack(spacing: 12) {
                MovementPatternBadge(pattern: exercise.movementPattern)
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.nameZh.isEmpty ? exercise.canonicalName : exercise.nameZh)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.C.textHi)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if !exercise.nameZh.isEmpty {
                            Text(exercise.canonicalName)
                        }
                        if exercise.loadDirection.isInverted {
                            Text(L("越小越強", "Lower is stronger"))
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(DS.C.textLow)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                if hasOccurred {
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text("\(exercise.occurrenceCount)")
                            .font(.system(size: 17, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DS.C.textHi)
                        Text(L("次", "×"))
                            .font(.system(size: 10))
                            .foregroundStyle(DS.C.textLow)
                    }
                    .frame(minWidth: 34, alignment: .trailing)
                } else {
                    Text(L("未出現", "Not used"))
                        .font(.system(size: 12))
                        .foregroundStyle(DS.C.textLow)
                }
                if exercise.loadDirection.isInverted {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(DS.C.textMid)
                }
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? DS.C.accent : Color.clear)
                    .frame(width: 20)
            }
            .frame(minHeight: 56)
        }
        .listRowBackground(isSelected ? DS.C.accentSoft.opacity(0.5) : DS.C.surface)
        .opacity(hasOccurred ? 1 : 0.5)
    }

    @ViewBuilder
    private var destinationView: some View {
        if let selectedClientID, let selectedExerciseID {
            ExerciseHistoryView(clientID: selectedClientID, exerciseID: selectedExerciseID)
                .environment(\.exerciseHistoryInitialDateRange, useDateRange ? Self.encodedRange(startDate, endDate) : nil)
        } else {
            EmptyView()
        }
    }

    /// 日期选择器保留了选中那一刻的本地时分秒；两端都按训练日期编码转换后
    /// 再取 min/max，才能和训练日期（UTC 零点）比较时不遗漏边界当天
    /// （2026-09-06 审查报告 #4）。
    private static func encodedRange(_ start: Date, _ end: Date) -> ClosedRange<Date> {
        let lo = TrainingDayEncoding.utcDay(from: start)
        let hi = TrainingDayEncoding.utcDay(from: end)
        return min(lo, hi)...max(lo, hi)
    }
}
