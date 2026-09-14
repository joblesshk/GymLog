import SwiftUI
import SwiftData
import GymLogKit

struct EnergyReportView: View {
    let report: EnergyReport
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("運動消耗估算", "Estimated activity energy")).font(.headline)
            LabeledContent(report.planPartial ? L("計劃（可估算部分）", "Plan (estimated portion)") : L("計劃合計", "Plan total"), value: EnergyReport.display(report.planned))
            LabeledContent(report.isPartial ? L("已記錄部分", "Recorded portion") : L("完成後估算", "Completed estimate"), value: EnergyReport.display(report.actual))
            if let weight = report.weightKg {
                Text(L("按體重 \(String(format: "%.1f", weight)) kg 估算", "Estimated at \(String(format: "%.1f", weight)) kg")).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L("請先在個人資料新增訓練當日或之前的體重記錄。", "Add a body-weight record dated on or before this session in the profile.")).font(.caption)
            }
            DisclosureGroup(L("各動作及計算依據", "Exercises and assumptions")) {
                ForEach(report.lines) { line in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(line.name).font(.subheadline)
                        Text(L("計劃 \(EnergyReport.display(line.planned)) · 已記錄 \(EnergyReport.display(line.actual))", "Plan \(EnergyReport.display(line.planned)) · Recorded \(EnergyReport.display(line.actual))")).font(.caption)
                        Text(L("記錄 \(line.recordedSets)/\(line.totalSets) · 規則 \(line.rule)", "Recorded \(line.recordedSets)/\(line.totalSets) · Rule \(line.rule)")).font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                }
                Text(TrainingInsights.assumptions).font(.caption).foregroundStyle(.secondary)
                Text(L("力量 MET 是活動類別近似；每次 3 秒並非量測值，單動作誤差可能很大。WOD 僅提供整塊估算。", "Strength MET is an activity-class proxy; 3 sec/rep is assumed, and per-exercise error can be large. WOD energy is estimated at block level only.")).font(.caption).foregroundStyle(.secondary)
                Link("Compendium 2024", destination: URL(string: "https://pacompendium.com/conditioning-exercise/")!)
                Link("ACSM 2026", destination: URL(string: "https://acsm.org/resistance-training-guidelines-update-2026/")!)
            }
        }.font(.subheadline).accessibilityIdentifier("training-energy-report")
    }
}

struct TrainingInsightView: View {
    let session: WorkoutSession
    @Environment(\.modelContext) private var context
    @State private var busy = false
    @State private var error: String?
    @State private var attemptedKey: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EnergyReportView(report: TrainingInsights.report(session))
            Divider()
            Text(L("AI 訓練評價", "AI training review")).font(.headline)
            if let archive = TrainingInsights.decode(session), let review = archive.review {
                if archive.reviewFingerprint != TrainingInsights.reviewKey(session) {
                    Text(L("記錄或背景已改變，以下為舊評價，請更新。", "Records or context changed; this review needs updating.")).font(.caption).foregroundStyle(.orange)
                }
                Text(review.summary)
                ForEach(Array(review.findings.enumerated()), id: \.offset) { _, s in Text("• " + s) }
                Text(L("下次建議", "Next session")).font(.subheadline.bold())
                ForEach(Array(review.suggestions.enumerated()), id: \.offset) { _, s in Text("• " + s) }
                ForEach(Array(review.limitations.enumerated()), id: \.offset) { _, s in Text(s).font(.caption).foregroundStyle(.secondary) }
                if let date = archive.generatedAt { Text("\(archive.model ?? "DeepSeek") · \(date.formatted())").font(.caption2).foregroundStyle(.secondary) }
            } else {
                Text(L("依據本次計劃、已填結果、目標與近期記錄生成；資料不足會明確說明。", "Uses this plan, recorded results, goal and recent history, with missing evidence identified.")).font(.caption).foregroundStyle(.secondary)
            }
            if busy { ProgressView(L("正在生成評價…", "Generating review…")) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Button(L("生成／更新評價", "Generate / refresh review")) { Task { await generate() } }
                .disabled(busy || session.isInProgress || TrainingInsights.report(session).lines.isEmpty)
            Text(L("AI 評價供訓練參考；不代表已檢查動作姿勢。", "AI training guidance; movement technique has not been assessed.")).font(.caption2).foregroundStyle(.secondary)
        }
        .task(id: session.id) {
            let key = TrainingInsights.reviewKey(session)
            guard !session.isInProgress, TrainingInsights.decode(session)?.review == nil, attemptedKey != key, !TrainingInsights.report(session).lines.isEmpty else { return }
            attemptedKey = key
            await generate()
        }
    }
    @MainActor private func generate() async {
        guard !busy else { return }; busy = true; error = nil
        defer { busy = false }
        do {
            try await TrainingReviewCoordinator.generate(session: session, context: context)
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
