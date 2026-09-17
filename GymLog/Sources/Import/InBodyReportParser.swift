import Foundation
import CoreGraphics

/// One recognized word, in pixel coordinates with the origin at TOP-LEFT
/// (Vision's own coordinate system has its origin at bottom-left; the
/// caller -- `InBodyTextRecognizer` -- is responsible for converting before
/// producing these, so this whole file only ever deals with one consistent
/// coordinate frame). Deliberately word-level, not line-level: CONTRACT-M7.md
/// §2.3's anchoring algorithm needs to reason about "the token immediately
/// to the right of the label," which requires word granularity.
public struct RecognizedToken {
    public let text: String
    public let rect: CGRect
    public let confidence: Float

    public init(text: String, rect: CGRect, confidence: Float) {
        self.text = text
        self.rect = rect
        self.confidence = confidence
    }
}

public enum FieldConfidence: Equatable {
    case confident
    case uncertain
    case missing
}

public struct InBodyScanResult {
    public var date: Date?
    public var dateConfidence: FieldConfidence = .missing
    public var weightKg: Double?
    public var weightConfidence: FieldConfidence = .missing
    public var bodyFatPercent: Double?
    public var bodyFatConfidence: FieldConfidence = .missing
    public var skeletalMuscleKg: Double?
    public var skeletalMuscleConfidence: FieldConfidence = .missing
    public var bmi: Double?
    public var bmiConfidence: FieldConfidence = .missing
    public var visceralFatLevel: Int?
    public var visceralFatConfidence: FieldConfidence = .missing
    public var bmr: Double?
    public var bmrConfidence: FieldConfidence = .missing
    public var bodyFatMassKg: Double?
    public var bodyFatMassConfidence: FieldConfidence = .missing
    /// CONTRACT-M7.md §2.4 / OQ-6: a compact auto-generated line for
    /// whatever the report shows that `BodyMetric` has no field for (TBW,
    /// Protein, Minerals, WHR, Obesity Degree, InBody Score, Target
    /// Weight -- Body Fat Mass used to be one of these too, until it got
    /// its own `bodyFatMassKg` field). Prefilled into the review form's
    /// Notes field, freely editable/clearable there.
    public var notes: String?
    /// §2.7's "is this even an InBody report" gate. `false` means the
    /// caller must show the "doesn't look like an InBody report" error,
    /// not the review form.
    public var passedThreshold = false

    public init() {}
}

/// CONTRACT-M7.md §2.3/§2.4/§2.7: pure function over already-recognized OCR
/// tokens (never touches Vision or an image directly -- see
/// `InBodyTextRecognizer` for that layer) that anchors each label to its
/// value by 2D position, exactly as specified: geometric line-clustering,
/// numeric-token detection with reference-range exclusion, then a
/// right-then-below search from each label's bounding box.
public enum InBodyReportParser {
    // MARK: - Geometry primitives

    private struct Line {
        let tokens: [RecognizedToken]
        let text: String
        let tokenRanges: [Range<String.Index>]
        let midY: CGFloat
        let rect: CGRect
    }

    /// Estimate the page's skew angle from the token cloud and rotate every
    /// rect back to horizontal before any line clustering happens.
    ///
    /// `buildLines` clusters purely by `midY`, which silently assumes the
    /// report's rows ARE horizontal. A photo taken by hand never is: at a
    /// mere 2 degrees of tilt, a row spanning 900px drifts ~31px vertically
    /// -- a full line height -- so one physical row smears across several
    /// clusters while unrelated rows merge into one. That is not a cosmetic
    /// problem; it is what makes a chart's axis scale ("55 70 85 100...")
    /// land on the same reconstructed line as a field label, which is
    /// exactly how an axis tick gets returned as a field's value. Measured
    /// on `Fixtures/inbody_sample.jpg` rotated by -2 degrees: SMM went
    /// missing entirely, PBF read 35.0 (an axis tick) instead of 28.7, and
    /// BMI read 100.0 instead of 26.0 -- all three "recognized" with
    /// `.confident`, and `passedThreshold` still true, so the review form
    /// happily showed the garbage.
    ///
    /// The angle is estimated from the median of the angles between each
    /// token and its nearest same-row right-neighbour. Median (not mean)
    /// because a two-column page and stacked label blocks both produce a
    /// minority of wildly wrong pairings, and the median simply ignores
    /// them.
    private static func deskewed(_ tokens: [RecognizedToken], lineHeight: CGFloat) -> [RecognizedToken] {
        guard tokens.count >= 8, lineHeight > 0 else { return tokens }

        let byX = tokens.sorted { $0.rect.minX < $1.rect.minX }
        var angles: [CGFloat] = []
        for (index, token) in byX.enumerated() {
            var neighbour: RecognizedToken?
            var cursor = index + 1
            while cursor < byX.count {
                let other = byX[cursor]
                let gap = other.rect.minX - token.rect.maxX
                // `byX` is sorted by minX, so `gap` only grows from here.
                if gap > 3 * lineHeight { break }
                cursor += 1
                guard gap >= 0,
                      abs(other.rect.midY - token.rect.midY) < 0.8 * lineHeight,
                      other.rect.height >= 0.7 * token.rect.height,
                      other.rect.height <= 1.4 * token.rect.height
                else { continue }
                neighbour = other
                break
            }
            guard let neighbour else { continue }
            let dx = neighbour.rect.midX - token.rect.midX
            guard dx > 0 else { continue }
            angles.append(atan2(neighbour.rect.midY - token.rect.midY, dx))
        }

        guard angles.count >= 8 else { return tokens }
        angles.sort()
        let skew = angles[angles.count / 2]
        // Below ~0.1 degrees there is nothing to correct; above ~15 degrees
        // the estimate is more likely to be garbage than a real tilt (and a
        // photo that skewed has bigger problems than clustering).
        guard abs(skew) > 0.002, abs(skew) < 0.26 else { return tokens }

        let centerX = tokens.map(\.rect.midX).reduce(0, +) / CGFloat(tokens.count)
        let centerY = tokens.map(\.rect.midY).reduce(0, +) / CGFloat(tokens.count)
        let cosine = cos(-skew), sine = sin(-skew)
        return tokens.map { token in
            let dx = token.rect.midX - centerX
            let dy = token.rect.midY - centerY
            let newMidX = centerX + dx * cosine - dy * sine
            let newMidY = centerY + dx * sine + dy * cosine
            // Text boxes stay axis-aligned: only the centre moves. At the
            // small angles this corrects, the box's own rotation is not
            // what breaks clustering -- its Y position is.
            let rect = CGRect(
                x: newMidX - token.rect.width / 2,
                y: newMidY - token.rect.height / 2,
                width: token.rect.width,
                height: token.rect.height
            )
            return RecognizedToken(text: token.text, rect: rect, confidence: token.confidence)
        }
    }

