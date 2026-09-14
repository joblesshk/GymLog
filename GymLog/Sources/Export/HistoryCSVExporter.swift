import Foundation

/// Coach-facing export of one client's full recorded training history to a
/// CSV file ("历史里面需要增加一个功能，把已经输入或记载的历史输出出来"). CSV rather
/// than an `.xlsx` matching the original import format -- the codebase only
/// ever built an XLSX *reader* (M7's `ZipArchiveReader`/`XLSXWorkbook`), no
/// writer, and CSV opens natively in Excel/Numbers/Sheets with far less new
/// surface than hand-rolling OOXML output would need.
public enum HistoryCSVExporter {
    /// One row per `SetLog` -- the most granular real unit of "recorded
    /// history" -- carrying its session/block/entry context on every row so
    /// the file is self-contained (no separate header sheet, unlike the
    /// original coach spreadsheet).
    public static func csv(for client: Client) -> String {
        var lines: [String] = [headerRow]

        let sessions = (client.sessions ?? []).sorted { $0.date < $1.date }
        for session in sessions {
            let dateText = isoDate(session.date)
            for block in session.orderedBlocks {
                let blockNote = block.note ?? ""
                // 2026-09-07 M2 CrossFit extension: a `.wod` block has no
                // `ExerciseEntry`/`SetLog` rows to enumerate below (its
                // content lives in `wodPayload`) -- one summary row per WOD
                // block, using the same column shape rather than exploding
                // per movement, is this v1's documented CSV granularity
                // (`CONTRACT-M10.md` §7); without this branch the block
                // silently contributed zero rows.
                if block.sectionKind == .wod, let payload = block.wodPayload {
                    // 跨全部轮次去重后的动作名——21-15-9 这类多轮处方共享同一组
                    // 动作，之前只看第一轮不会漏动作，但一旦多轮处方彼此动作不同
                    // （比如 EMOM 站点轮换）就会漏掉后面几轮才出现的动作。
                    let movementNames = payload.prescription.uniqueMovementNames.joined(separator: "+")
                    lines.append(row([
                        dateText,
                        "\(session.weekNumber)",
                        "WOD",
                        movementNames.isEmpty ? (payload.prescription.name ?? "WOD") : movementNames,
                        "-",
                        "-",
                        WODSummaryFormatter.compactSummary(payload),
                        payload.result.variant.displayName,
                        blockNote,
                    ]))
                    continue
                }
                for entry in block.orderedEntries {
                    let exercise = entry.displayName
                    for set in entry.orderedSets {
                        lines.append(row([
                            dateText,
                            "\(session.weekNumber)",
                            block.blockType.displayName,
                            exercise,
                            "\(set.setIndex + 1)",
                            set.load.displayText,
                            set.target.displayText,
                            set.actual.displayText,
                            blockNote,
                        ]))
                    }
                }
            }
        }

        // UTF-8 BOM so Excel (especially on Windows) auto-detects UTF-8
        // instead of mis-decoding the Chinese text as the system codepage.
        return "\u{FEFF}" + lines.joined(separator: "\r\n")
    }

    public static func data(for client: Client) -> Data {
        Data(csv(for: client).utf8)
    }

    /// Writes the export to a fresh temp file and returns its URL, for
    /// handing straight to a share sheet. Caller owns cleanup (the OS
    /// periodically reclaims `temporaryDirectory` anyway).
    public static func writeTempFile(for client: Client) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(suggestedFileName(for: client))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data(for: client).write(to: url, options: .atomic)
        return url
    }

    /// Filename convention: client name + export date, sanitized so it's
    /// safe as a Files/AirDrop/Mail attachment name.
    public static func suggestedFileName(for client: Client, exportedAt date: Date = Date()) -> String {
        let safeName = client.displayName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(safeName)_訓練歷史_\(isoDate(date)).csv"
    }

    private static let headerRow = row(["日期", "週數", "訓練塊類型", "動作", "組別", "重量", "目標", "實際", "備註"])

    private static func row(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",")
    }

    /// RFC 4180 field escaping: quote if the field contains a comma, quote,
    /// or newline; double up any embedded quotes.
    private static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func isoDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
