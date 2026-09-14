import Foundation
import CryptoKit

/// CONTRACT-M7.md §3.6: exercise-name normalization and stable-ID derivation,
/// ported from `migrate.py`'s `normalize_key` / `stable_exercise_id`. Any
/// exercise name that normalizes to the same key as one already in the
/// seeded library resolves to the SAME `Exercise.id` here as it did during
/// the original migration -- no fuzzy matching needed for that case, since
/// the id is a pure function of the normalized name.
public enum ExerciseNameCanonicalizer {
    /// Collapse all whitespace runs to a single space, trim, lowercase.
    public static func normalizeKey(_ rawName: String) -> String {
        let collapsed = rawName.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// `"ex-" + first 8 hex chars of SHA-1(key.utf8)`. Deliberately SHA-1
    /// (not a stronger hash) to byte-for-byte match `migrate.py`'s
    /// `hashlib.sha1(key.encode("utf-8")).hexdigest()[:8]` -- this is an
    /// identity key, not a security boundary.
    public static func stableExerciseID(_ key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "ex-" + hex.prefix(8)
    }

    /// `w/assist` or `assisted` anywhere in the (already-normalized) key.
    /// CONTRACT.md §7.3: exercises matching this MUST get
    /// `loadDirection = .lowerIsStronger` -- missing this flips every
    /// pull-up/dip trend chart's direction.
    public static func isAssistedExercise(key: String) -> Bool {
        RegexSearch.contains(#"w/\s*assist|assisted"#, in: key, caseInsensitive: true)
    }

    /// §7.5 (v2): a superset's non-first component is sometimes a bare
    /// variation word for the FIRST component ("Latpull wide + reverse" is
    /// one exercise done in reverse grip, not two exercises). Fires only
    /// when exactly one non-shared word remains and it's in the curated
    /// adjective set -- never guesses beyond that.
    private static let modifierAdjectives: Set<String> = [
        "reverse", "unilateral", "side", "close", "narrow", "wide",
        "eccentric", "neutral", "hold", "push", "pull", "inout",
    ]

    /// Returns the cleaned modifier word (e.g. `"narrow"`) if
    /// `componentName` is a bare variation of `baseName`, else `nil`.
    public static func detectBareModifier(baseName: String, componentName: String) -> String? {
        let baseWords = Set(words(in: baseName).map { $0.lowercased() })
        let componentWords = words(in: componentName)
        let remaining = componentWords.filter { !baseWords.contains($0.lowercased()) }
        guard remaining.count == 1, modifierAdjectives.contains(remaining[0].lowercased()) else {
            return nil
        }
        return remaining[0].lowercased()
    }

    private static func words(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for char in text {
            if char.isLetter {
                current.append(char)
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// Shared "does this pattern match anywhere" helper (Python `re.search`
/// semantics -- NOT anchored, unlike `ExcelValueParsers`'s `wholeMatch`).
/// Used by both this file and `ExerciseClassifier`.
enum RegexSearch {
    static func contains(_ pattern: String, in text: String, caseInsensitive: Bool) -> Bool {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