    /// Group tokens into physical text rows by HORIZONTAL ADJACENCY, not by
    /// `midY` alone.
    ///
    /// Clustering on `midY` by itself cannot tell "a word on my row" from "a
    /// word on the row above, in a different column" -- it only sees a
    /// number. That failure is not hypothetical on this report: the chart
    /// labels are printed two-deep at the same left margin (the short code
    /// "SMM" directly above the descriptive "Skeletal Muscle Mass"), and
    /// the two are only ~0.55 line heights apart. A Y-only grouping either
    /// merges them -- and because both start at the SAME `minX`, sorting by
    /// `minX` then interleaves them into "Skeletal SMM Muscle Mass", which
    /// the `skeletal\s*muscle\s*mass` anchor no longer matches at all -- or,
    /// with a threshold tight enough to separate them, slices "Mass" off the
    /// end of its own label and onto the row above. Both were observed on
    /// `Fixtures/inbody_sample.jpg` at small tilts, and both end with SMM
    /// missing or read off the chart's axis scale.
    ///
    /// Adjacency has neither failure mode: two tokens share a row only if
    /// they are vertically close AND close enough horizontally to be
    /// consecutive words, and rows are then the connected components of
    /// that relation. "Mass" joins "Muscle" (10px apart horizontally, 2px
    /// vertically) no matter what else is nearby; "SMM" joins neither
    /// (21px of vertical separation), even though it overlaps them in X.
    ///
    /// Only sound AFTER `deskewed`: on a tilted page a single row's own
    /// `midY` drift exceeds the vertical tolerance, so a long row would
    /// fragment.
    private static func makeLine(_ group: [RecognizedToken]) -> Line {
        let sorted = group.sorted { $0.rect.minX < $1.rect.minX }
        var text = ""
        var ranges: [Range<String.Index>] = []
        for (index, token) in sorted.enumerated() {
            if index > 0 { text += " " }
            let start = text.endIndex
            text += token.text
            ranges.append(start..<text.endIndex)
        }
        let unionRect = sorted.dropFirst().reduce(sorted[0].rect) { $0.union($1.rect) }
        let avgMidY = sorted.map(\.rect.midY).reduce(0, +) / CGFloat(sorted.count)
        return Line(tokens: sorted, text: text, tokenRanges: ranges, midY: avgMidY, rect: unionRect)
    }

    private static func buildRowGroups(_ tokens: [RecognizedToken], lineHeight: CGFloat) -> [[RecognizedToken]] {
        guard !tokens.isEmpty else { return [] }
        let byX = tokens.sorted { $0.rect.minX < $1.rect.minX }

        // Wide enough for the gap between two words, and between two ticks
        // of a chart's axis scale; far too narrow to jump the ~300px of
        // empty chart between a row's label and the value printed at the
        // end of its bar (which `findValue` reaches via its own band, not
        // via this grouping).
        let maxGapX = 1.5 * lineHeight
        let maxDeltaY = 0.3 * lineHeight

        var parent = Array(byX.indices)
        func find(_ i: Int) -> Int {
            var root = i
            while parent[root] != root { root = parent[root] }
            var current = i
            while parent[current] != current {
                let next = parent[current]
                parent[current] = root
                current = next
            }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            let (rootA, rootB) = (find(a), find(b))
            if rootA != rootB { parent[rootB] = rootA }
        }

        for i in byX.indices {
            var j = i + 1
            while j < byX.count {
                let gap = byX[j].rect.minX - byX[i].rect.maxX
                // `byX` is sorted by minX, so `gap` only grows from here.
                if gap > maxGapX { break }
                if abs(byX[j].rect.midY - byX[i].rect.midY) <= maxDeltaY {
                    union(i, j)
                }
                j += 1
            }
        }

        var buckets: [Int: [RecognizedToken]] = [:]
        for index in byX.indices {
            buckets[find(index), default: []].append(byX[index])
        }
        return Array(buckets.values)
    }

    private static func buildLines(_ tokens: [RecognizedToken]) -> (rows: [Line], allTokens: [RecognizedToken], lineHeight: CGFloat) {
        guard !tokens.isEmpty else { return ([], [], 0) }
        let heights = tokens.map(\.rect.height).sorted()
        let lineHeight = heights[heights.count / 2]

        let corrected = deskewed(tokens, lineHeight: lineHeight)
        let rows = buildRowGroups(corrected, lineHeight: lineHeight)
            .map { makeLine($0) }
            .sorted { $0.midY < $1.midY }
        return (rows, corrected, lineHeight)
    }

    // MARK: - Numeric token judgment (§2.3)

    private static let numericUnits = ["kg", "%", "kcal", "cm", "l", "pts"]

    private static func cleanedNumericText(_ raw: String) -> String? {
        var text = raw
        while let first = text.first, ",:。；".contains(first) {
            text.removeFirst()
        }
        while let last = text.last, ",:。；".contains(last) {
            text.removeLast()
        }
        let lower = text.lowercased()
        for unit in numericUnits {
            if lower.hasSuffix(unit) {
                text = String(text.dropLast(unit.count))
                break
            }
        }
        // A chart axis printed "14.50 16.50 18.50 21.75 ..." comes back
        // from a photo as "14,50 16,50 18,50 21.75 ..." often enough that
        // it decides whether the scale is recognized as a scale at all:
        // `axisTokenKeys` needs five NUMERIC tokens in a band before it
        // will call one a scale, and a comma-for-dot slip makes each of
        // them non-numeric. On the X-Contact 356's B.M.I. row that left
        // only three usable ticks, the axis went undetected, and the
        // "nearest number right of the label" search was free to return
        // a tick (21.75) as the client's BMI.
        //
        // Only `\d+,\d{1,2}` is read as a decimal comma -- a three-digit
        // group is a thousands separator ("1,445" is 1445, not 1.445).
        if RegexSearch.wholeMatch(#"^\d{1,5},\d{1,2}$"#, text) {
            text = text.replacingOccurrences(of: ",", with: ".")
        } else if RegexSearch.wholeMatch(#"^\d{1,2}(,\d{3})+$"#, text) {
            text = text.replacingOccurrences(of: ",", with: "")
        }
        return text.isEmpty ? nil : text
    }

