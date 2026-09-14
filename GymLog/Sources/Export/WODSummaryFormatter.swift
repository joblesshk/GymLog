import Foundation

/// Shared "how does one WOD block read as text" formatting -- used by
/// `SessionDetailView`/`HistoryListView` (app target), `SessionSummaryGenerator`,
/// and `HistoryCSVExporter`, so the four never independently invent slightly
/// different renderings of the same `WODPayload` (工程审阅 §6's history list
/// example: "力量 + AMRAP 12:00 · 5輪+12次 · Scaled").
///
/// Pure formatting only, same division of labor `SessionSummaryGenerator`
/// already documents for strength entries: deciding what a value MEANS
/// (e.g. "is this a PR") stays elsewhere; this only renders already-decided
/// values into consistent text.
public enum WODSummaryFormatter {
    /// One-line summary, e.g. `"AMRAP 12:00 · 5輪+12次 · Scaled"` or
    /// `"For Time 8:32 · Rx"` or `"EMOM 12×60s · 未記錄"`.
    public static func compactSummary(_ payload: WODPayload) -> String {
        let prescription = payload.prescription
        let result = payload.result
        var parts: [String] = [formatHeader(prescription)]
        if let scoreText = scoreText(prescription: prescription, result: result) {
            parts.append(scoreText)
        }
        if result.status != .notRecorded, result.variant != .unknown {
            parts.append(result.variant.displayName)
        }
        return parts.joined(separator: " · ")
    }

    private static func formatHeader(_ prescription: WODPrescription) -> String {
        switch prescription.format {
        case .amrap:
            return "AMRAP \(RepTarget.formatSeconds(prescription.timeCapSeconds ?? 0))"
        case .forTime:
            if let cap = prescription.timeCapSeconds {
                return L("計時完成（上限\(RepTarget.formatSeconds(cap))）", "For Time (cap \(RepTarget.formatSeconds(cap)))")
            }
            return L("計時完成", "For Time")
        case .emom:
            return "EMOM \(prescription.intervalCount ?? 0)×\(prescription.intervalSeconds ?? 0)s"
        case .interval:
            return L(
                "間歇 \(prescription.intervalSeconds ?? 0)s/\(prescription.restSeconds ?? 0)s×\(prescription.intervalCount ?? 0)",
                "Interval \(prescription.intervalSeconds ?? 0)s/\(prescription.restSeconds ?? 0)s×\(prescription.intervalCount ?? 0)"
            )
        case .unknown:
            return L("未知形式", "Unknown Format")
        }
    }

    /// `nil` when there's nothing meaningful to say about the score yet
    /// (`.notRecorded`) -- callers append `未記錄`/`Not Recorded` themselves
    /// where that reads better inline, or omit the segment entirely.
    private static func scoreText(prescription: WODPrescription, result: WODResult) -> String? {
        switch result.status {
        case .notRecorded:
            return L("未記錄", "Not Recorded")
        case .completed:
            switch prescription.format {
            case .forTime:
                return result.elapsedSeconds.map { RepTarget.formatSeconds($0) } ?? L("已完成", "Completed")
            case .amrap:
                return amrapProgressText(result)
            case .emom, .interval, .unknown:
                return totalText(result) ?? L("已完成", "Completed")
            }
        case .capped:
            return L("超時（Capped）", "Capped")
        case .stopped:
            return L("中止", "Stopped")
        case .unknown:
            return nil
        }
    }

    private static func amrapProgressText(_ result: WODResult) -> String {
        let rounds = result.completedRounds ?? 0
        guard let partial = result.partialRoundQuantity, partial.value ?? 0 > 0 else {
            return L("\(rounds) 輪", "\(rounds) rounds")
        }
        return L("\(rounds) 輪 + \(partial.displayText)", "\(rounds) rounds + \(partial.displayText)")
    }

    private static func totalText(_ result: WODResult) -> String? {
        guard let first = result.typedTotals.first else { return nil }
        return L("共 \(first.displayText)", "Total \(first.displayText)")
    }

    /// Multi-line detail text for sharing (`SessionSummaryGenerator`) --
    /// prescription's movement list, then the score line, then notes.
    public static func detailLines(_ payload: WODPayload) -> [String] {
        var lines: [String] = [formatHeader(payload.prescription)]
        let rounds = payload.prescription.rounds
        // 多轮处方（21-15-9）逐轮列出，标注轮次编号；只有一轮时保持原来的
        // 平铺列表，不给最常见的简单 WOD 多加一层没用的"第 1 輪"标题。
        for (roundIndex, round) in rounds.enumerated() {
            if rounds.count > 1 {
                lines.append(L("  第 \(roundIndex + 1) 輪：", "  Round \(roundIndex + 1):"))
            }
            for movement in round.movements {
                var line = "  \u{2022} \(movement.exerciseNameSnapshot) \u{00d7} \(movement.quantity.displayText)"
                if let load = movement.load {
                    line += " @ \(load.displayText)"
                }
                lines.append(line)
            }
        }
        if let score = scoreText(prescription: payload.prescription, result: payload.result) {
            lines.append(L("  成績：\(score)", "  Score: \(score)"))
        }
        if let notes = payload.result.notes, !notes.isEmpty {
            lines.append(L("  備註：\(notes)", "  Notes: \(notes)"))
        }
        return lines
    }
}
