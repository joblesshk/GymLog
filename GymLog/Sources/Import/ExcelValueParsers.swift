import Foundation

/// One parsed `LoadValue` plus the audit metadata `migrate.py` tracks
/// alongside it (CONTRACT.md §9's per-cell audit trail, carried here as a
/// return value instead of a side-table since the Swift importer builds
/// `needsReview`/`reviewReason` directly onto the model objects it creates).
public struct ParsedLoadValue {
    public let value: LoadValue
    public let needsReview: Bool
    public let reviewReason: String?
}

public struct ParsedRepTarget {
    public let value: RepTarget
    public let needsReview: Bool
    public let reviewReason: String?
}

public struct ParsedSetsCell {
    public let sets: Int?
    public let raw: String
    public let needsReview: Bool
}

/// CONTRACT-M7.md §3.4: a function-for-function port of `migrate.py`'s
/// §7.6/§7.7/§8 cell-value parsers. Every regex, threshold, and branch order
/// below mirrors the Python source exactly -- see `migration/migrate.py`'s
/// "RepTarget parsing" and "Sets / Rest parsing" sections for the
/// line-by-line original. Parity with that file (not with what "seems
/// reasonable" in Swift) is enforced by `M7ExcelValueParserTests` and, at
/// the whole-workbook level, `M7WorkbookParityTests`.
public enum ExcelValueParsers {
    // MARK: - §7.6 LoadValue

    private static let bandColors = [
        "red", "green", "blue", "yellow", "orange", "purple", "pink",
        "black", "light green", "light blue",
    ]
    private static let bandAbbreviations: [String: String] = [
        "g": "green", "b": "blue", "o": "orange", "p": "purple", "r": "red",
    ]
    private static let lbToKg = 0.45359237

    /// `raw_text`: the exact cell text for a single, already-unsplit
    /// component (a superset's per-component segment, or the whole cell for
    /// a single-exercise block). `exerciseNameLower` gates the `sled` kind.
    public static func parseLoadValue(_ rawText: String?, exerciseNameLower: String) -> ParsedLoadValue {
        let raw = rawText ?? ""
        let text = raw.trimmingCharacters(in: .whitespaces)

        if text.isEmpty || text == "/" {
            return ParsedLoadValue(value: .unknown(raw: raw), needsReview: false, reviewReason: nil)
        }

        if wholeMatch(#"^b\.?w\.?$"#, text, caseInsensitive: true) != nil {
            return ParsedLoadValue(value: .bodyweight(raw: raw), needsReview: false, reviewReason: nil)
        }

        if let m = wholeMatch(#"^(\d+(?:\.\d+)?)\s*lbs?$"#, text, caseInsensitive: true), let lbs = Double(m[1]) {
            let kg = (lbs * lbToKg * 10000).rounded() / 10000
            return ParsedLoadValue(value: .absolute(kg: kg, raw: raw), needsReview: false, reviewReason: nil)
        }

        if let m = wholeMatch(#"^(\d+(?:\.\d+)?)\s*each$"#, text, caseInsensitive: true), let kg = Double(m[1]) {
            return ParsedLoadValue(value: .perSide(kg: kg, raw: raw), needsReview: false, reviewReason: nil)
        }

        if let m = wholeMatch(#"^single\s+(\d+(?:\.\d+)?)$"#, text, caseInsensitive: true), let kg = Double(m[1]) {
            return ParsedLoadValue(value: .perSide(kg: kg, raw: raw), needsReview: false, reviewReason: nil)
        }

        if wholeMatch(#"^(?:\d+\s*(?:red|green|blue|yellow|orange|purple|pink|black)\s*){2,}$"#, text, caseInsensitive: true) != nil {
            return ParsedLoadValue(value: .pinLoad(desc: text, raw: raw), needsReview: false, reviewReason: nil)
        }

        let bandPattern = "^(\\d+)?\\s*(" + bandColors.map { $0.replacingOccurrences(of: " ", with: "\\s*") }.joined(separator: "|") + ")\\s*$"
        if let m = wholeMatch(bandPattern, text, caseInsensitive: true) {
            let count = m[1].isEmpty ? 1 : (Int(m[1]) ?? 1)
            let color = normalizeWhitespace(m[2]).lowercased()
            return ParsedLoadValue(value: .band(color: color, count: count, raw: raw), needsReview: false, reviewReason: nil)
        }

        if text.contains("+") {
            let tokens = text.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
            if tokens.count >= 2 {
                let resolved: [(color: String?, wasAbbreviation: Bool)] = tokens.map(resolveBandComponent)
                if resolved.allSatisfy({ $0.color != nil }) {
                    let components = resolved.compactMap { $0.color }.sorted()
                    let usedAbbreviation = resolved.contains { $0.wasAbbreviation }
                    let colorString = components.joined(separator: "+")
                    let value = LoadValue.band(color: colorString, count: components.count, raw: raw)
                    if usedAbbreviation {
                        return ParsedLoadValue(
                            value: value, needsReview: true,
                            reviewReason: "abbreviation expanded per §7.9 (G/B/O/P/R -> full color name) — an inference, well-supported by this exercise's own fully-spelled variants, but confirm with the coach"
                        )
                    }
                    return ParsedLoadValue(value: value, needsReview: false, reviewReason: nil)
                }
            }
        }

        if wholeMatch(#"^machine$"#, text, caseInsensitive: true) != nil {
            return ParsedLoadValue(value: .machineStack(level: text, raw: raw), needsReview: false, reviewReason: nil)
        }

        if let m = wholeMatch(#"^rack\s*(\d+)?$"#, text, caseInsensitive: true) {
            let level = m[1].isEmpty ? text : m[1]
            return ParsedLoadValue(value: .machineStack(level: level, raw: raw), needsReview: false, reviewReason: nil)
        }

        if let m = wholeMatch(#"^(\d+(?:\.\d+)?)$"#, text, caseInsensitive: false), let kg = Double(m[1]) {
            if exerciseNameLower.contains("sled") {
                return ParsedLoadValue(value: .sled(kg: kg, raw: raw), needsReview: false, reviewReason: nil)
            }
            return ParsedLoadValue(value: .absolute(kg: kg, raw: raw), needsReview: false, reviewReason: nil)
        }

        return ParsedLoadValue(
            value: .unknown(raw: raw), needsReview: true,
            reviewReason: "text does not match any documented LoadValue pattern (§7.6) — needs human interpretation"
        )
    }

