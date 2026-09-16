import SwiftUI
import SwiftData
import GymLogKit

// MARK: - Energy

/// 课次详情里的「运动消耗」卡片（2026-09-15 重新设计）：一个主数字回答「这节课大约
/// 消耗多少」，一条进度说明它依据了多少已记录的组，各动作明细默认收起；估算方法、
/// MET 规则与出处放进「i」说明页，不再堆在卡片正文里。
struct EnergyReportView: View {
    let report: EnergyReport
    @State private var showBreakdown = false
    @State private var showMethod = false

    private var recordedSets: Int { report.lines.map(\.recordedSets).reduce(0, +) }
    private var totalSets: Int { report.lines.map(\.totalSets).reduce(0, +) }

    private var headline: (value: Double?, caption: String) {
        if let actual = report.actual, !report.isPartial {
            return (actual, L("完成後估算", "Completed estimate"))
        }
        if let actual = report.actual {
            return (actual, L("已記錄部分估算", "Recorded portion"))
        }
        if let planned = report.planned {
            return (planned, L("計劃估算 · 尚未記錄結果", "Planned estimate · no results yet"))
        }
        return (nil, "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                InsightCardTitle(icon: "flame.fill", title: L("運動消耗", "Activity Energy"))
                Spacer()
                Button { showMethod = true } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 17))
                        .foregroundStyle(DS.C.textLow)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("估算方法", "How this is estimated"))
            }

            if report.weightKg == nil {
                InsightNotice(
                    icon: "scalemass",
                    text: L("需要訓練當日或之前的體重記錄才能估算。可在「個人信息」新增體重。", "A body-weight record on or before this day is needed. Add one in Profile.")
                )
            } else if let value = headline.value {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("≈")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(DS.C.textLow)
                        Text("\(Int(value.rounded()))")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(DS.C.textHi)
                        Text("kcal")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DS.C.textMid)
                    }
                    Text(captionLine)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DS.C.textLow)
                    if let weightSourceLine {
                        Label(weightSourceLine, systemImage: "scalemass")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.C.textLow)
                            .accessibilityIdentifier("energy-weight-source")
                    }
                }

                if totalSets > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        ProportionBar(fraction: Double(recordedSets) / Double(totalSets), height: 6)
                        Text(L("已記錄 \(recordedSets)/\(totalSets) 組", "\(recordedSets)/\(totalSets) sets recorded"))
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(DS.C.textLow)
                    }
                }
            } else {
                InsightNotice(icon: "questionmark.circle", text: L("這節課的記錄不足以估算消耗。", "Not enough recorded detail to estimate energy."))
            }

            if !report.lines.isEmpty {
                breakdown
            }
        }
        .insightCardStyle()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("training-energy-report")
        .sheet(isPresented: $showMethod) { EnergyMethodSheet(report: report) }
    }

    private var captionLine: String {
        var parts = [headline.caption]
        if report.actual != nil, let planned = report.planned {
            parts.append(L("計劃 \(EnergyReport.display(planned))", "Plan \(EnergyReport.display(planned))"))
        }
        return parts.joined(separator: " · ")
    }

    /// Which body weight the estimate used: a dated body-metric record, or the undated
    /// starting weight from the profile (only ever used for a same-day session).
    private var weightSourceLine: String? {
        guard let weight = report.weightKg else { return nil }
        let kg = String(format: "%.1f", weight)
        if let date = report.weightDate {
            let day = date.formatted(.dateTime.year().month().day())
            return L("按體重 \(kg) kg 計算 · \(day) 的體重記錄", "Based on \(kg) kg · body-weight record from \(day)")
        }
        return L("按體重 \(kg) kg 計算 · 個人資料中的起始體重", "Based on \(kg) kg · starting weight in the profile")
    }

    private var breakdown: some View {
        let values = report.lines.map { $0.actual ?? $0.planned }
        let maximum = values.compactMap { $0 }.max() ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { showBreakdown.toggle() }
            } label: {
                HStack {
                    Text(L("各動作消耗", "By exercise"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.C.textHi)
                    Text("\(report.lines.count)")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(DS.C.textLow)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DS.C.textLow)
                        .rotationEffect(.degrees(showBreakdown ? 180 : 0))
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("energy-breakdown-toggle")
            .overlay(alignment: .top) { Rectangle().fill(DS.C.hairlineSoft).frame(height: 1) }

            if showBreakdown {
                VStack(spacing: 12) {
                    ForEach(Array(report.lines.enumerated()), id: \.element.id) { index, line in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(line.name)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(DS.C.textHi)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(values[index].map { "≈\(Int($0.rounded())) kcal" } ?? "—")
                                    .font(.system(size: 13, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(values[index] == nil ? DS.C.textLow : DS.C.textMid)
                            }
                            ProportionBar(fraction: maximum > 0 ? (values[index] ?? 0) / maximum : 0, height: 4)
                            Text([L("記錄 \(line.recordedSets)/\(line.totalSets) 組", "\(line.recordedSets)/\(line.totalSets) sets recorded"), EnergyRuleLabel.text(line.rule)].joined(separator: " · "))
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(DS.C.textLow)
                        }
                    }
                }
                .padding(.top, 4)
                .transition(.opacity)
            }
        }
    }
}

