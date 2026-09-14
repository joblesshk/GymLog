import Foundation

/// 课后摘要（2026-09-06 审查报告"适合当前范围的功能"第二批）: "复用现有数据输出
/// 本次动作、完成情况、个人纪录和教练备注，方便分享"。
///
/// Pure text formatting only — deciding WHICH point in this session counts
/// as a new PR needs the client's full cross-session history for that
/// exercise (`ExerciseHistoryAnalyzer.points`/`prFlags`), which lives behind
/// a SwiftData `@Query` the caller already has (`SessionDetailView`); this
/// function only renders the result, via `prPointIDs` — the set of
/// `ExerciseHistoryPoint.id`s (the same "session.id#block.order#entry.order"
/// scheme `ExerciseHistoryAnalyzer` already uses) that came back flagged as
/// a PR — so the "what is a PR" rule stays defined in exactly the one place
/// CONTRACT-UI.md §4.2 already established, not re-decided here.
public enum SessionSummaryGenerator {
    public static func summary(for session: WorkoutSession, clientName: String, prPointIDs: Set<String>) -> String {
        var lines: [String] = []
        lines.append(L(
            "\(clientName) 訓練摘要 · \(isoDate(session.date)) · 第\(session.weekNumber)週",
            "\(clientName) — Session Summary · \(isoDate(session.date)) · Week \(session.weekNumber)"
        ))

        if let warmup = session.warmup, !warmup.isEmpty {
            lines.append("")
            lines.append(L("熱身：\(warmup)", "Warm-up: \(warmup)"))
            if let note = session.warmupNote, !note.isEmpty {
                lines.append(L("（\(note)）", "(\(note))"))
            }
        }

        for block in session.orderedBlocks {
            lines.append("")
            // 2026-09-07 M2 CrossFit extension: a `.wod` block has no
            // entries to enumerate (its content lives in `wodPayload`) --
            // without this branch the strength loop below silently
            // rendered just the block-type header with nothing under it
            // (documented gap, `CONTRACT-M10.md` §7, closed here).
            if block.sectionKind == .wod, let payload = block.wodPayload {
                lines.append(contentsOf: WODSummaryFormatter.detailLines(payload))
                if let note = block.note, !note.isEmpty {
                    lines.append(L("  備註：\(note)", "  Note: \(note)"))
                }
                continue
            }
            lines.append("\(block.blockType.displayName):")
            for entry in block.orderedEntries {
                let pointID = "\(session.id)#\(block.order)#\(entry.order)"
                let isPR = prPointIDs.contains(pointID)
                let setsText = entry.orderedSets
                    .map { "\($0.load.displayText)×\($0.actual.displayText)" }
                    .joined(separator: "、")
                lines.append("• \(entry.displayName)\(isPR ? L("（PR）", " (PR)") : "")：\(setsText)")
            }
            if let note = block.note, !note.isEmpty {
                lines.append(L("  備註：\(note)", "  Note: \(note)"))
            }
        }

        if let cooldown = session.cooldown, !cooldown.isEmpty {
            lines.append("")
            lines.append(L("放鬆：\(cooldown)", "Cooldown: \(cooldown)"))
            if let note = session.cooldownNote, !note.isEmpty {
                lines.append(L("（\(note)）", "(\(note))"))
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func isoDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