    private static func resolveBandComponent(_ token: String) -> (color: String?, wasAbbreviation: Bool) {
        let t = normalizeWhitespace(token).lowercased()
        if t.count == 1, let expanded = bandAbbreviations[t] {
            return (expanded, true)
        }
        if bandColors.contains(t) {
            return (t, false)
        }
        return (nil, false)
    }

    // MARK: - §7.7 / §8.2 / §8.3 RepTarget

    private static let serialMin = 45000
    private static let serialMax = 46600
    private static let suspectNumericThreshold = 1000.0

    private static func rangeBoundsOK(_ low: Int, _ high: Int) -> Bool {
        low >= 1 && low < high && high <= 60
    }

    /// §8.2: date serial -> date -> (month, day) -> `.range(month, day)`,
    /// with BOTH required bounds checks (constraint 1: the reconstructed
    /// range itself must look like a real rep range; constraint 2: the
    /// serial must fall within this workbook's plausible date span -- this
    /// is what catches the two `56789` corrupted values, which pass
    /// constraint 1 alone).
    public static func parseRepTargetFromSerial(_ serial: Int, raw: String) -> ParsedRepTarget {
        guard serialMin <= serial, serial <= serialMax else {
            return ParsedRepTarget(
                value: .unknown(raw: raw), needsReview: true,
                reviewReason: "serial \(serial) outside plausible workbook range [\(serialMin),\(serialMax)] (§8.2 constraint 2) — treated as corrupted/fabricated value, not reconstructed"
            )
        }
        let date = ExcelEpoch.date(fromSerial: serial)
        let low = date.month, high = date.day
        guard rangeBoundsOK(low, high) else {
            return ParsedRepTarget(
                value: .unknown(raw: raw), needsReview: true,
                reviewReason: "reconstructed range \(low)-\(high) fails 1<=low<high<=60 (§8.2 constraint 1)"
            )
        }
        return ParsedRepTarget(value: .range(low: low, high: high, raw: raw), needsReview: false, reviewReason: nil)
    }

    /// §8.3: an `h:mm`-parsed Excel time fraction (day fraction, e.g.
    /// `0.0430555...`) reinterpreted as `m:ss`.
    public static func parseRepTargetFromTimeSerial(_ fractionText: String, raw: String) -> ParsedRepTarget {
        let frac = Double(fractionText) ?? 0
        let totalMinutesRounded = Int((frac * 24 * 60).rounded())
        let h = totalMinutesRounded / 60
        let m = totalMinutesRounded % 60
        let seconds = h * 60 + m
        return ParsedRepTarget(value: .time(seconds: seconds, raw: raw), needsReview: false, reviewReason: nil)
    }