/// 估算方法说明页：假设、每个动作套用的 MET 规则和出处。
private struct EnergyMethodSheet: View {
    let report: EnergyReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(TrainingInsights.assumptions)
                    Text(L("力量 MET 是活動類別近似；每次 3 秒並非量測值，單動作誤差可能很大。WOD 僅提供整塊估算。", "Strength MET is an activity-class proxy; 3 sec/rep is assumed, and per-exercise error can be large. WOD energy is estimated at block level only."))
                } header: { Text(L("估算假設", "Assumptions")) }
                if !report.lines.isEmpty {
                    Section {
                        ForEach(report.lines) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                LabeledContent(line.name, value: EnergyRuleLabel.text(line.rule))
                                Text(EnergyRuleLabel.detail(line.rule))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: { Text(L("各動作套用規則", "Rule per exercise")) }
                }
                Section {
                    Link("Compendium of Physical Activities 2024", destination: URL(string: "https://pacompendium.com/conditioning-exercise/")!)
                    Link("ACSM 2026", destination: URL(string: "https://acsm.org/resistance-training-guidelines-update-2026/")!)
                } header: { Text(L("出處", "Sources")) }
            }
            .font(.system(size: 14))
            .navigationTitle(L("估算方法", "How It's Estimated"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("完成", "Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Human-readable names for the Compendium 2024 rule codes stored on each energy line.
enum EnergyRuleLabel {
    static func text(_ rule: String) -> String {
        let assisted = rule.hasSuffix("-assisted")
        let base = assisted ? String(rule.dropLast("-assisted".count)) : rule
        let name: String
        switch base {
        case "02020": name = L("高強度徒手", "Vigorous calisthenics")
        case "02022": name = L("中等強度徒手", "Moderate calisthenics")
        case "02024": name = L("低強度徒手", "Light calisthenics")
        case "02050": name = L("高強度負重", "Vigorous resistance")
        case "02052": name = L("深蹲／硬拉類負重", "Squat/deadlift resistance")
        case "02054": name = L("一般負重訓練", "General resistance")
        case "02058": name = L("壺鈴擺盪", "Kettlebell swings")
        case "02022-proxy": name = L("體能動作（近似）", "Conditioning (proxy)")
        case "02035-proxy": name = L("WOD 整塊（近似）", "WOD block (proxy)")
        case "unmapped": name = L("未分類，未估算", "Uncategorized, not estimated")
        default: name = base
        }
        return assisted ? L("\(name) · 已扣助力", "\(name) · assistance deducted") : name
    }

    static func detail(_ rule: String) -> String {
        let assisted = rule.hasSuffix("-assisted")
        let base = assisted ? String(rule.dropLast("-assisted".count)) : rule
        let met: String
        switch base {
        case "02020": met = "7.5"
        case "02022", "02022-proxy": met = "3.8"
        case "02024": met = "2.8"
        case "02050": met = "6.0"
        case "02052": met = "5.0"
        case "02054": met = "3.5"
        case "02058": met = "9.8"
        case "02035-proxy": met = "5.0"
        default: return L("沒有動作分類，無法套用 MET。", "No movement category, so no MET applies.")
        }
        if base == "02035-proxy" { return L("按中等強度循環訓練近似 · MET \(met)", "Approximated as moderate circuit training · MET \(met)") }
        return "Compendium \(base.replacingOccurrences(of: "-proxy", with: "")) · MET \(met)"
    }
}

// MARK: - AI review

struct TrainingInsightView: View {
    let session: WorkoutSession
    @Environment(\.modelContext) private var context
    @State private var busy = false
    @State private var error: String?
    @State private var showLimitations = false

    private var report: EnergyReport { TrainingInsights.report(session) }
    private var cloudReady: Bool { CloudVoiceConfiguration.load().hasLLM }

    // 2026-09-16：不再在卡片一出現就自動打雲端生成評價——教練翻歷史課次時
    // 每次都要等 10–30 秒、也不是每次點進來都想花這次雲端額度看 AI 評價。
    // 生成一律走 `footer` 裡「生成評價」按鈕，教練自己按。
    var body: some View {
        reviewCard
    }

    private var reviewCard: some View {
        let archive = TrainingInsights.decode(session)
        let review = archive?.review
        let outdated = review != nil && archive?.reviewFingerprint != TrainingInsights.reviewKey(session)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                InsightCardTitle(icon: "sparkles", title: L("AI 訓練評價", "AI Training Review"))
                Spacer()
                if busy {
                    StatusChip(text: L("生成中", "Generating"), fg: DS.C.textMid, bg: DS.C.inset)
                } else if outdated {
                    StatusChip(text: L("需要更新", "Outdated"), fg: DS.C.review, bg: DS.C.reviewBg)
                }
            }

            if let review {
                if outdated {
                    InsightNotice(
                        icon: "arrow.triangle.2.circlepath",
                        text: L("這節課的記錄或目標已修改，以下評價基於修改前的內容。", "This session's records or goal changed; the review below reflects the earlier version."),
                        tint: DS.C.review, background: DS.C.reviewBg
                    )
                }
                Text(review.summary)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DS.C.textHi)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                ReviewList(title: L("觀察", "Observations"), items: review.findings, numbered: false)
                ReviewList(title: L("下次建議", "Next Session"), items: review.suggestions, numbered: true)

                if !review.limitations.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            withAnimation(.snappy(duration: 0.25)) { showLimitations.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Text(L("評價依據的限制", "Limitations"))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .bold))
                                    .rotationEffect(.degrees(showLimitations ? 180 : 0))
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DS.C.textLow)
                        }
                        .buttonStyle(.plain)
                        if showLimitations {
                            ForEach(Array(review.limitations.enumerated()), id: \.offset) { _, item in
                                Text(item)
                                    .font(.system(size: 12))
                                    .foregroundStyle(DS.C.textLow)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            } else if !busy {
                Text(emptyStateText)
                    .font(.system(size: 14))
                    .foregroundStyle(DS.C.textMid)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if busy {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(L("正在分析這節訓練，通常需要 10–30 秒…", "Analyzing this session, usually 10–30 seconds…"))
                        .font(.system(size: 13))
                        .foregroundStyle(DS.C.textMid)
                }
                .padding(.vertical, 4)
            }

            if let error, !busy {
                InsightNotice(icon: "exclamationmark.triangle.fill", text: error, tint: DS.C.danger, background: DS.C.danger.opacity(0.1))
            }

            footer(archive: archive, hasReview: review != nil, outdated: outdated)
        }
        .insightCardStyle()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("training-review-card")
    }

    @ViewBuilder
    private func footer(archive: InsightArchive?, hasReview: Bool, outdated: Bool) -> some View {
        let canGenerate = cloudReady && !busy && !session.isInProgress && !report.lines.isEmpty
        VStack(alignment: .leading, spacing: 10) {
            if hasReview && !outdated {
                HStack {
                    if let date = archive?.generatedAt {
                        Text("\(archive?.model ?? "AI") · \(date.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.C.textLow)
                    }
                    Spacer()
                    Button {
                        Task { await generate() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text(L("重新生成", "Regenerate"))
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(canGenerate ? DS.C.accent : DS.C.textLow)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canGenerate)
                }
            } else if !busy {
                Button {
                    Task { await generate() }
                } label: {
                    Label(hasReview ? L("更新評價", "Update Review") : (error == nil ? L("生成評價", "Generate Review") : L("重試", "Try Again")),
                          systemImage: hasReview ? "arrow.triangle.2.circlepath" : "sparkles")
                }
                .buttonStyle(PrimaryButtonStyle(isEnabled: canGenerate))
                .disabled(!canGenerate)
                .accessibilityIdentifier("training-review-generate")
            }
            Text(L("AI 評價僅供訓練參考，不代表已檢查動作姿勢。", "AI guidance only; movement technique has not been assessed."))
                .font(.system(size: 11))
                .foregroundStyle(DS.C.textLow)
        }
    }

    private var emptyStateText: String {
        if session.isInProgress { return L("課次結束後即可生成評價。", "A review can be generated once the session is finished.") }
        if report.lines.isEmpty { return L("這節課沒有可評價的訓練記錄。", "This session has no records to review.") }
        if !cloudReady { return L("尚未設定雲端服務，無法生成 AI 評價。可在「設置」中查看雲端設定。", "The cloud service isn't configured, so a review can't be generated. See cloud settings in Settings.") }
        return L("根據這節課的計劃、實際完成、目標與近期訓練給出觀察和建議；資料不足的地方會明確說明。", "Observations and suggestions based on this plan, the recorded results, the goal and recent training, with gaps called out.")
    }

    @MainActor private func generate() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await TrainingReviewCoordinator.generate(session: session, context: context)
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Shared pieces

private struct InsightCardTitle: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(DS.C.accent)
                .frame(width: 26, height: 26)
                .background(DS.C.accentSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .font(DS.F.cardTitle)
                .foregroundStyle(DS.C.textHi)
        }
    }
}

private struct StatusChip: View {
    let text: String
    let fg: Color
    let bg: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(bg, in: Capsule())
    }
}

private struct InsightNotice: View {
    let icon: String
    let text: String
    var tint: Color = DS.C.textMid
    var background: Color = DS.C.inset

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint == DS.C.textMid ? DS.C.textMid : tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ProportionBar: View {
    let fraction: Double
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.C.inset)
                Capsule().fill(DS.C.accent)
                    .frame(width: max(fraction > 0 ? height : 0, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private struct ReviewList: View {
    let title: String
    let items: [String]
    let numbered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).sectionLabelStyle()
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if numbered {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(DS.C.accent)
                            .frame(width: 22, height: 22)
                            .background(DS.C.accentSoft, in: Circle())
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    } else {
                        Circle()
                            .fill(DS.C.accent)
                            .frame(width: 6, height: 6)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    }
                    Text(item)
                        .font(.system(size: 14))
                        .foregroundStyle(DS.C.textHi)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private extension View {
    func insightCardStyle() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }
}
