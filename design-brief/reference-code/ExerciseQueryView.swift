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

                Section(L("動作", "Exercise")) {
                    Picker(L("分類", "Category"), selection: $patternFilter) {
                        Text(L("全部分類", "All Categories")).tag(MovementPattern?.none)
                        ForEach(MovementPattern.allCases.filter { $0 != .unknown }) { pattern in
                            Text(pattern.displayName).tag(Optional(pattern))
                        }
                    }
                    ForEach(filteredExercises, id: \.id) { exercise in
                        Button {
                            selectedExerciseID = exercise.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(exercise.displayName)
                                        .font(DS.F.listRow)
                                        .foregroundStyle(DS.C.textHi)
                                    Text(L("\(exercise.movementPattern.displayName) · 出現 \(exercise.occurrenceCount) 次", "\(exercise.movementPattern.displayName) · \(exercise.occurrenceCount)×"))
                                        .font(DS.F.subtitle)
                                        .foregroundStyle(DS.C.textLow)
                                }
                                Spacer()
                                if exercise.id == selectedExerciseID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(DS.C.accent)
                                }
                                if exercise.loadDirection.isInverted {
                                    Image(systemName: "arrow.down.circle")
                                        .foregroundStyle(DS.C.textMid)
                                        .help(L("越小越強", "Lower Is Stronger"))
                                }
                            }
                        }
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
                    NavigationLink {
                        destinationView
                    } label: {
                        Text(L("查看", "View"))
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.C.accent)
                    .disabled(selectedClientID == nil || selectedExerciseID == nil)
                }
            }
        }
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