    public static func parseRepTargetText(_ text: String, raw: String) -> ParsedRepTarget {
        if text.isEmpty || text == "/" {
            return ParsedRepTarget(value: .unknown(raw: raw), needsReview: false, reviewReason: nil)
        }
        if let m = wholeMatch(#"^(\d+)\s*-\s*(\d+)$"#, text, caseInsensitive: false),
           let low = Int(m[1]), let high = Int(m[2]) {
            if rangeBoundsOK(low, high) {
                return ParsedRepTarget(value: .range(low: low, high: high, raw: raw), needsReview: false, reviewReason: nil)
            }
            return ParsedRepTarget(value: .unknown(raw: raw), needsReview: true, reviewReason: "literal range \(low)-\(high) fails 1<=low<high<=60")
        }
        if let m = wholeMatch(#"^~\s*(\d+)$"#, text, caseInsensitive: false), let value = Int(m[1]) {
            return ParsedRepTarget(value: .fixed(value: value, raw: raw), needsReview: false, reviewReason: "'~N' interpreted as approximate fixed rep count")
        }
        if let m = wholeMatch(#"^(\d+)$"#, text, caseInsensitive: false), let value = Int(m[1]) {
            return ParsedRepTarget(value: .fixed(value: value, raw: raw), needsReview: false, reviewReason: nil)
        }
        if let m = wholeMatch(#"^(\d+)\s*min$"#, text, caseInsensitive: true), let mins = Int(m[1]) {
            return ParsedRepTarget(value: .time(seconds: mins * 60, raw: raw), needsReview: false, reviewReason: nil)
        }
        if let m = wholeMatch(#"^(\d+)\s*s(?:ec)?$"#, text, caseInsensitive: true), let secs = Int(m[1]) {
            return ParsedRepTarget(value: .time(seconds: secs, raw: raw), needsReview: false, reviewReason: nil)
        }
        if let m = wholeMatch(#"^(\d+)\s*m$"#, text, caseInsensitive: true), let meters = Int(m[1]) {
            return ParsedRepTarget(value: .distance(meters: meters, raw: raw), needsReview: false, reviewReason: nil)
        }
        if let m = wholeMatch(#"^(\d+)\s*round(?:s)?$"#, text, caseInsensitive: true), let count = Int(m[1]) {
            return ParsedRepTarget(value: .rounds(count: count, raw: raw), needsReview: false, reviewReason: nil)
        }
        if let m = wholeMatch(#"^(\d+)\s*x\s*(\d+)$"#, text, caseInsensitive: true), let count = Int(m[1]) {
            return ParsedRepTarget(value: .rounds(count: count, raw: raw), needsReview: false, reviewReason: "'AxB' notation — count taken as A per §7.7")
        }
        return ParsedRepTarget(
            value: .unknown(raw: raw), needsReview: true,
            reviewReason: "text does not match any documented RepTarget pattern (§7.7) — needs human interpretation"
        )
    }

    /// Full dispatch for a Rep-range/Rep-completed cell, honoring cell
    /// style (§8.2/§8.3 categories) plus the value-magnitude safety net for
    /// General-styled corrupted serials (the two `56789` cells).
    public static func parseRepTargetCell(_ cell: XLSXCell?, category: NumberFormatCategory) -> ParsedRepTarget {
        guard let cell else {
            return parseRepTargetText("", raw: "")
        }
        let rawText = cell.text
        if cell.isString {
            return parseRepTargetText(rawText.trimmingCharacters(in: .whitespaces), raw: rawText)
        }
        switch category {
        case .dateMonthDashDay:
            guard let doubleValue = Double(rawText), doubleValue.isFinite else {
                return parseRepTargetText(rawText.trimmingCharacters(in: .whitespaces), raw: rawText)
            }
            return parseRepTargetFromSerial(Int(doubleValue), raw: rawText)
        case .timeHourMinute:
            return parseRepTargetFromTimeSerial(rawText, raw: rawText)
        case .dateBuiltin:
            // CONTRACT-M7.md §3.2's extra guard, not present in migrate.py
            // (this workbook never triggers it): a full date -- one with a
            // year component -- means the coach (or a re-save through
            // Numbers/Google Sheets) really did put a date here. Running
            // §8.2 reconstruction on it would fabricate a fake rep range
            // out of a real date's month/day.
            return ParsedRepTarget(
                value: .unknown(raw: rawText), needsReview: true,
                reviewReason: "cell has a full date format (contains a year) — treated as a genuine date, not a §8.2-corrupted rep range"
            )
        case .dateMonthDay, .general:
            guard let num = Double(rawText) else {
                return parseRepTargetText(rawText.trimmingCharacters(in: .whitespaces), raw: rawText)
            }
            if num >= suspectNumericThreshold {
                return parseRepTargetFromSerial(Int(num), raw: rawText)
            }
            if num == num.rounded(.towardZero) {
                return ParsedRepTarget(value: .fixed(value: Int(num), raw: rawText), needsReview: false, reviewReason: nil)
            }
            return ParsedRepTarget(
                value: .unknown(raw: rawText), needsReview: true,
                reviewReason: "non-integer numeric value does not match any RepTarget pattern"
            )
        }
    }

    /// Like `parseRepTargetCell`, but for a cell that belongs to a
    /// SINGLE-exercise block (never a superset component). Adds §7.8's
    /// `perSide` branch. Callers MUST only invoke this from the
    /// non-superset path -- inside a superset, commas are component
    /// separators, not left/right sides.
    public static func parseRepTargetCellSingleBlock(_ cell: XLSXCell?, category: NumberFormatCategory) -> ParsedRepTarget {
        if let cell, cell.isString {
            let text = cell.text.trimmingCharacters(in: .whitespaces)
            if let m = wholeMatch(#"^(\d+)\s*,\s*(\d+)$"#, text, caseInsensitive: false),
               let left = Int(m[1]), let right = Int(m[2]) {
                return ParsedRepTarget(
                    value: .perSide(left: left, right: right, raw: cell.text), needsReview: false,
                    reviewReason: "exactly 2 comma-separated integers in a single-exercise block — left/right reps for a unilateral movement (§7.8)"
                )
            }
        }
        return parseRepTargetCell(cell, category: category)
    }

    // MARK: - §6 / §8.4 Sets

    public static func parseSetsCell(_ cell: XLSXCell?, category: NumberFormatCategory) -> ParsedSetsCell {
        guard let cell else {
            return ParsedSetsCell(sets: nil, raw: "", needsReview: false)
        }
        let rawText = cell.text
        if cell.isString {
            let text = rawText.trimmingCharacters(in: .whitespaces)
            if let m = wholeMatch(#"^(\d+)$"#, text, caseInsensitive: false), let value = Int(m[1]) {
                return ParsedSetsCell(sets: value, raw: rawText, needsReview: false)
            }
            return ParsedSetsCell(sets: nil, raw: rawText, needsReview: true)
        }
        if category == .dateMonthDashDay || category == .dateMonthDay || category == .timeHourMinute {
            return ParsedSetsCell(sets: nil, raw: rawText, needsReview: true)
        }
        guard let num = Double(rawText) else {
            return ParsedSetsCell(sets: nil, raw: rawText, needsReview: true)
        }
        guard num == num.rounded(.towardZero), num > 0, num < 20 else {
            return ParsedSetsCell(sets: nil, raw: rawText, needsReview: true)
        }
        return ParsedSetsCell(sets: Int(num), raw: rawText, needsReview: false)
    }

    // MARK: - Rest

    /// Returns `(seconds, raw)`. `raw` is always the original text
    /// (possibly empty); `seconds` is `nil` when unparseable.
    public static func parseRest(_ rawText: String?) -> (seconds: Int?, raw: String) {
        guard let rawText, !rawText.isEmpty else { return (nil, rawText ?? "") }
        let text = rawText.trimmingCharacters(in: .whitespaces)
        if let m = wholeMatch(#"^(\d+)\s*min$"#, text, caseInsensitive: true), let mins = Int(m[1]) {
            return (mins * 60, rawText)
        }
        if let m = wholeMatch(#"^(\d+)\s*s(?:ec)?$"#, text, caseInsensitive: true), let secs = Int(m[1]) {
            return (secs, rawText)
        }
        return (nil, rawText)
    }

    // MARK: - Regex helper

    /// Full-string match (both `^` and `$` are expected to already be in
    /// `pattern`, mirroring every `migrate.py` pattern this ports).
    /// Returns capture groups (index 0 = whole match), or `nil`.
    private static func wholeMatch(_ pattern: String, _ text: String, caseInsensitive: Bool) -> [String]? {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let result = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        var groups: [String] = []
        for i in 0..<result.numberOfRanges {
            if let r = Range(result.range(at: i), in: text) {
                groups.append(String(text[r]))
            } else {
                groups.append("")
            }
        }
        return groups
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Excel's 1900-date-system epoch (the well-known leap-year bug is baked
/// into this constant, same as `migrate.py`'s `EPOCH = date(1899, 12, 30)`).
public enum ExcelEpoch {
    /// UTC-anchored: a serial's (month, day) must not shift because the
    /// host device's local time zone rounds the instant to a different
    /// calendar day.
    public static func date(fromSerial serial: Int) -> (month: Int, day: Int, year: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.year = 1899
        components.month = 12
        components.day = 30
        let epoch = calendar.date(from: components)!
        let result = calendar.date(byAdding: .day, value: serial, to: epoch)!
        let parts = calendar.dateComponents([.year, .month, .day], from: result)
        return (parts.month!, parts.day!, parts.year!)
    }
}
