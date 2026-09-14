import Foundation

// MARK: - Parsed DTOs (pure data, no SwiftData -- CONTRACT-M7.md §3.9: parsing
// and persistence are deliberately separate layers so a parse failure never
// touches the database).

public struct ParsedSetLog {
    public let setIndex: Int
    public let load: LoadValue
    public let target: RepTarget
    public let actual: RepTarget
    public let isInferred: Bool
}

public struct ParsedExerciseEntry {
    public let order: Int
    public let exerciseKey: String
    public let exerciseRaw: String
    public let plannedSets: Int
    public let sets: [ParsedSetLog]
}

public struct ParsedSessionBlock {
    public let order: Int
    public let blockType: BlockType
    public let restSeconds: Int?
    public let restRaw: String?
    public let note: String?
    public let sourceRow: Int
    public let entries: [ParsedExerciseEntry]
}

public struct ParsedSession {
    public let date: Date
    public let dateOrigin: DateOrigin
    public let dateRaw: String
    public let weekNumber: Int
    public let sourceSheet: String
    public let sourceRow: Int
    public let warmup: String?
    public let warmupNote: String?
    public let cooldown: String?
    public let cooldownNote: String?
    public let needsReview: Bool
    public let reviewReason: String?
    public var blocks: [ParsedSessionBlock]
    /// Every row number this session occupies in the source sheet (its
    /// "Week N" header row, warm-up row, each data row, cool-down row) --
    /// deliberately NOT derivable from `blocks` alone (a block only knows
    /// its own `sourceRow`, not the header/warmup/cooldown rows around it).
    /// Exists purely to feed `SessionDigest.sourceDigest` (CONTRACT-M7.md
    /// §3.8.3): detecting "did the Excel change" needs the exact source
    /// text of every cell the session came from, not just its parsed
    /// result.
    public let sourceRowsUsed: [Int]
}

public struct ParsedExercise {
    public let key: String
    public let id: String
    public let canonicalName: String
    public let aliases: [String]
    public let movementPattern: MovementPattern
    public let equipment: Equipment
    public let loadDirection: LoadDirection
    public let isUnilateral: Bool
    public let occurrenceCount: Int
    public let needsReview: Bool
    public let reviewReason: String?
    /// CONTRACT-M8.md. Name-keyword-only guess (see `ExerciseClassifier`) --
    /// always paired with `needsReview = true` by the caller.
    public let recordingMetric: RecordingMetric
}

public struct ParsedWorkbook {
    /// Sorted by date ascending (stable), matching CONTRACT.md §5.
    public let sessions: [ParsedSession]
    /// Sorted by canonicalName (case-insensitive), matching `migrate.py`.
    /// Each session entry's `exerciseKey` looks up into this list's `key`.
    public let exercises: [ParsedExercise]
}

public enum WorkbookSessionParserError: Error, Equatable {
    case noLogSheets
    case headerMismatch(sheet: String, row: Int, found: [String])
    case noDateAnchor
    case dateOrderingBroken(detail: String)
}