    private static func isNumericToken(_ token: RecognizedToken) -> Bool {
        guard let cleaned = cleanedNumericText(token.text) else { return false }
        return RegexSearch.wholeMatch(#"^[+-]?\d{1,5}(\.\d{1,2})?$"#, cleaned)
    }

    /// A standalone unit token ("kg", "%", "L"...) with no digits at all --
    /// distinct from `isNumericToken`, which is for a NUMBER that happens
    /// to carry a unit suffix (e.g. "65.1kg"). Used to let a same-line
    /// value search step over a lone unit column between a label and its
    /// value without treating a REAL label word the same way. Includes a
    /// couple of tokens beyond `numericUnits`: real Vision output on
    /// "(kg/m²)" (BMI's unit) sometimes splits into two overlapping-rect
    /// words "m" and "kg" rather than one clean token, and "m"/"m2" alone
    /// isn't in `numericUnits` (which exists to be stripped as a NUMBER's
    /// suffix, not matched as its own bare token).
    private static func isBareUnitToken(_ token: RecognizedToken) -> Bool {
        numericUnits.contains(token.text.lowercased())
            // "(kg/m2)" and "(cm2)" lose their punctuation and their
            // superscript to OCR in several shapes -- "m2", "mz", "m²" --
            // and any one of them sitting in the unit column between a
            // label and its value is enough to make the same-line search
            // give up on the whole row (see `findValue`'s between-check).
            || ["m", "m2", "mz", "m²", "cm2", "cmz", "cm²", "kgm", "kgm2"].contains(token.text.lowercased())
    }

    /// Only a known *different* field label can protect a below-anchor
    /// candidate. Generic text is deliberately ignored: on the chart row,
    /// the first tick (`55`) may sit immediately after `SMM`, while a
    /// descriptive label split over rows may leave `Mass 30.9` below
    /// `Skeletal Muscle`. Both are valid same-field layouts and must remain
    /// available to the field's own search.
    private static let crossFieldLabelPatterns = [
        #"\bbmi\b"#, #"body\s*mass\s*index"#,
        #"\bpbf\b"#, #"percent\s*body\s*fat"#, #"body\s*fat\s*(?:percent(?:age)?|%)"#,
        #"\bweight(?:\s*\(\s*kg\s*\))?\b"#
    ]

    private static func hasAdjacentDifferentFieldLabel(
        before token: RecognizedToken,
        allTokens: [RecognizedToken],
        lineHeight: CGFloat,
        excluding ownPatterns: [String]
    ) -> Bool {
        let labels = allTokens
            .filter {
                !isNumericToken($0) && !isBareUnitToken($0)
                    && $0.rect.maxX <= token.rect.minX
                    && abs($0.rect.midY - token.rect.midY) <= 0.3 * lineHeight
            }
            .sorted { ($0.rect.minX, $0.rect.maxX) < ($1.rect.minX, $1.rect.maxX) }
        guard var suffix = labels.last.map({ [$0] }) else { return false }
        for label in labels.dropLast().reversed() {
            guard let next = suffix.first,
                  next.rect.minX - label.rect.maxX <= 1.5 * lineHeight else { break }
            suffix.insert(label, at: 0)
        }
        let prefix = suffix.map(\.text).joined(separator: " ")

        return crossFieldLabelPatterns.contains { otherPattern in
            RegexSearch.contains(otherPattern, in: prefix, caseInsensitive: true)
                && !ownPatterns.contains { ownPattern in
                    RegexSearch.contains(ownPattern, in: prefix, caseInsensitive: true)
                }
        }
    }

    /// §2.3's reference-range exclusion: a token must not be read as a
    /// value if it's part of a "(36.6~44.7)"-style normal-range annotation.
    ///
    /// Tracks paren DEPTH from `searchFrom` up to (not including)
    /// `tokenIndex`, rather than just "is there any '(' earlier on the
    /// line" -- a self-contained unit annotation like "(kg)" is a single
    /// token containing both '(' and ')', netting to depth 0, so it does
    /// NOT poison every token after it. Only an actually-unclosed '(' --
    /// the real "(" of a "(", "36.6~44.7", ")" reference-range span split
    /// across tokens -- leaves depth > 0 and excludes what follows. First
    /// implementation used "position after the first paren-containing
    /// token," which wrongly excluded the real value whenever a unit paren
    /// like "(kg)"/"(L)" preceded it on the same line -- confirmed against
    /// a token layout modeled on the real report, where this is the norm,
    /// not an edge case. `searchFrom` is the anchor's own token count on
    /// its line (so the label's OWN parens, if the anchor pattern itself
    /// included them, aren't double-counted); on the below-anchor line
    /// there's no anchor to skip past, so `searchFrom` is simply 0.
    private static func isExcludedByReferenceRange(_ token: RecognizedToken, in line: Line, tokenIndex: Int, searchFrom: Int) -> Bool {
        if token.text.contains(where: { "()~-".contains($0) }) { return true }
        var depth = 0
        for index in searchFrom..<tokenIndex {
            let text = line.tokens[index].text
            depth += text.filter { $0 == "(" }.count
            depth -= text.filter { $0 == ")" }.count
        }
        if depth > 0 { return true }
        if tokenIndex > 0 {
            let combined = line.tokens[tokenIndex - 1].text + token.text
            if RegexSearch.wholeMatch(#"^\d+(?:\.\d+)?~\d+(?:\.\d+)?$"#, combined) { return true }
        }
        return false
    }

    /// A token's stable identity, so the globally-computed axis set can be
    /// consulted from any later regrouping of the same tokens.
    private struct TokenKey: Hashable {
        let x: CGFloat
        let y: CGFloat
        let text: String
    }

    private static func key(_ token: RecognizedToken) -> TokenKey {
        TokenKey(x: token.rect.minX, y: token.rect.minY, text: token.text)
    }

    /// Every token on the page that belongs to a chart's AXIS SCALE rather
    /// than being a value.
    ///
    /// Every bar chart on an InBody report is drawn over a printed scale
    /// ("55 70 85 100 115 130 145 160 175 190 205" under the SMM bar,
    /// "0.0 5.0 10.0 ... 50.0" under PBF). Those ticks sit at nearly the
    /// same page height as the row's label, so a "nearest number to the
    /// right of the label" search will happily return one -- and it looks
    /// like a perfectly good number, so nothing downstream catches it. This
    /// is how the parser produced a confident PBF of 35.0 and BMI of 100.0
    /// on a tilted photo, and a confident SMM of 70.0 on a perfectly
    /// straight one.
    ///
    /// Grouped into horizontal BANDS of numeric tokens, deliberately NOT
    /// into the adjacency rows used for text. A scale's ticks are collinear
    /// but not reliably contiguous: OCR drops or mangles one every so often
    /// ("110" came back as "11o", "130" vanished entirely, on a clean
    /// 2000px-wide render of the sample), which opens a two-tick-wide hole.
    /// Adjacency then splits one scale into two fragments, each too short
    /// to look like a scale -- which is exactly how SMM came back as 70.0.
    /// A Y-band does not care about the hole.
    private static func axisTokenKeys(allTokens: [RecognizedToken], pageWidth: CGFloat, lineHeight: CGFloat) -> Set<TokenKey> {
        // Numbers that SHARE a bounding box are never a scale's ticks: a
        // printed scale has each tick as its own observation with its own
        // box, whereas a shared box means Vision could not split a run at
        // all (a bracketed reference range, or a whole line it returned as
        // one observation). Dropping them first is what stops the page
        // HEADER from being mistaken for a scale -- "Date 02-07-2018 21:23
        // ... Height 172.0 cm Weight 68.8 kg" reads as the ascending run
        // 02, 07, 21, 23, 172.0 spanning half the page, and the growth step
        // then swallowed the client's own weight, which is why that field
        // came back missing off a photo that prints it perfectly legibly.
        // Deduplicated the run collapses to four entries and is correctly
        // not a scale.
        var boxCounts: [RectKey: Int] = [:]
        for token in allTokens where isNumericToken(token) { boxCounts[RectKey(token.rect), default: 0] += 1 }
        let numerics = allTokens
            .filter { isNumericToken($0) && boxCounts[RectKey($0.rect)] == 1 }
            .sorted { $0.rect.midY < $1.rect.midY }
        guard numerics.count >= 5 else { return [] }

        // Tight enough that a chart's value label -- printed at the end of
        // its bar, half a line height or more below the scale -- lands in a
        // different band than the ticks. That separation is what stops a
        // value from being mistaken for one of its own ticks: the label sits
        // at exactly the X position its value occupies on the scale, so
        // pooled together it would slot into the increasing run perfectly.
        let bandTolerance = 0.4 * lineHeight
        var bands: [[RecognizedToken]] = []
        for token in numerics {
            if let last = bands.last?.last, token.rect.midY - last.rect.midY <= bandTolerance {
                bands[bands.count - 1].append(token)
            } else {
                bands.append([token])
            }
        }

        var keys: Set<TokenKey> = []
        for band in bands where band.count >= 5 {
            let byX = band.sorted { $0.rect.minX < $1.rect.minX }
            let values = byX.map { numericValue($0) ?? 0 }

            // Longest strictly-increasing subsequence over the numbers in X
            // order -- O(n^2) is irrelevant at these sizes and keeps the
            // reconstruction obvious.
            var length = [Int](repeating: 1, count: values.count)
            var previous = [Int](repeating: -1, count: values.count)
            for i in values.indices {
                for j in 0..<i where values[j] < values[i] && length[j] + 1 > length[i] {
                    length[i] = length[j] + 1
                    previous[i] = j
                }
            }
            guard let best = length.indices.max(by: { length[$0] < length[$1] }), length[best] >= 5 else { continue }

            var run: [Int] = []
            var cursor = best
            while cursor != -1 {
                run.append(cursor)
                cursor = previous[cursor]
            }
            run.reverse()
            let runRects = run.map { byX[$0].rect }
            let span = (runRects.map(\.maxX).max() ?? 0) - (runRects.map(\.minX).min() ?? 0)
            guard span >= 0.25 * pageWidth else { continue }

            // Tick pitch, from the run itself.
            let centres = runRects.map(\.midX).sorted()
            let gaps = zip(centres.dropFirst(), centres).map { $0 - $1 }.sorted()
            let spacing = gaps[gaps.count / 2]
            guard spacing > 0 else { continue }

            // Grow the run outward along the band, hopping at most two tick
            // pitches at a time. This picks up the ticks the run itself had
            // to skip -- one misread out of sequence ("10.0 15.0" came back
            // as "100 150", which sorts outside the increasing run and was
            // then returned as a confident BMI of 100.0) -- while the hop
            // limit stops the growth well before the page's other column,
            // whose numbers are a real field's values and must be left alone.
            var included = Set(run)
            var changed = true
            while changed {
                changed = false
                for index in byX.indices where !included.contains(index) {
                    let nearest = included.map { abs(byX[$0].rect.midX - byX[index].rect.midX) }.min() ?? .greatestFiniteMagnitude
                    if nearest <= 2 * spacing {
                        included.insert(index)
                        changed = true
                    }
                }
            }
            for index in included { keys.insert(key(byX[index])) }
        }
        return keys
    }

    /// A rect used as a dictionary key. `CGRect` is `Hashable` already,
    /// but only bit-for-bit; these rects come from the same Vision
    /// observation and are therefore genuinely identical, so exact
    /// comparison is what is wanted here.
    private struct RectKey: Hashable {
        let x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
        init(_ rect: CGRect) {
            (x, y, width, height) = (rect.minX, rect.minY, rect.width, rect.height)
        }
    }

    /// Numeric tokens that are the two ends of a printed reference range,
    /// found by the one thing about them OCR reliably preserves: they
    /// share a bounding box.
    ///
    /// `isExcludedByReferenceRange` reasons about brackets, tildes and
    /// paren depth -- exactly what Vision's `.byWords` enumeration throws
    /// away. On a real photo the X-Contact 356's "[52.0~55.3]" comes back
    /// as two bare words, "152.0" and "55.31" (the brackets absorbed into
    /// the digits), with no paren, no tilde, and nothing in the TEXT to
    /// say these are a range rather than two readings. What they do have
    /// is one shared rect: Vision could not compute per-word boxes inside
    /// that run, so `candidate.boundingBox(for:)` handed both words the
    /// whole observation's box. Every reference range on that report --
    /// and on the InBody120's "(36.6~44.7)" too -- collapses the same way.
    ///
    /// Without this the below-the-label search reads a range bound as the
    /// value: measured on the two real X-Contact photos, Protein came back
    /// as 11.7 (the top of "[10.4~11.7]") on a row whose actual value the
    /// OCR never even read.
    ///
    /// Exactly TWO numerics in a shared box is the discriminating case. A
    /// whole row that OCR happened to return as a single observation
    /// ("Trunk 24.92Kg [24.15~25.71]") collapses into a shared box as
    /// well, but carries three -- and its first one is a real value -- so
    /// that group is deliberately left alone.
    private static func referenceRangeKeys(allTokens: [RecognizedToken]) -> Set<TokenKey> {
        var groups: [RectKey: [RecognizedToken]] = [:]
        for token in allTokens {
            groups[RectKey(token.rect), default: []].append(token)
        }
        var keys: Set<TokenKey> = []
        for group in groups.values where group.count >= 2 {
            let numerics = group.filter { isNumericToken($0) }
            guard numerics.count == 2 else { continue }
            for token in numerics { keys.insert(key(token)) }
        }
        return keys
    }

    // MARK: - Anchor + value search (§2.3)

    private struct AnchorHit {
        let rowIndex: Int
        let rect: CGRect
    }

    private static func findAnchor(patterns: [String], excludeLine: (String) -> Bool, rows: [Line]) -> AnchorHit? {
        findAnchors(patterns: patterns, excludeLine: excludeLine, rows: rows).first
    }

    /// EVERY row a label matches, in pattern-then-page order.
    ///
    /// The old single-hit version was written for a report that prints
    /// each field once. The X-Contact 356 prints most of them four times
    /// -- in Body Composition, on the Body Status chart, in the Control
    /// Guide, and again in the Body Composition Change table at the foot
    /// of the page -- and print quality decides which of those the OCR
    /// can actually read. On one of the two real photos the topmost
    /// "S.M.M." (Body Composition) has a value too faint for Vision to
    /// see at all, with only its reference range legible; taking that
    /// first hit and stopping is why the field came back missing rather
    /// than reading 30.1 off the chart row two hundred pixels below.
    ///
    /// Capped, because a loose pattern on a busy page could otherwise turn
    /// one field into dozens of full-page value searches.
    private static func findAnchors(patterns: [String], excludeLine: (String) -> Bool, rows: [Line]) -> [AnchorHit] {
        // Real reports can be a two-column page (e.g. Body Composition
        // Analysis on the left, InBody Score / Weight Control / Research
        // Parameters on the right at the SAME height) -- an unrelated column
        // can end up sharing a reconstructed row with the real anchor.
        // Checking `excludeLine` against the WHOLE row would let that
        // unrelated column veto a perfectly good anchor, so the check is
        // scoped to a local token window around the actual match instead.
        //
        // Rows are scanned top-down, which is what keeps a label ahead of
        // the report's own prose about it ("Compare the bar lengths of
        // Skeletal Muscle Mass...") and ahead of the Segmental Lean
        // Analysis table at the foot of the page, whose "Skeletal Muscle
        // Mass" row carries PREVIOUS measurements. Preferring a match that
        // starts its row -- to skip that prose when OCR garbles the real
        // label -- was tried and reverted: it promotes the foot-of-page
        // table's historical value, turning a missing field into a
        // confidently wrong one, which is the worse failure of the two.
        let windowRadius = 4
        let maxAnchors = 8
        var hits: [AnchorHit] = []
        for pattern in patterns {
            for (index, line) in rows.enumerated() {
                guard let matchRange = RegexSearch.firstMatchRange(pattern, in: line.text, caseInsensitive: true) else { continue }
                let coveringTokenIndices = line.tokenRanges.indices.filter { line.tokenRanges[$0].overlaps(matchRange) }
                guard !coveringTokenIndices.isEmpty else { continue }
                let minIdx = max(0, (coveringTokenIndices.min() ?? 0) - windowRadius)
                let maxIdx = min(line.tokens.count - 1, (coveringTokenIndices.max() ?? 0) + windowRadius)
                let windowText = line.tokens[minIdx...maxIdx].map(\.text).joined(separator: " ")
                if excludeLine(windowText) { continue }
                let rects = coveringTokenIndices.map { line.tokens[$0].rect }
                let unionRect = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
                guard !hits.contains(where: { $0.rowIndex == index }) else { continue }
                hits.append(AnchorHit(rowIndex: index, rect: unionRect))
                if hits.count >= maxAnchors { return hits }
            }
        }
        return hits
    }

    /// The tokens that share the anchor's visual row, gathered fresh around
    /// the anchor's own `midY` rather than taken from a precomputed cluster.
    ///
    /// The clusters `buildLines` produces are grown from whichever token
    /// happens to come first in Y order, so their boundaries fall wherever
    /// that chain happens to end -- which is not necessarily around the row
    /// the anchor is on. On the SMM row that cut is fatal: the stacked
    /// "SMM" code sits ~0.55 line heights above "Skeletal Muscle Mass", so
    /// a cluster started at "SMM" is already a full line height tall by the
    /// time it reaches the label, and the value -- printed at the end of the
    /// bar, a few px BELOW the label's baseline -- falls into the next
    /// cluster instead. Re-centring the search band on the anchor removes
    /// that dependence on cluster boundaries entirely.
    private static func rowBand(around anchor: AnchorHit, allTokens: [RecognizedToken], lineHeight: CGFloat) -> Line? {
        // Deliberately tighter than the coarse clustering threshold: it has
        // to reach the value printed a few px below the label's baseline
        // without reaching the chart axis roughly 0.7 line heights away.
        let tolerance = 0.75 * lineHeight
        let band = allTokens.filter { abs($0.rect.midY - anchor.rect.midY) <= tolerance }
        guard !band.isEmpty else { return nil }
        return makeLine(band)
    }

    /// `plausible`: the field's own reasonability range (§2.3). Used to
    /// CHOOSE between candidates, not to reject them -- when several numbers
    /// sit in the band, the nearest one that could actually be this field's
    /// value beats a nearer one that could not. A photo's tilt decides how
    /// much of a neighbouring row's content the band sees, so without this
    /// the choice between "26.0" and "100.0" for BMI came down to which one
    /// the tilt happened to place closer. If nothing in range is found the
    /// nearest candidate is still returned, so an out-of-range reading is
    /// surfaced as `.uncertain` rather than silently dropped.
    private static func findValue(near anchor: AnchorHit, rows: [Line], allTokens: [RecognizedToken], excludedKeys: Set<TokenKey>, plausible: ClosedRange<Double>?, lineHeight: CGFloat, ownPatterns: [String]) -> RecognizedToken? {
        let pageWidth = allTokens.map(\.rect.maxX).max() ?? 0
        // A label/unit/value table row (e.g. "Percent Body Fat ... 28.7")
        // can legitimately span close to a third of the page width at real
        // report DPI -- the label, its unit column, and the chart's own
        // value label can all land far apart. A small multiple of text
        // height badly under-covers this (measured up to ~500px on a
        // 1640px-wide real InBody120 photo -- see
        // Fixtures/inbody_sample.jpg), so this scales with the page's own
        // width instead of a fixed text-height multiple, which would only
        // have been correct for one specific report's DPI/layout.
        let maxGapX = max(6 * lineHeight, 0.35 * pageWidth)
        // "Right of the label" needs a little slack, because Vision's word
        // boxes are not a tight partition of the line: on a hand-held photo
        // of the X-Contact 356 the header's "Weight" box overhangs the
        // start of its own "68.8kg" by ~9px. Requiring `minX >= maxX`
        // exactly threw that reading away and the client's weight came back
        // missing off a page that prints it in four different places.
        let anchorRightEdge = anchor.rect.maxX - 0.4 * lineHeight

        if let bandLine = rowBand(around: anchor, allTokens: allTokens, lineHeight: lineHeight) {
            let searchFrom = bandLine.tokens.firstIndex { $0.rect.minX >= anchorRightEdge } ?? bandLine.tokens.count
            let sameLineCandidates = bandLine.tokens.enumerated().filter { index, token in
                guard index >= searchFrom,
                      token.rect.minX >= anchorRightEdge,
                      token.rect.minX - anchorRightEdge <= maxGapX,
                      isNumericToken(token),
                      !excludedKeys.contains(key(token)),
                      !isExcludedByReferenceRange(token, in: bandLine, tokenIndex: index, searchFrom: searchFrom)
                else { return false }
                // The page-width-scaled maxGapX above is deliberately generous
                // (a real table row's label/unit/value columns can span a
                // third of the page), but that alone would let a same-Y line
                // that merges several DIFFERENT short-code fields (e.g. "SMM
                // PBF 28.7 BMI 26.0" all on one reconstructed line) leak one
                // field's value into another's. So the gap between the anchor
                // and this candidate must contain nothing but units/numbers --
                // an actual label word sitting in between (like "PBF" between
                // "SMM" and "28.7") means that number belongs to a DIFFERENT
                // field's anchor, not this one, no matter how close it is.
                let between = bandLine.tokens[searchFrom..<index]
                return between.allSatisfy { isNumericToken($0) || isBareUnitToken($0) }
            }
            let ordered = sameLineCandidates.map(\.element).sorted { $0.rect.minX < $1.rect.minX }
            if let plausible, let inRange = ordered.first(where: { numericValue($0).map(plausible.contains) ?? false }) {
                return inRange
            }
            if let closest = ordered.first {
                return closest
            }
        }

        let maxGapY = 2.5 * lineHeight
        var belowCandidates: [RecognizedToken] = []
        for line in rows {
            for (index, token) in line.tokens.enumerated() {
                guard !excludedKeys.contains(key(token)),
                      token.rect.minY > anchor.rect.maxY,
                      token.rect.minY - anchor.rect.maxY <= maxGapY,
                      abs(token.rect.midX - anchor.rect.midX) <= 0.5 * anchor.rect.width + lineHeight,
                      isNumericToken(token),
                      !hasAdjacentDifferentFieldLabel(before: token, allTokens: allTokens, lineHeight: lineHeight, excluding: ownPatterns),
                      !isExcludedByReferenceRange(token, in: line, tokenIndex: index, searchFrom: 0)
                else { continue }
                belowCandidates.append(token)
            }
        }
        let orderedBelow = belowCandidates.sorted { $0.rect.minY < $1.rect.minY }
        if let plausible, let inRange = orderedBelow.first(where: { numericValue($0).map(plausible.contains) ?? false }) {
            return inRange
        }
        return orderedBelow.first
    }

    private static func numericValue(_ token: RecognizedToken) -> Double? {
        guard let cleaned = cleanedNumericText(token.text) else { return nil }
        return Double(cleaned)
    }

    // MARK: - Field anchor patterns (§2.3's table)

    private static let weightExclusionPattern = #"target\s*weight|weight\s*control|fat\s*control|muscle\s*control"#

    /// A regex for one of the dotted field codes used by the X-Contact /
    /// Jawon family of reports ("P.B.F.", "S.M.M.", "B.M.R." ...), written
    /// to survive all three shapes OCR returns them in.
    ///
    /// Vision drops the trailing dot but keeps the inner ones, so a clean
    /// read is a single token "P.B.F". A faint one is two tokens ("P" +
    /// "B.F"), and a faint one on the chart rows -- where the code is
    /// printed letter-spaced -- is three bare letters that `makeLine`
    /// rejoins as "P B F". Both real photos contain examples of all three
    /// on the same page, so matching only the tidy form is matching about
    /// half of them.
    ///
    /// `[.\s]*` (rather than `[.\s]+`) means the undotted spelling is
    /// covered too, which makes this a superset of a plain `\bPBF\b`.
    private static func dottedCode(_ code: String) -> String {
        #"\b"# + code.map(String.init).joined(separator: #"[.\s]*"#) + #"\b"#
    }

    /// B.M.I.'s trailing "I" is the one letter on these reports that OCR
    /// routinely gets wrong -- a bare serif capital I comes back as "l",
    /// "1", or the Cyrillic "І" (U+0406) depending on the photo.
    private static let bmiDottedPattern = #"\bB[.\s]*M[.\s]*[Il1І]\b"#
    /// Likewise B.C.M.'s "M", which one of the two real photos returned as
    /// the Cyrillic "М" (U+041C).
    private static let bcmDottedPattern = #"\bB[.\s]*C[.\s]*[MМ]\b"#

    /// Walks every row the label matched and keeps the first value that
    /// could actually BE this field, falling back to the topmost reading
    /// only when none of them is in range.
    ///
    /// The order matters and is the reason this is not just "try them all
    /// and take the best": the topmost hit is still preferred whenever it
    /// yields a plausible number, which is what keeps a report's
    /// foot-of-page history table from overruling the reading at the top
    /// of the page (see `findAnchors`). A later anchor only ever wins a
    /// field the first one could not fill.
    private static func extractField(
        rows: [Line], allTokens: [RecognizedToken], excludedKeys: Set<TokenKey>, lineHeight: CGFloat,
        patterns: [String], plausible: ClosedRange<Double>? = nil, excludeLine: (String) -> Bool = { _ in false }
    ) -> RecognizedToken? {
        var fallback: RecognizedToken?
        for anchor in findAnchors(patterns: patterns, excludeLine: excludeLine, rows: rows) {
            guard let token = findValue(near: anchor, rows: rows, allTokens: allTokens, excludedKeys: excludedKeys, plausible: plausible, lineHeight: lineHeight, ownPatterns: patterns) else { continue }
            guard let plausible else { return token }
            if let value = numericValue(token), plausible.contains(value) { return token }
            if fallback == nil { fallback = token }
        }
        return fallback
    }

    // MARK: - Main entry point

    public static func parse(tokens: [RecognizedToken]) -> InBodyScanResult {
        var result = InBodyScanResult()
        let (rows, allTokens, lineHeight) = buildLines(tokens)
        guard !rows.isEmpty else { return result }
        let excludedKeys = axisTokenKeys(allTokens: allTokens, pageWidth: allTokens.map(\.rect.maxX).max() ?? 0, lineHeight: lineHeight)
            .union(referenceRangeKeys(allTokens: allTokens))

        // Reading order, not Vision's observation order: a multi-word
        // phrase only survives the join if the words are adjacent, and
        // `rows` is the one place on this page where that is guaranteed.
        let fullText = rows.map(\.text).joined(separator: "\n")

        // Weight: exclude Target Weight / *Control lines before searching.
        if let token = extractField(rows: rows, allTokens: allTokens, excludedKeys: excludedKeys, lineHeight: lineHeight, patterns: [#"\bweight\s*\(\s*kg\s*\)"#, #"\bweight\b"#], plausible: 20...300, excludeLine: { RegexSearch.contains(weightExclusionPattern, in: $0, caseInsensitive: true) }) {
            applyReasonabilityGated(numericValue(token), range: 20...300, confidence: token.confidence, to: &result.weightKg, confidenceOut: &result.weightConfidence)
        }
        // Deliberately NOT generalised: Tanita and Omron print "Muscle
        // Mass", which is not the same quantity as skeletal muscle mass --
        // it counts smooth and cardiac muscle too, and reads ~20kg higher
        // on the same body. Mapping it onto `skeletalMuscleKg` would write
        // a confidently wrong number into a client's record, which is worse
        // than leaving the field empty for the coach to fill.
        //
        // Full descriptive name tried BEFORE the short code: on a real
        // report the short-code row ("SMM"/"PBF"/"BMI") sits directly on
        // its chart's horizontal axis scale (55 70 85 100 115...), so a
        // same-line "nearest number to the right" search grabs an axis
        // tick instead of the value -- confirmed on a real photo, where
        // this silently produced 70/0.0/10.0 instead of 30.9/28.7/26.0.
        // The descriptive-name row just below it ("Skeletal Muscle
        // Mass"/"Percent Body Fat"/"Body Mass Index") isn't on the axis's
        // row and has the real value immediately next to it.
        if let token = extractField(rows: rows, allTokens: allTokens, excludedKeys: excludedKeys, lineHeight: lineHeight, patterns: [#"skeletal\s*muscle\s*mass"#, #"skeletal\s*muscle\s*ma\w*"#, #"skeletal\s*muscle$"#, #"骨骼\s*肌(?:量|重)?"#, #"\bsmm\b"#, dottedCode("SMM")], plausible: 5...80) {
            applyReasonabilityGated(numericValue(token), range: 5...80, confidence: token.confidence, to: &result.skeletalMuscleKg, confidenceOut: &result.skeletalMuscleConfidence)
            if let smm = result.skeletalMuscleKg, let weight = result.weightKg, smm >= weight {
                result.skeletalMuscleConfidence = .uncertain
            }
        }
        if let token = extractField(rows: rows, allTokens: allTokens, excludedKeys: excludedKeys, lineHeight: lineHeight, patterns: [#"percent\s*body\s*fat"#, #"\bpbf\b"#, dottedCode("PBF"), #"body\s*fat\s*percent(?:age)?"#, #"body\s*fat\s*%"#, #"\bfat\s*%"#], plausible: 3...70) {
            applyReasonabilityGated(numericValue(token), range: 3...70, confidence: token.confidence, to: &result.bodyFatPercent, confidenceOut: &result.bodyFatConfidence)
        }
        if let token = extractField(rows: rows, allTokens: allTokens, excludedKeys: excludedKeys, lineHeight: lineHeight, patterns: [#"body\s*mass\s*index"#, #"\bbmi\b"#, bmiDottedPattern], plausible: 8...60) {
            applyReasonabilityGated(numericValue(token), range: 8...60, confidence: token.confidence, to: &result.bmi, confidenceOut: &result.bmiConfidence)
            if let bmi = result.bmi, let weight = result.weightKg {
                // Cross-check only possible once height is known -- left to
                // the caller (which has `Client.heightCm`); this parser has
                // no client context, so it cannot perform §2.3's
                // height-based BMI cross-check itself.
                _ = (bmi, weight)
            }
        }
        if let token = extractField(rows: rows, allTokens: allTokens, excludedKeys: excludedKeys, lineHeight: lineHeight, patterns: [#"visceral\s*fat\s*level"#, #"\bvfl\b"#, dottedCode("VFL"), #"visceral\s*fat\s*(?:rating|index|grade)"#, #"visceral\s*fat(?!\s*area)"#], plausible: 1...30) {
            if let value = numericValue(token), value == value.rounded(), (1...30).contains(value) {
                result.visceralFatLevel = Int(value)
                result.visceralFatConfidence = token.confidence < 0.5 ? .uncertain : .confident
            } else if let value = numericValue(token) {
                result.visceralFatLevel = Int(value)
                result.visceralFatConfidence = .uncertain
            }
        }
        if let token = extractField(rows: rows, allTokens: allTokens, excludedKeys: excludedKeys, lineHeight: lineHeight, patterns: [#"basal\s*metabolic\s*rate"#, #"\bbmr\b"#, dottedCode("BMR"), #"basal\s*metabolism"#], plausible: 500...5000) {
            applyReasonabilityGated(numericValue(token), range: 500...5000, confidence: token.confidence, to: &result.bmr, confidenceOut: &result.bmrConfidence)
        }
        if let token = extractField(rows: rows, allTokens: allTokens, excludedKeys: excludedKeys, lineHeight: lineHeight, patterns: [#"body\s*fat\s*mass"#, #"\bbfm\b"#, dottedCode("MBF"), #"\bfat\s*mass\b"#], plausible: 2...150) {
            applyReasonabilityGated(numericValue(token), range: 2...150, confidence: token.confidence, to: &result.bodyFatMassKg, confidenceOut: &result.bodyFatMassConfidence)
        }

        // Date.
        // Plain "Date:" last, after the InBody spellings: it is what the
        // X-Contact 356 prints, and it also appears again further down that
        // page as the Body Composition Change table's column header --
        // which is harmless only because rows are scanned top-down and the
        // page header always comes first.
        if let anchor = findAnchor(patterns: [#"test\s*date"#, #"date\s*/\s*time"#, #"測試日期"#, #"\bdate\b"#], excludeLine: { _ in false }, rows: rows) {
            let anchorLine = rows[anchor.rowIndex]
            // Deliberately a geometric band rather than `anchorLine.tokens`.
            // Row grouping joins words by ADJACENCY, and the X-Contact 356
            // prints "Date:" a full label-width away from its own value --
            // 117px on a 4032px-wide photo, well past the row builder's
            // ~46px word gap -- so the label ends up alone on its row with
            // the date on a row of its own. Reading only the anchor's row
            // then yields an empty string, and the whole scan silently
            // dates itself TODAY.
            //
            // Ordered by (x, then the order Vision returned them). That
            // second key is not a tie-break nicety: "02-07-2018 21:23" is
            // one observation whose five words ALL carry the same bounding
            // box, so x alone cannot order them and an unstable sort is
            // free to hand back "2018 02 07" -- which parses, as the year
            // 2007. Vision enumerates words left to right, so its own order
            // is the only thing left that knows which number is the day.
            let bandTolerance = 0.75 * lineHeight
            let dateTokenCandidates = allTokens.enumerated()
                .filter { _, token in
                    abs(token.rect.midY - anchor.rect.midY) <= bandTolerance
                        && token.rect.minX >= anchor.rect.maxX
                        && token.rect.minX - anchor.rect.maxX <= 0.35 * (allTokens.map(\.rect.maxX).max() ?? 0)
                }
                .filter { _, token in
                    !token.text.allSatisfy { "/:".contains($0) }
                        && !RegexSearch.contains(#"^time:?$"#, in: token.text, caseInsensitive: true)
                }
                .sorted { ($0.element.rect.minX, $0.offset) < ($1.element.rect.minX, $1.offset) }
                .map(\.element)
            var dateText = dateTokenCandidates.map(\.text).joined(separator: " ")
            // Real reports can print the "ID / Height / Age / Gender / Test
            // Date / Time" LABELS on one physical row and their VALUES on
            // the row directly below (a stacked header, not label:value
            // pairs side by side on one row -- confirmed on a real photo,
            // where this left dateText empty and fell through to today's
            // date). If nothing usable sat to the right of the anchor on
            // its own line, look one row down in the same X band, mirroring
            // the below-anchor fallback the numeric fields already have.
            //
            // "In the same X band" is load-bearing, not decoration: that
            // header row is a series of independent label/value columns (ID,
            // Height, Age, Gender, Test Date), so the rows just below the
            // anchor include "Male", "172cm" and the ID -- and the topmost
            // of those is not necessarily the one under THIS label. The row
            // has to actually sit beneath the anchor horizontally.
            if parseInBodyDate(dateText) == nil {
                let maxGapY = 2.5 * lineHeight
                let belowLine = rows
                    .filter { $0.midY > anchorLine.midY && $0.midY - anchorLine.midY <= maxGapY }
                    .filter { $0.rect.maxX >= anchor.rect.minX && $0.rect.minX <= anchor.rect.maxX }
                    .min { $0.midY < $1.midY }
                if let belowLine {
                    let belowText = belowLine.tokens
                        .filter { token in
                            !token.text.allSatisfy { "/:".contains($0) }
                                && !RegexSearch.contains(#"^time:?$"#, in: token.text, caseInsensitive: true)
                        }
                        .map(\.text).joined(separator: " ")
                    // Real Vision word-splitting drops ":" entirely (see
                    // the file-level notes on `M7InBodyRealReportTests`),
                    // so a real report's time never has a literal colon by
                    // the time it reaches here -- only match date+time
                    // together when a colon genuinely is present (a
                    // hand-written token fixture could still supply one);
                    // otherwise take just the date, since
                    // `parseInBodyDate`'s own time-stripper requires that
                    // colon too and silently fails without it.
                    if let dateRange = RegexSearch.firstMatchRange(
                        #"\d{1,4}[./]\d{1,2}[./]\d{1,4}\.?\s*\d{1,2}:\d{2}|\d{1,4}[./]\d{1,2}[./]\d{1,4}"#,
                        in: belowText, caseInsensitive: true
                    ) {
                        dateText = String(belowText[dateRange])
                    }
                }
            }
            if let (date, uncertain) = parseInBodyDate(dateText) {
                result.date = date
                result.dateConfidence = uncertain ? .uncertain : .confident
            } else {
                result.date = Date()
                result.dateConfidence = .uncertain
            }
        }

        // Notes (§2.4 OQ-6): compact line of values with no BodyMetric field.
        result.notes = buildNotes(rows: rows, allTokens: allTokens, excludedKeys: excludedKeys, lineHeight: lineHeight, machine: machineName(in: fullText))

        // §2.7 threshold: what the page MEASURES, not what it is called.
        //
        // This used to also require two hits from a list of brand words
        // ("InBody", "InBody Score", "Muscle-Fat"...), which made the gate
        // an answer to "is this an InBody-brand printout" when the only
        // question worth asking is "does this photo carry body-composition
        // data". A real X-Contact 356 report -- same measurements, same
        // client, different manufacturer -- scored one brand hit and was
        // refused before a single one of its values was looked at.
        //
        // Three of these six is a STRONGER statement than any title match,
        // and one no amount of branding can fake: each field needs its own
        // label matched AND a number in the right place next to it. Since
        // weight is the only one of the six that turns up outside a body
        // report at all, three of them means at least two came from
        // vocabulary -- BMI, body fat, skeletal muscle, visceral fat,
        // basal metabolic rate -- that a gym price list does not have.
        let extractedFieldCount = [
            result.weightConfidence, result.bodyFatConfidence, result.skeletalMuscleConfidence,
            result.bmiConfidence, result.visceralFatConfidence, result.bmrConfidence,
        ].filter { $0 != .missing }.count

        result.passedThreshold = extractedFieldCount >= 3
        return result
    }

    /// The analyser's own name, when the page happens to print one.
    ///
    /// Provenance only -- it is written into the note so a coach reading
    /// the record next year knows which machine produced it (different
    /// analysers disagree by a kilo or two on muscle mass, which matters
    /// when comparing across gyms). It decides NOTHING about parsing: no
    /// field, no threshold, and no note is conditional on it, and a report
    /// from a machine this does not recognize is read exactly the same
    /// way.
    private static func machineName(in fullText: String) -> String? {
        let known = [
            (#"InBody\s*\d{3}"#, "InBody"),
            (#"X[\s.-]*CONTACT|CONTACT[\s.-]*X"#, "X-Contact"),
            (#"\bTanita\b"#, "Tanita"),
            (#"\bOMRON\b"#, "Omron"),
            (#"InBody"#, "InBody"),
        ]
        for (pattern, name) in known where RegexSearch.contains(pattern, in: fullText, caseInsensitive: true) {
            return name
        }
        return nil
    }

    private static func applyReasonabilityGated(
        _ value: Double?, range: ClosedRange<Double>, confidence: Float,
        to output: inout Double?, confidenceOut: inout FieldConfidence
    ) {
        guard let value else { return }
        output = value
        if !range.contains(value) || confidence < 0.5 {
            confidenceOut = .uncertain
        } else {
            confidenceOut = .confident
        }
    }

    // MARK: - Date parsing (§2.3)

    /// Returns `(date, isAmbiguous)`. Tries `dd.MM.yyyy` -> `yyyy.MM.dd` ->
    /// `dd/MM/yyyy` -> `yyyy-MM-dd`. The sample's raw text is
    /// `"06.08.2026. 17:50"` -- time MUST be stripped before the trailing
    /// dot (stripping dots first leaves the time in place, which then
    /// leaves the trailing dot from "2026." untouched since it's no longer
    /// the last character -- got this backwards on the first pass and it
    /// silently fed "06.08.2026. 17:50" into the formatter, which parsed
    /// SOMETHING but not the right date).
    private static func parseInBodyDate(_ raw: String) -> (Date, Bool)? {
        if let parsed = parseDateText(raw) { return parsed }
        // Fallback, deliberately only reached when the shapes above all
        // failed: the X-Contact 356 prints "02-07-2018 21:23", and by the
        // time that reaches here it is the bare string "02 07 2018 21 23".
        // Vision's `.byWords` enumeration drops the '-' and the ':', and --
        // because it cannot compute per-word boxes inside that run -- hands
        // all five words the SAME bounding box, so neither the text nor the
        // geometry is left with any hint of where the date ends and the
        // clock begins. Taking the first three date-shaped numbers and
        // ignoring the rest is all the information there is.
        guard let normalized = normalizedDateText(raw) else { return nil }
        return parseDateText(normalized)
    }

    /// First "d(d) sep m(m) sep y(y|yyyy)" run in the text, rewritten with
    /// dots so `parseDateText`'s existing formats can take it. A two-digit
    /// year is read as 20xx -- these reports do not predate 2000.
    private static func normalizedDateText(_ raw: String) -> String? {
        let pattern = #"(\d{1,4})[\s./-]+(\d{1,2})[\s./-]+(\d{2,4})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, options: [], range: range) else { return nil }
        func group(_ index: Int) -> String {
            guard let range = Range(match.range(at: index), in: raw) else { return "" }
            return String(raw[range])
        }
        var year = group(3)
        if year.count == 2 { year = "20" + year }
        guard !group(1).isEmpty, !group(2).isEmpty, year.count == 4 else { return nil }
        return "\(group(1)).\(group(2)).\(year)"
    }

    private static func parseDateText(_ raw: String) -> (Date, Bool)? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if let timeRange = text.range(of: #"\s+\d{1,2}:\d{2}$"#, options: .regularExpression) {
            text.removeSubrange(timeRange)
        }
        while let last = text.last, ".".contains(last) { text.removeLast() }

        let formats = ["dd.MM.yyyy", "yyyy.MM.dd", "dd/MM/yyyy", "yyyy-MM-dd"]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for format in formats {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if let date = formatter.date(from: text) {
                // Ambiguity check (§2.3 / OQ-7): if this is `dd.MM.yyyy` and
                // both segments are <=12, the reading is genuinely ambiguous.
                if format == "dd.MM.yyyy" {
                    let parts = text.split(separator: ".")
                    if parts.count >= 2, let a = Int(parts[0]), let b = Int(parts[1]), a <= 12, b <= 12 {
                        return (date, true)
                    }
                }
                return (date, false)
            }
        }
        return nil
    }

    // MARK: - Notes generation (§2.4)

    private static func buildNotes(rows: [Line], allTokens: [RecognizedToken], excludedKeys: Set<TokenKey>, lineHeight: CGFloat, machine: String?) -> String? {
        var parts: [String] = []
        func append(_ label: String, patterns: [String], suffix: String, plausible: ClosedRange<Double>? = nil, excludeLine: @escaping (String) -> Bool = { _ in false }) {
            guard let token = extractField(rows: rows, allTokens: allTokens, excludedKeys: excludedKeys, lineHeight: lineHeight, patterns: patterns, plausible: plausible, excludeLine: excludeLine),
                  let value = cleanedNumericText(token.text)
            else { return }
            // Unlike the mapped fields -- which surface an out-of-range
            // reading as `.uncertain` for the review form to argue with --
            // a note is free text nobody is prompted to check, so an
            // implausible one is simply left out. On the X-Contact 356
            // the T.B.W. label appears twice, and the second occurrence
            // ("E.C.W./T.B.W. 0.394") is a RATIO: without this guard the
            // notes claimed 0.394 litres of body water.
            if let plausible, let number = Double(value), !plausible.contains(number) { return }
            parts.append("\(label) \(value)\(suffix)")
        }
        // The X-Contact 356 prints "T.B.W." twice, and the second one is
        // the denominator of the E.C.W./T.B.W. RATIO -- a row with no
        // value of its own on the page (the ratio itself, "0.394", has
        // three decimals and so is not even read as a number). Left
        // unexcluded, the below-the-label search walks past it into the
        // next row and reports that row's B.C.M. as body water.
        append("TBW", patterns: [#"total\s*body\s*water"#, dottedCode("TBW")], suffix: "L", plausible: 10...80,
               excludeLine: { RegexSearch.contains(#"\bE[.\s]*C[.\s]*W\b"#, in: $0, caseInsensitive: true) })
        append("Protein", patterns: [#"\bprotein\b"#], suffix: "kg", plausible: 2...30)
        // Singular on the X-Contact 356 ("Mineral"), plural on the
        // InBody120 ("Minerals").
        append("Minerals", patterns: [#"\bminerals?\b"#], suffix: "kg", plausible: 1...10)
        // "Waist-Hip Ratio" on the page, but Vision's `.byWords` enumeration
        // drops the hyphen along with every other punctuation mark, so the
        // recognized text is "Waist Hip Ratio". The old pattern required a
        // literal hyphen and therefore never matched a real report at all --
        // WHR has been silently missing from every scan.
        append("WHR", patterns: [#"waist[\s-]*hip\s*ratio"#, dottedCode("WHR")], suffix: "", plausible: 0.5...1.5)
        append("肥胖度", patterns: [#"obesity\s*degree"#], suffix: "%", plausible: 50...200)
        // Comes back missing on some layouts and that is left alone: the
        // page prints "64/100 Points", and Vision hands back "64" and "100"
        // with byte-identical bounding boxes, in no dependable order. There
        // is no geometric way to prefer one, and 100 is a legal score, so
        // guessing would be a coin flip written into a client's record.
        append("InBody Score", patterns: [#"inbody\s*score"#], suffix: "", plausible: 20...100)
        append("目標體重", patterns: [#"target\s*weight"#], suffix: "kg", plausible: 20...300)
        // The Weight Control panel: how far this client is from the
        // report's own target, split into fat and muscle. For a coach these
        // are the most directly actionable numbers on the page -- "needs to
        // lose 13.2kg of fat and add 2.6kg of muscle" is a training plan,
        // where TBW and Minerals are context.
        //
        // Printed with a sign on paper ("-13.2", "+2.6") that OCR does not
        // survive, so these are recorded as magnitudes, exactly as
        // recognized. No direction is inferred: it would be a guess, and a
        // guess about whether to add or remove 13kg is not one to write into
        // a client's record.
        //
        // Weight Control itself is deliberately NOT extracted. It is the
        // panel's own heading as well as one of its rows, and the two are
        // character-for-character identical once recognized, so an anchor
        // cannot tell them apart -- the heading is found first (rows are
        // scanned top-down), carries no value, and the search then reaches
        // for whatever happens to be nearby. It is also the one number here
        // that is simply 目標體重 − 體重, both of which are already
        // recorded, so nothing is lost by leaving it out.
        append("脂肪控制", patterns: [#"fat\s*control"#], suffix: "kg", plausible: 0.1...60)
        append("肌肉控制", patterns: [#"muscle\s*control"#], suffix: "kg", plausible: 0.1...40)
        // Measurements with no `BodyMetric` field of their own. Written in
        // the dotted spelling the X-Contact 356 uses because that is the
        // report they were read off, but tried on EVERY page: what a photo
        // is willing to give up should not depend on whose logo is at the
        // top of it. The plausible ranges and the guard above are what keep
        // a short code like "A.C." from inventing a waist measurement on a
        // page that has none -- not a brand check.
        append("軟組織瘦體重", patterns: [dottedCode("SLM"), #"soft\s*lean\s*mass"#], suffix: "kg", plausible: 10...100)
        append("除脂體重", patterns: [dottedCode("LBM"), #"lean\s*body\s*mass"#, #"fat[\s-]*free\s*mass"#], suffix: "kg", plausible: 20...150)
        append("身體細胞量", patterns: [bcmDottedPattern, #"body\s*cell\s*mass"#], suffix: "kg", plausible: 10...80)
        append("內臟脂肪面積", patterns: [dottedCode("VFA"), #"visceral\s*fat\s*area"#], suffix: "cm²", plausible: 10...400)
        append("腹圍", patterns: [#"\bA\.\s*C\b"#, #"waist\s*circumference"#, #"abdominal\s*circumference"#], suffix: "cm", plausible: 40...200)
        append("每日總消耗", patterns: [dottedCode("TEE"), #"total\s*energy\s*expenditure"#, #"\bTDEE\b"#], suffix: "kcal", plausible: 800...6000)
        guard !parts.isEmpty else { return nil }
        // The machine's name is provenance, not a category: an
        // unrecognized analyser still gets its values read and still gets a
        // note, just without a name in front of it.
        return (machine.map { "\($0) " } ?? "") + "體測報告掃描導入 · " + parts.joined(separator: " · ")
    }
}

extension RegexSearch {
    static func wholeMatch(_ pattern: String, _ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return false }
        return match.range == range
    }

    static func firstMatchRange(_ pattern: String, in text: String, caseInsensitive: Bool) -> Range<String.Index>? {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        return Range(match.range, in: text)
    }
}
