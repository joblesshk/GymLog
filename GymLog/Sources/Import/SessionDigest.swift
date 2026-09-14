import Foundation
import CryptoKit

/// CONTRACT-M7.md §3.8.3: two SHA-256 digests that let re-importing the
/// same file recognize "this session already exists" without depending on
/// row numbers (which shift whenever a row is inserted/removed anywhere
/// above) or on `id` (a session's id is derived from its natural key, so a
/// mismatch there would already mean a different session entirely).
///
/// - `sourceDigest` hashes the RAW cell text the session occupied in the
///   source file. Comparing this on re-import answers "did the Excel
///   change?" -- using the original text, not the parsed result, so it's
///   insensitive to parser changes (a future bugfix in `ExcelValueParsers`
///   must not make already-imported sessions look "changed").
/// - `importDigest` hashes the OBJECT GRAPH as written to the database.
///   Recomputing it from the database's *current* state (not from the
///   freshly-parsed DTO) and comparing against the stored value answers
///   "has this session been hand-edited in the app since it was imported?"
///   -- with no separate "dirty" flag to remember to set at every edit
///   site (there isn't one single save path today across `TodayView` /
///   `SessionDetailView`, so a flag would be easy to leave unset somewhere).
public enum SessionDigest {
    /// Canonical form: one line per cell, `"row|col:text"`, rows ascending
    /// then columns ascending within a row, `\n`-joined. Built from the
    /// ORIGINAL workbook (not the parsed DTO) so it reflects exactly what a
    /// person would see re-opening the source file.
    public static func sourceDigest(sheet: String, rows: [Int], workbook: XLSXWorkbook) -> String {
        guard let sheetRows = workbook.sheets[sheet] else { return sha256("") }
        var lines: [String] = []
        for row in rows.sorted() {
            guard let cells = sheetRows[row] else { continue }
            for col in cells.keys.sorted() {
                lines.append("\(row)|\(col):\(cells[col]!.text)")
            }
        }
        return sha256(lines.joined(separator: "\n"))
    }

    /// Canonical form, one line per object, in a fixed field order (`nil`
    /// serializes to an empty string):
    /// ```
    /// S|date|weekNumber|sourceSheet|warmup|warmupNote|cooldown|cooldownNote
    /// B|order|blockType|restSeconds|restRaw|note            (per block, order asc)
    /// E|order|exerciseIdRef|exerciseRaw|plannedSets           (per entry, order asc)
    /// L|setIndex|load|target|actual|isInferred                (per set, setIndex asc)
    /// ```
    /// `load`/`target`/`actual` use the SAME JSON encoding `SetLog` itself
    /// stores them as (`JSONColumnCoding`), so this can be recomputed
    /// identically whether fed a freshly-parsed DTO or objects read back
    /// out of SwiftData.
    public static func importDigest(
        date: Date, weekNumber: Int, sourceSheet: String,
        warmup: String?, warmupNote: String?, cooldown: String?, cooldownNote: String?,
        blocks: [ImportDigestBlock]
    ) -> String {
        sha256(rawLines(date: date, weekNumber: weekNumber, sourceSheet: sourceSheet, warmup: warmup, warmupNote: warmupNote, cooldown: cooldown, cooldownNote: cooldownNote, blocks: blocks).joined(separator: "\n"))
    }

    private static func rawLines(
        date: Date, weekNumber: Int, sourceSheet: String,
        warmup: String?, warmupNote: String?, cooldown: String?, cooldownNote: String?,
        blocks: [ImportDigestBlock]
    ) -> [String] {
        var lines: [String] = []
        let isoDate = isoDateString(date)
        lines.append("S|\(isoDate)|\(weekNumber)|\(sourceSheet)|\(warmup ?? "")|\(warmupNote ?? "")|\(cooldown ?? "")|\(cooldownNote ?? "")")
        for block in blocks.sorted(by: { $0.order < $1.order }) {
            lines.append("B|\(block.order)|\(block.blockType.rawValue)|\(block.restSeconds.map(String.init) ?? "")|\(block.restRaw ?? "")|\(block.note ?? "")")
            for entry in block.entries.sorted(by: { $0.order < $1.order }) {
                lines.append("E|\(entry.order)|\(entry.exerciseIdRef)|\(entry.exerciseRaw)|\(entry.plannedSets)")
                for set in entry.sets.sorted(by: { $0.setIndex < $1.setIndex }) {
                    // Deliberately NOT `JSONColumnCoding.encode` here: Foundation's
                    // `JSONEncoder` does not guarantee stable key ordering across
                    // separate encode calls for the same value (confirmed on-device:
                    // the exact same `LoadValue.absolute(kg: 50, raw: "50")` encoded
                    // twice produced `{"raw":"50","kind":"absolute","kg":50}` once and
                    // `{"kind":"absolute","kg":50,"raw":"50"}` the next time). That's
                    // fine for the persisted column (decoding is structural, key order
                    // is irrelevant) but fatal for a digest that hashes the raw text --
                    // it would flag an untouched session as "changed" on pure bad luck.
                    // `.sortedKeys` makes the byte sequence a true function of the value.
                    let loadJSON = canonicalJSON(set.load)
                    let targetJSON = canonicalJSON(set.target)
                    let actualJSON = canonicalJSON(set.actual)
                    lines.append("L|\(set.setIndex)|\(loadJSON)|\(targetJSON)|\(actualJSON)|\(set.isInferred)")
                }
            }
        }
        return lines
    }

    private static func isoDateString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    private static let canonicalEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static func canonicalJSON<T: Encodable>(_ value: T) -> String {
        guard let data = try? canonicalEncoder.encode(value), let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }

    private static func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// A plain, digest-agnostic view of one block's identity for
/// `importDigest` -- deliberately NOT `SessionBlock`/`ExerciseEntry`/
/// `SetLog` themselves, so this function can be fed either a freshly-parsed
/// `ParsedSessionBlock` (before anything is written) or the equivalent
/// shape read back out of SwiftData (to detect a post-import edit),
/// without those two call sites needing to share a common model type.
public struct ImportDigestBlock {
    public let order: Int
    public let blockType: BlockType
    public let restSeconds: Int?
    public let restRaw: String?
    public let note: String?
    public let entries: [ImportDigestEntry]

    public init(order: Int, blockType: BlockType, restSeconds: Int?, restRaw: String?, note: String?, entries: [ImportDigestEntry]) {
        self.order = order
        self.blockType = blockType
        self.restSeconds = restSeconds
        self.restRaw = restRaw
        self.note = note
        self.entries = entries
    }
}

public struct ImportDigestEntry {
    public let order: Int
    public let exerciseIdRef: String
    public let exerciseRaw: String
    public let plannedSets: Int
    public let sets: [ImportDigestSet]

    public init(order: Int, exerciseIdRef: String, exerciseRaw: String, plannedSets: Int, sets: [ImportDigestSet]) {
        self.order = order
        self.exerciseIdRef = exerciseIdRef
        self.exerciseRaw = exerciseRaw
        self.plannedSets = plannedSets
        self.sets = sets
    }
}

public struct ImportDigestSet {
    public let setIndex: Int
    public let load: LoadValue
    public let target: RepTarget
    public let actual: RepTarget
    public let isInferred: Bool

    public init(setIndex: Int, load: LoadValue, target: RepTarget, actual: RepTarget, isInferred: Bool) {
        self.setIndex = setIndex
        self.load = load
        self.target = target
        self.actual = actual
        self.isInferred = isInferred
    }
}
