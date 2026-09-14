import Foundation

/// CONTRACT-M7.md §3.2: which of `CONTRACT.md`'s §8 data-corruption
/// categories a cell's display format puts it in. Unlike `migrate.py`
/// (which hardcodes numFmtId 164/165/20 for this specific workbook),
/// this classifies by the format CODE STRING -- numFmtId ≥164 is assigned
/// per-workbook by whichever program last saved the file, so a coach
/// re-saving in Numbers or Google Sheets can renumber it freely without
/// changing what it visually displays.
public enum NumberFormatCategory: Equatable {
    /// "m/d" (or "d/m") -- §8.1's session-date column style.
    case dateMonthDay
    /// "m-d" (or "d-m") -- §8.2's rep-range column style.
    case dateMonthDashDay
    /// A genuine full date (contains a year component, e.g. "m/d/yyyy",
    /// or one of the built-in date numFmtIds 14/15/16/17/22). §3.2's extra
    /// guard: a cell in this category must NOT be run through §8.2's
    /// reconstruction -- it's a real date, not a swallowed rep range.
    case dateBuiltin
    /// §8.3's cardio-time style ("h:mm" and its built-in-id equivalents).
    case timeHourMinute
    case general
}

public enum XLSXNumberFormat {
    /// `formatCode` as read from a `<numFmt>` element in `styles.xml`, for
    /// custom (numFmtId ≥ 164) formats.
    public static func category(formatCode: String) -> NumberFormatCategory {
        let normalized = normalize(formatCode)
        switch normalized {
        case "m/d", "d/m":
            return .dateMonthDay
        case "m-d", "d-m":
            return .dateMonthDashDay
        default:
            break
        }
        // Order matters: check for a time component before a year
        // component -- "h" never appears in either of our two short date
        // styles, so this can't misfire on them (already handled above).
        if normalized.contains("h") {
            return .timeHourMinute
        }
        if normalized.contains("y") {
            return .dateBuiltin
        }
        return .general
    }

    /// Built-in numFmtIds (no `<numFmt>` entry in `styles.xml` -- Excel
    /// knows these by number alone, per ECMA-376 part 1 §18.8.30).
    public static func category(builtinNumFmtId id: Int) -> NumberFormatCategory {
        switch id {
        case 14, 15, 16, 17, 22:
            return .dateBuiltin
        case 18, 19, 20, 21, 45, 46, 47:
            return .timeHourMinute
        default:
            return .general
        }
    }

    /// Strips backslash-escapes (`m\-d` -> `m-d`), bracketed sections
    /// (locale/color codes like `[$-409]`, `[Red]`), quoted literal text,
    /// and surrounding whitespace, then lowercases. Mirrors what a person
    /// visually reads off the formatted cell, not the raw format-code
    /// syntax.
    private static func normalize(_ formatCode: String) -> String {
        var result = ""
        result.reserveCapacity(formatCode.count)
        var insideBracket = false
        var insideQuote = false
        for char in formatCode {
            if insideQuote {
                if char == "\"" { insideQuote = false }
                continue
            }
            if insideBracket {
                if char == "]" { insideBracket = false }
                continue
            }
            switch char {
            case "\\": continue
            case "[": insideBracket = true
            case "\"": insideQuote = true
            default: result.append(char)
            }
        }
        return result.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
