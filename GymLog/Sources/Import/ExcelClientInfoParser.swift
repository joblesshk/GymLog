import Foundation

/// A client identity/profile read off an Excel workbook's "Info" sheet --
/// the same sheet `migration/migrate.py` always found blank for the real
/// coach data this app ships with (every `Info` cell except the label
/// column is empty in `Fixtures/source.xlsx`), but which a DIFFERENT
/// client's workbook may have genuinely filled in.
public struct ParsedClientInfo {
    public let name: String
    public let phone: String?
    public let gender: String?
    public let age: Int?
    public let heightCm: Double?
    public let startWeightKg: Double?
    public let goal: String?
    public let frequency: String?
    public let bmr: Double?
    public let tdee: Double?
    public let habits: String?
    public let medicalHistory: String?
}

/// Reads the `Info` sheet's label(column A) -> value(column B) rows. Pure
/// function over an already-parsed `XLSXWorkbook`, same shape as
/// `WorkbookSessionParser` -- no SwiftData, no I/O.
public enum ExcelClientInfoParser {
    /// `nil` when there's no `Info` sheet at all, or when its `Name` cell
    /// is empty -- a blank name means there is nothing here to compare
    /// against the app's current client, not "an empty-named client."
    public static func parse(_ workbook: XLSXWorkbook) -> ParsedClientInfo? {
        guard let sheet = workbook.sheets["Info"] else { return nil }
        var labelToValue: [String: String] = [:]
        for (_, columns) in sheet {
            guard let labelCell = columns[1], let valueCell = columns[2] else { continue }
            let label = labelCell.text.trimmingCharacters(in: .whitespaces)
            let value = valueCell.text.trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, !value.isEmpty else { continue }
            // First non-empty value wins if a label somehow repeats -- the
            // template only ever has one row per label in practice.
            if labelToValue[label] == nil { labelToValue[label] = value }
        }
        guard let name = labelToValue["Name"], !name.isEmpty else { return nil }
        return ParsedClientInfo(
            name: name,
            phone: labelToValue["Phone No."],
            gender: labelToValue["Gender"],
            age: labelToValue["Age"].flatMap(leadingInt),
            heightCm: labelToValue["Height"].flatMap(leadingDouble),
            startWeightKg: labelToValue["Weight"].flatMap(leadingDouble),
            goal: labelToValue["Target"],
            frequency: labelToValue["Frequency"],
            bmr: labelToValue["BMR"].flatMap(leadingDouble),
            tdee: labelToValue["TDEE"].flatMap(leadingDouble),
            habits: labelToValue["Habits"],
            medicalHistory: labelToValue["Medical History"]
        )
    }

    /// Cells like "44" parse directly, but a coach might write "44歲"/"172cm"
    /// -- take the leading numeric run rather than failing the whole field
    /// over a trailing unit.
    private static func leadingInt(_ text: String) -> Int? {
        leadingDouble(text).map { Int($0) }
    }

    private static func leadingDouble(_ text: String) -> Double? {
        if let direct = Double(text) { return direct }
        let leading = text.prefix { $0.isNumber || $0 == "." }
        return leading.isEmpty ? nil : Double(leading)
    }
}