/// CONTRACT-M7.md §3.3/§3.5/§3.6/§3.7: the whole-workbook session parser,
/// ported from `migrate.py`'s `gather_raw_sessions` / `build_block` /
/// `reconstruct_dates` / the exercise-assembly half of `main()`. This is a
/// pure function over an already-parsed `XLSXWorkbook` -- no SwiftData, no
/// I/O -- so it can be fuzzed and parity-tested without a persistence layer
/// in the loop.
public enum WorkbookSessionParser {
    public static func parse(_ workbook: XLSXWorkbook) throws -> ParsedWorkbook {
        let logSheetNames = workbook.sheetOrder.filter {
            RegexSearch.contains(#"^full body(\s+\d+)?$"#, in: $0.trimmingCharacters(in: .whitespaces), caseInsensitive: true)
        }
        guard !logSheetNames.isEmpty else { throw WorkbookSessionParserError.noLogSheets }

        var rawSessions: [RawSession] = []
        for sheetName in logSheetNames {
            guard let rows = workbook.sheets[sheetName] else { continue }
            try validateHeaderRows(sheet: sheetName, rows: rows)
            rawSessions.append(contentsOf: gatherRawSessions(sheetName: sheetName, rows: rows))
        }

        let dateResults = try reconstructDates(rawSessions)

        let stats = ExerciseStatsAggregator()
        var sessionsBuilt: [ParsedSession] = []
        for (rawSession, dateResult) in zip(rawSessions, dateResults) {
            var blocks: [ParsedSessionBlock] = []
            for (rowNumber, cells) in rawSession.dataRows {
                let category: (Int) -> NumberFormatCategory = { workbook.numberFormatCategory(styleIndex: $0) }
                var block = buildBlock(sheet: rawSession.sheet, rowNumber: rowNumber, cells: cells, categoryOf: category, stats: stats)
                block = ParsedSessionBlock(
                    order: blocks.count, blockType: block.blockType, restSeconds: block.restSeconds,
                    restRaw: block.restRaw, note: block.note, sourceRow: block.sourceRow, entries: block.entries
                )
                blocks.append(block)
            }
            sessionsBuilt.append(ParsedSession(
                date: dateResult.date, dateOrigin: dateResult.dateOrigin, dateRaw: rawSession.dateRaw,
                weekNumber: rawSession.week, sourceSheet: rawSession.sheet, sourceRow: rawSession.row,
                warmup: rawSession.warmup, warmupNote: rawSession.warmupNote,
                cooldown: rawSession.cooldown, cooldownNote: rawSession.cooldownNote,
                needsReview: dateResult.needsReview, reviewReason: dateResult.reviewReason,
                blocks: blocks, sourceRowsUsed: rawSession.allRows.sorted()
            ))
        }

        sessionsBuilt.sort { $0.date < $1.date }

        let exercises = assembleExercises(stats: stats)
        return ParsedWorkbook(sessions: sessionsBuilt, exercises: exercises)
    }

    // MARK: - §3.3 header validation

    private static func validateHeaderRows(sheet: String, rows: [Int: [Int: XLSXCell]]) throws {
        let expected = ["Exercise", "Sets", "Weights", "Rep range", "Rep completed", "Rest", "Notes"]
        for rowNumber in rows.keys.sorted() {
            let cells = rows[rowNumber]!
            let aText = (cells[1]?.text ?? "").trimmingCharacters(in: .whitespaces)
            guard aText == "Exercise" else { continue }
            let found = (1...7).map { (cells[$0]?.text ?? "").trimmingCharacters(in: .whitespaces) }
            guard found == expected else {
                throw WorkbookSessionParserError.headerMismatch(sheet: sheet, row: rowNumber, found: found)
            }
        }
    }

    // MARK: - §3.3 week-block segmentation

    private final class RawSession {
        let sheet: String
        let row: Int
        let week: Int
        let dateRaw: String
        var warmup: String?
        var warmupNote: String?
        var cooldown: String?
        var cooldownNote: String?
        var dataRows: [(rowNumber: Int, cells: [Int: XLSXCell])] = []
        /// Every row number belonging to this session -- header, "Exercise"
        /// column-header row, warm-up, each data row, cool-down -- in the
        /// order encountered. Feeds `sourceRowsUsed` (see `ParsedSession`).
        var allRows: [Int]

        init(sheet: String, row: Int, week: Int, dateRaw: String) {
            self.sheet = sheet
            self.row = row
            self.week = week
            self.dateRaw = dateRaw
            self.allRows = [row]
        }
    }

    private static func cellText(_ cells: [Int: XLSXCell], _ col: Int) -> String {
        (cells[col]?.text ?? "").trimmingCharacters(in: .whitespaces)
    }

    private static func gatherRawSessions(sheetName: String, rows: [Int: [Int: XLSXCell]]) -> [RawSession] {
        var sessions: [RawSession] = []
        var current: RawSession?
        for rowNumber in rows.keys.sorted() {
            let cells = rows[rowNumber]!
            let aText = cellText(cells, 1)
            if let m = wholeMatch(#"^Week (\d+)$"#, aText, caseInsensitive: false), let week = Int(m[1]) {
                current = RawSession(sheet: sheetName, row: rowNumber, week: week, dateRaw: cellText(cells, 2))
                sessions.append(current!)
                continue
            }
            guard let session = current else { continue }
            if aText.isEmpty { continue }
            session.allRows.append(rowNumber)
            if aText == "Exercise" { continue }
            if aText == "Warm-up" {
                session.warmup = cellText(cells, 2)
                session.warmupNote = cellText(cells, 7)
                continue
            }
            if aText == "Cool-down" {
                session.cooldown = cellText(cells, 2)
                session.cooldownNote = cellText(cells, 7)
                continue
            }
            session.dataRows.append((rowNumber, cells))
        }
        return sessions
    }

    // MARK: - §3.5 block/entry/set assembly

    private final class ExerciseStatsAggregator {
        struct Stats {
            var count = 0
            var variantCounts: [String: Int] = [:]
            /// First-seen order, no duplicates -- Python's `collections.Counter`
            /// preserves insertion order for equal counts, and
            /// `most_common(1)` breaks ties that way (first-inserted wins).
            /// A plain `[String: Int]` has no ordering guarantee at all, so
            /// this has to be tracked explicitly to match that tie-break
            /// rule (confirmed necessary: without it, "Rear lunges" vs
            /// "rear lunges" -- equal counts -- picked the alphabetically
            /// later one instead of the first-seen one).
            var variantOrder: [String] = []
        }
        var statsByKey: [String: Stats] = [:]
        var unilateralKeys: Set<String> = []
        var bareModifierKeys: Set<String> = []

        func record(key: String, variant: String) {
            var stats = statsByKey[key] ?? Stats()
            stats.count += 1
            if stats.variantCounts[variant] == nil {
                stats.variantOrder.append(variant)
            }
            stats.variantCounts[variant, default: 0] += 1
            statsByKey[key] = stats
        }
    }

    /// `(segmentCount, segments)`. `segments` is non-nil only when the cell
    /// is a comma-separated STRING with more than one part.
    private static func segCountAndParts(_ cell: XLSXCell?) -> (count: Int, parts: [String]?) {
        guard let cell, cell.isString, cell.text.contains(",") else { return (1, nil) }
        let parts = cell.text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count > 1 ? (parts.count, parts) : (1, nil)
    }

    private static func syntheticCell(_ text: String) -> XLSXCell {
        XLSXCell(text: text, styleIndex: 0, isString: true)
    }

    private static func buildBlock(
        sheet: String, rowNumber: Int, cells: [Int: XLSXCell],
        categoryOf: (Int) -> NumberFormatCategory, stats: ExerciseStatsAggregator
    ) -> ParsedSessionBlock {
        let rawName = cells[1]?.text ?? ""
        let isSuperset = RegexSearch.contains(#"\s\+\s"#, in: rawName, caseInsensitive: false)
        var parts = splitOnPlus(rawName).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.isEmpty { parts = [rawName.trimmingCharacters(in: .whitespaces)] }
        let nParts = parts.count

        let setsCell = cells[2]
        let weightCell = cells[3]
        let targetCell = cells[4]
        let actualCell = cells[5]
        let restCell = cells[6]
        let noteCell = cells[7]

        let parsedSets = ExcelValueParsers.parseSetsCell(setsCell, category: setsCell.map { categoryOf($0.styleIndex) } ?? .general)
        let (restSeconds, restRaw) = ExcelValueParsers.parseRest(restCell?.text ?? "")
        let noteTrimmed = noteCell?.text.trimmingCharacters(in: .whitespaces)
        let note = (noteTrimmed?.isEmpty == false) ? noteTrimmed : nil

        let nameLower = rawName.lowercased()
        let isDropNamed = nameLower.contains("drop")

        var blockType: BlockType = .single
        var entries: [ParsedExerciseEntry] = []

        if isSuperset, nParts >= 2 {
            blockType = .superset
            let (wCount, wParts) = segCountAndParts(weightCell)
            let (tCount, tParts) = segCountAndParts(targetCell)
            let (aCount, aParts) = segCountAndParts(actualCell)

            for (index, partName) in parts.enumerated() {
                let wCellI = (wParts != nil && wCount == nParts) ? syntheticCell(wParts![index]) : weightCell
                let tCellI = (tParts != nil && tCount == nParts) ? syntheticCell(tParts![index]) : targetCell
                let aCellI = (aParts != nil && aCount == nParts) ? syntheticCell(aParts![index]) : actualCell

                let load = ExcelValueParsers.parseLoadValue(wCellI?.text, exerciseNameLower: partName.lowercased()).value
                let target = ExcelValueParsers.parseRepTargetCell(tCellI, category: tCellI.map { categoryOf($0.styleIndex) } ?? .general).value
                let actual = ExcelValueParsers.parseRepTargetCell(aCellI, category: aCellI.map { categoryOf($0.styleIndex) } ?? .general).value

                let nSets = parsedSets.sets ?? 0
                let sets = (0..<nSets).map { ParsedSetLog(setIndex: $0, load: load, target: target, actual: actual, isInferred: true) }

                var canonForm = partName
                if index > 0, let modifier = ExerciseNameCanonicalizer.detectBareModifier(baseName: parts[0], componentName: partName) {
                    canonForm = "\(parts[0]) (\(modifier))"
                }
                let key = ExerciseNameCanonicalizer.normalizeKey(canonForm)
                if canonForm != partName {
                    stats.bareModifierKeys.insert(key)
                }
                entries.append(ParsedExerciseEntry(order: index, exerciseKey: key, exerciseRaw: partName, plannedSets: nSets, sets: sets))
                stats.record(key: key, variant: canonForm)
            }
        } else {
            let exerciseRaw = parts[0]
            let key = ExerciseNameCanonicalizer.normalizeKey(exerciseRaw)
            let (wCount, wParts) = segCountAndParts(weightCell)
            let (tCount, _) = segCountAndParts(targetCell)
            let (aCount, _) = segCountAndParts(actualCell)
            let multiCounts = Set([wCount, tCount, aCount].filter { $0 > 1 })

            var weightValuesDescending: [Double]?
            if isDropNamed, let wParts {
                let leading = wParts.map { leadingNumericPrefix($0) }
                if leading.allSatisfy({ $0 != nil }) {
                    let values = leading.map { $0! }
                    let descending = (0..<(values.count - 1)).allSatisfy { values[$0] >= values[$0 + 1] }
                    weightValuesDescending = descending ? values : nil
                }
            }

            if isDropNamed, let wParts, weightValuesDescending != nil, multiCounts.count <= 1 {
                blockType = .dropset
                let n = wCount
                let (tCountForDrop, tPartsForDrop) = segCountAndParts(targetCell)
                let (aCountForDrop, aPartsForDrop) = segCountAndParts(actualCell)
                var sets: [ParsedSetLog] = []
                for stageIndex in 0..<n {
                    let wCellI = syntheticCell(wParts[stageIndex])
                    let tCellI = (tPartsForDrop != nil && tCountForDrop == n) ? syntheticCell(tPartsForDrop![stageIndex]) : targetCell
                    let aCellI = (aPartsForDrop != nil && aCountForDrop == n) ? syntheticCell(aPartsForDrop![stageIndex]) : actualCell
                    let load = ExcelValueParsers.parseLoadValue(wCellI.text, exerciseNameLower: nameLower).value
                    let target = ExcelValueParsers.parseRepTargetCell(tCellI, category: tCellI.map { categoryOf($0.styleIndex) } ?? .general).value
                    let actual = ExcelValueParsers.parseRepTargetCell(aCellI, category: aCellI.map { categoryOf($0.styleIndex) } ?? .general).value
                    sets.append(ParsedSetLog(setIndex: stageIndex, load: load, target: target, actual: actual, isInferred: true))
                }
                entries.append(ParsedExerciseEntry(order: 0, exerciseKey: key, exerciseRaw: exerciseRaw, plannedSets: n, sets: sets))
            } else {
                let nSets = parsedSets.sets ?? 0
                let loadShared: LoadValue
                if let wParts, wCount > 1, wParts.count > 1 {
                    loadShared = .unknown(raw: weightCell?.text ?? "")
                } else {
                    loadShared = ExcelValueParsers.parseLoadValue(weightCell?.text, exerciseNameLower: nameLower).value
                }
                let targetCategory = targetCell.map { categoryOf($0.styleIndex) } ?? .general
                let actualCategory = actualCell.map { categoryOf($0.styleIndex) } ?? .general
                let targetResult = ExcelValueParsers.parseRepTargetCellSingleBlock(targetCell, category: targetCategory)
                let actualResult = ExcelValueParsers.parseRepTargetCellSingleBlock(actualCell, category: actualCategory)
                if isPerSide(targetResult.value) || isPerSide(actualResult.value) {
                    stats.unilateralKeys.insert(key)
                }
                let sets = (0..<nSets).map {
                    ParsedSetLog(setIndex: $0, load: loadShared, target: targetResult.value, actual: actualResult.value, isInferred: true)
                }
                entries.append(ParsedExerciseEntry(order: 0, exerciseKey: key, exerciseRaw: exerciseRaw, plannedSets: nSets, sets: sets))
            }
            stats.record(key: key, variant: exerciseRaw)
        }

        // `restRaw` is never nil-ed for an empty string -- `migrate.py`'s
        // `parse_rest("")` returns `(None, "")`, not `(None, None)`, and
        // that empty string IS what lands in gymlog_seed.json (confirmed:
        // session 80/block row 819 has `"restRaw": ""` in the real seed).
        return ParsedSessionBlock(
            order: 0, blockType: blockType, restSeconds: restSeconds, restRaw: restRaw,
            note: note, sourceRow: rowNumber, entries: entries
        )
    }

    private static func isPerSide(_ target: RepTarget) -> Bool {
        if case .perSide = target { return true }
        return false
    }

    private static func leadingNumericPrefix(_ text: String) -> Double? {
        guard let m = wholeMatchPrefix(#"^(\d+(?:\.\d+)?)"#, text) else { return nil }
        return Double(m)
    }

    /// Splits on `\s+\+\s+` (one-or-more spaces, a literal `+`, one-or-more
    /// spaces) -- `migrate.py`'s `SPLIT_RE`. A plain `+`-with-no-surrounding-
    /// space (as can appear inside a band color like `"G+B"`, which is a
    /// LOAD value, not an exercise name) must NOT be split on, which is
    /// exactly why this requires the space-padded regex rather than a
    /// literal `"+"` split.
    private static func splitOnPlus(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\s+\+\s+"#) else { return [text] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var result: [String] = []
        var lastEnd = text.startIndex
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let matchRange = Range(match.range, in: text) else { return }
            result.append(String(text[lastEnd..<matchRange.lowerBound]))
            lastEnd = matchRange.upperBound
        }
        result.append(String(text[lastEnd..<text.endIndex]))
        return result
    }

    // MARK: - §3.7 date reconstruction with serial-year anchoring

    struct DateResult {
        let date: Date
        let dateOrigin: DateOrigin
        let needsReview: Bool
        let reviewReason: String?
    }

    /// The one known, allowed date reversal (CONTRACT.md §8.1 amendment):
    /// both sides are unconverted text dates -- a coach data-entry slip, not
    /// a conversion artifact. Reconstruct-and-flag, never invent a "fixed"
    /// date.
    private static let knownReversalCurRaw = "21/7"
    private static let knownReversalPrevRaw = "24/7"

    private static func reconstructDates(_ rawSessions: [RawSession]) throws -> [DateResult] {
        struct Interim {
            let month: Int
            let day: Int
            let origin: DateOrigin
            let serialYear: Int?
            let raw: String
        }

        var interims: [Interim] = []
        for session in rawSessions {
            let raw = session.dateRaw.trimmingCharacters(in: .whitespaces)
            if raw.contains("/") {
                let components = raw.split(separator: "/")
                guard components.count >= 2, let d = Int(components[0]), let mo = Int(components[1]) else {
                    interims.append(Interim(month: 1, day: 1, origin: .asRecorded, serialYear: nil, raw: raw))
                    continue
                }
                interims.append(Interim(month: mo, day: d, origin: .asRecorded, serialYear: nil, raw: raw))
            } else {
                let serial = Int(Double(raw) ?? 0)
                let parts = ExcelEpoch.date(fromSerial: serial)
                // Swap: Excel's month becomes day, Excel's day becomes month.
                interims.append(Interim(month: parts.day, day: parts.month, origin: .reconstructed, serialYear: parts.year, raw: raw))
            }
        }

        guard interims.contains(where: { $0.origin == .reconstructed }) else {
            throw WorkbookSessionParserError.noDateAnchor
        }

        var years = [Int?](repeating: nil, count: interims.count)
        for (index, interim) in interims.enumerated() where interim.origin == .reconstructed {
            years[index] = interim.serialYear
        }

        // Forward pass: fill `asRecorded` runs from the nearest preceding
        // anchor using month-rollback detection (>=6 months back => new year).
        var lastKnownYear: Int?
        var lastKnownMonth: Int?
        for index in interims.indices {
            if let y = years[index] {
                lastKnownYear = y
                lastKnownMonth = interims[index].month
                continue
            }
            guard let y = lastKnownYear, let prevMonth = lastKnownMonth else { continue }
            let month = interims[index].month
            let newYear = (month < prevMonth && (prevMonth - month) >= 6) ? y + 1 : y
            years[index] = newYear
            lastKnownYear = newYear
            lastKnownMonth = month
        }
        // Backward pass: a leading `asRecorded` run before the first anchor.
        var nextKnownYear: Int?
        var nextKnownMonth: Int?
        for index in interims.indices.reversed() {
            if let y = years[index] {
                nextKnownYear = y
                nextKnownMonth = interims[index].month
                continue
            }
            guard years[index] == nil else { continue }
            guard let y = nextKnownYear, let nextMonth = nextKnownMonth else { continue }
            let month = interims[index].month
            let inferredYear = (month > nextMonth && (month - nextMonth) >= 6) ? y - 1 : y
            years[index] = inferredYear
            nextKnownYear = inferredYear
            nextKnownMonth = month
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        var results: [DateResult] = []
        var previousDate: Date?
        var previousRaw: String?
        var reversalCount = 0

        for (index, interim) in interims.enumerated() {
            guard let year = years[index] else {
                throw WorkbookSessionParserError.noDateAnchor
            }
            var components = DateComponents()
            components.year = year
            components.month = interim.month
            components.day = interim.day
            guard let thisDate = calendar.date(from: components) else {
                throw WorkbookSessionParserError.dateOrderingBroken(detail: "invalid calendar date for \(interim.raw)")
            }

            var needsReview = false
            var reviewReason: String?
            if let prev = previousDate, thisDate < prev {
                if interim.raw == knownReversalCurRaw, previousRaw == knownReversalPrevRaw {
                    needsReview = true
                    reviewReason = "源数据日期逆序（raw='24/7'→'21/7'），两侧均为 Excel 未转换的文本日期，疑似教练录入笔误（按周节奏本应落在 7 月 27-31 日）。按契约 §8.1 保留原值，不做修正，由教练本人判定是否修正。"
                    reversalCount += 1
                    let daysBack = calendar.dateComponents([.day], from: thisDate, to: prev).day ?? 0
                    if reversalCount > 3 || daysBack > 30 {
                        throw WorkbookSessionParserError.dateOrderingBroken(detail: "reversal exceeds §3.7 tolerance (count=\(reversalCount), daysBack=\(daysBack))")
                    }
                } else {
                    let daysBack = calendar.dateComponents([.day], from: thisDate, to: prev).day ?? 0
                    reversalCount += 1
                    if reversalCount > 3 || daysBack > 30 {
                        throw WorkbookSessionParserError.dateOrderingBroken(detail: "unexpected date reversal at raw=\(interim.raw), \(daysBack) days back from \(String(describing: previousRaw))")
                    }
                    needsReview = true
                    reviewReason = "年份由推断得出且与后续錨點衝突"
                }
            }

            results.append(DateResult(date: thisDate, dateOrigin: interim.origin, needsReview: needsReview, reviewReason: reviewReason))
            previousDate = thisDate
            previousRaw = interim.raw
        }
        return results
    }

    // MARK: - §3.6 exercise assembly (canonical name / aliases / merge candidates)

    private static func assembleExercises(stats: ExerciseStatsAggregator) -> [ParsedExercise] {
        let keys = stats.statsByKey.keys.sorted()
        var mergeCandidates: [String: Set<String>] = [:]
        for i in keys.indices {
            for j in (i + 1)..<keys.count {
                let k1 = keys[i], k2 = keys[j]
                if abs(k1.count - k2.count) > 3 { continue }
                if levenshtein(k1, k2) <= 2 {
                    mergeCandidates[k1, default: []].insert(k2)
                    mergeCandidates[k2, default: []].insert(k1)
                }
            }
        }

        var exercises: [ParsedExercise] = []
        for key in keys {
            let info = stats.statsByKey[key]!
            let maxCount = info.variantCounts.values.max() ?? 0
            let mostCommonVariant = info.variantOrder.first { info.variantCounts[$0] == maxCount } ?? key
            let canonicalName = mostCommonVariant
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let aliases = info.variantOrder.sorted()

            let classification = ExerciseClassifier.classify(key: key)
            let isAssisted = ExerciseNameCanonicalizer.isAssistedExercise(key: key)
            let loadDirection: LoadDirection = isAssisted ? .lowerIsStronger : .higherIsStronger

            var isUnilateral = RegexSearch.contains(#"\bsl\b|unilateral|single arm|one arm|single leg"#, in: key, caseInsensitive: true)
            if stats.unilateralKeys.contains(key) { isUnilateral = true }

            var needsReview = classification.needsReview
            var reasons = classification.needsReview ? [classification.reason] : []
            if isAssisted {
                needsReview = true
                reasons.append("assisted exercise (w/assist or assisted) — loadDirection=lowerIsStronger, must be confirmed (§7.3): lower value = stronger")
            }
            if let candidates = mergeCandidates[key], !candidates.isEmpty {
                needsReview = true
                reasons.append("possible duplicate/merge candidate: " + candidates.sorted().joined(separator: ", "))
            }
            if stats.bareModifierKeys.contains(key) {
                needsReview = true
                reasons.append("canonicalName synthesized from a bare-modifier superset component (§7.5 v2) — confirm this variation naming with the coach")
            }
            if stats.unilateralKeys.contains(key), !key.contains("sl"), !key.contains("unilateral") {
                needsReview = true
                reasons.append("isUnilateral inferred from a §7.8 perSide RepTarget (2 comma-separated reps), not from the exercise name — confirm")
            }

            exercises.append(ParsedExercise(
                key: key, id: ExerciseNameCanonicalizer.stableExerciseID(key), canonicalName: canonicalName,
                aliases: aliases, movementPattern: classification.movementPattern, equipment: classification.equipment,
                loadDirection: loadDirection, isUnilateral: isUnilateral, occurrenceCount: info.count,
                needsReview: needsReview, reviewReason: reasons.isEmpty ? nil : reasons.joined(separator: "; "),
                recordingMetric: classification.recordingMetric
            ))
        }
        return exercises.sorted { $0.canonicalName.lowercased() < $1.canonicalName.lowercased() }
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let aChars = Array(a), bChars = Array(b)
        var prev = Array(0...bChars.count)
        for (i, ca) in aChars.enumerated() {
            var cur = [i + 1] + [Int](repeating: 0, count: bChars.count)
            for (j, cb) in bChars.enumerated() {
                cur[j + 1] = min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (ca == cb ? 0 : 1))
            }
            prev = cur
        }
        return prev[bChars.count]
    }

    // MARK: - Regex helpers local to this file

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

    private static func wholeMatchPrefix(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let result = regex.firstMatch(in: text, options: [], range: range), result.numberOfRanges > 1,
              let r = Range(result.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
