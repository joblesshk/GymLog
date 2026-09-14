import SwiftUI
import SwiftData
import GymLogKit

/// CONTRACT-UI.md §3.1: 动作 wheel, two columns linked -- left column is
/// category (「常用」 first, then the `MovementPattern`s present in the
/// library), right column is that category's exercises, ordered by this
/// client's usage frequency. A search entry above the wheel covers "录入全新
/// 动作" (CONTRACT-UI.md's explicit exception to "no free text" for the
/// entry flow).
struct ExercisePickerWheel: View {
    @Binding var exercise: Exercise
    let clientID: String
    /// 2026-09-11 P0 崩溃修复：搜索改由呼叫方（`EntryRowView`）在同一個單一
    /// `.sheet(item:)` 裡切換到搜索面板，而不是這個 wheel 自己在已经身处一個
    /// `.sheet` 內容裡的時候再疊一層 `.sheet` ——兩層獨立的 `.sheet`
    /// 各自持有自己的 `NavigationStack`/`Environment(\.dismiss)`，其中內層在
    /// `onSelect` 裡「先改父層綁定、緊接著 dismiss 自己」，等於在外層 sheet
    /// 的一次重繪視窗裡同時觸發「子 sheet 關閉動畫」與「父視圖因為 binding
    /// 變化而重新計算 body（連帶重新求值外層 wheel Picker 的 selection/內容）」
    /// ——沒有真機崩潰堆疊可核對，但這正是 SwiftUI wheel Picker + 疊層 sheet
    /// 最常見的一類崩潰誘因，且這條「修改動作」路徑是全庫唯一一處疊了兩層
    /// `.sheet` 的入口（其餘全部呼叫端都是單層直接呈現 `ExercisePickerSheet`，
    /// 未見同類崩溃報告）。改為只呼叫這個閉包，讓外層決定如何呈現，結構上
    /// 保證同一時間只有一個 `.sheet` 在呈現。
    var onRequestSearch: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Exercise.canonicalName) private var allExercises: [Exercise]

    // Stable internal sentinel for the "frequently used" category tab --
    // kept separate from its displayed label (`L("常用", "Frequent")`) so the
    // `selectedCategory == frequentCategoryID` comparisons below never break
    // when the coach switches language.
    private static let frequentCategoryID = "__frequent__"
    @State private var selectedCategory: String = ExercisePickerWheel.frequentCategoryID

    private var frequentExercises: [Exercise] {
        FrequencyAnalyzer.frequentExercises(clientID: clientID, in: modelContext)
    }

    private var categories: [CategoryItem] {
        var items = [CategoryItem(id: Self.frequentCategoryID, displayName: L("常用", "Frequent"))]
        items += FrequencyAnalyzer.visibleCategories(allExercises: allExercises).map {
            CategoryItem(id: $0.rawValue, displayName: $0.displayName)
        }
        return items
    }

    private var rightColumnExercises: [Exercise] {
        if selectedCategory == Self.frequentCategoryID {
            return frequentExercises
        }
        guard let pattern = MovementPattern(rawValue: selectedCategory) else { return [] }
        return FrequencyAnalyzer.exercises(in: pattern, allExercises: allExercises, clientID: clientID, in: modelContext)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(L("動作", "Exercise")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    onRequestSearch()
                } label: {
                    Label(L("搜索", "Search"), systemImage: "magnifyingglass")
                        .labelStyle(.iconOnly)
                }
                .accessibilityIdentifier("exercise-picker-search-button")
            }
            HStack(spacing: 0) {
                Picker(L("分類", "Category"), selection: $selectedCategory) {
                    ForEach(categories) { cat in
                        Text(cat.displayName).tag(cat.id)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)

                Picker(L("動作", "Exercise"), selection: Binding<String>(
                    get: { exercise.id },
                    set: { newID in
                        if let found = rightColumnExercises.first(where: { $0.id == newID }) {
                            exercise = found
                        }
                    }
                )) {
                    ForEach(rightColumnExercises, id: \.id) { ex in
                        Text(ex.displayName).tag(ex.id)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            selectedCategory = initialCategory(for: exercise)
        }
    }

    /// Which left-column tab to highlight for an already-chosen exercise
    /// (e.g. one that arrived via prefill or search): 常用 if it's in that
    /// client's frequent list (the most common access path), else its own
    /// category.
    private func initialCategory(for exercise: Exercise) -> String {
        if frequentExercises.contains(where: { $0.id == exercise.id }) {
            return Self.frequentCategoryID
        }
        return exercise.movementPattern.rawValue
    }
}

private struct CategoryItem: Identifiable {
    let id: String
    let displayName: String
}

#Preview {
    Text("ExercisePickerWheel preview needs a ModelContainer")
}
