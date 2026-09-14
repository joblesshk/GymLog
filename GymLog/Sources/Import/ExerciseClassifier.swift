import Foundation

public struct ExerciseClassification {
    public let movementPattern: MovementPattern
    public let equipment: Equipment
    /// CONTRACT-M8.md: name-keyword-only guess (no historical majority-vote
    /// signal is available here -- a brand-new exercise created mid-Excel-
    /// import has no prior logged sets to analyze, unlike `migrate.py`'s
    /// seed-generation classifier). Always paired with `needsReview = true`
    /// by the caller (`ExcelImportFlow`'s auto-create-on-unresolved path),
    /// same as every other auto-classified field for a newly-created
    /// exercise.
    public let recordingMetric: RecordingMetric
    /// Whether the KEYWORD CLASSIFIER ITSELF flags this for review (unknown
    /// pattern, unknown equipment, ambiguous/short fragment, or a debatable
    /// olympic-lift-style word). This is narrower than the seed's final
    /// per-`Exercise` `needsReview` -- that also folds in cross-cutting
    /// flags (merge-candidate detection, §7.5 bare-modifier synthesis, §7.8
    /// unilateral detection) computed later during whole-workbook session
    /// assembly (CONTRACT-M7.md §3.6/§3.7), not by this classifier alone.
    public let needsReview: Bool
    public let reason: String
}

/// CONTRACT-M7.md §3.6: a keyword-based exercise classifier, ported
/// rule-for-rule (same order, same regexes) from `migrate.py`'s
/// `classify_exercise`. Rule ORDER matters -- first match wins, and
/// compound/specific phrases are listed before generic single words so
/// e.g. "leg extension" resolves to `.squat`, not `.push`'s generic
/// "extension" fallback.
public enum ExerciseClassifier {
    private static let patternRules: [(pattern: String, movementPattern: MovementPattern)] = [
        (#"\b(hack squat|leg press|leg extension|split squat|box squat|goblet squat|smith squat|squat)\b"#, .squat),
        (#"\b(lunge|lunges|box step|step to press|step eccentric)\b"#, .squat),
        (#"\b(deadlift|\bdl\b|rdl|hip thrust|hip adduction|hip abduction|hip ad\+abduction|back extension|good morning|hinge|leg curl)\b"#, .hipHinge),
        (#"\brow|\bpull|curl|\blat\b|latpull|chin\s*up|pull\s*up|face\s*pull|pullover|upright row|\bclean\b|\bsnatch\b"#, .pull),
        (#"press|bench|push|dips?\b|fly|\bchest\b|\bohp\b|shoulder press|triceps|skull crusher|pressdown|\bjerk\b|lateral raise|extension"#, .push),
        (#"\bplank\b|crunch|\bcore\b|rotation|twist|hollow hold|wall sit|\bab\b|sit up"#, .core),
        (#"farmer walk|\bcarry\b"#, .carry),
        (#"\browing\b|\bski\b|\bsled\b|slam|wall ball|kb swing|wheel roll|crab walk|burpee|\bjump\b|\brope\b|over shoulder"#, .conditioning),
    ]

    private static let equipmentRules: [(pattern: String, equipment: Equipment)] = [
        (#"\bdb\b|dumbbell"#, .dumbbell),
        (#"\bkb\b|kettlebell"#, .kettlebell),
        (#"\bcable\b"#, .cable),
        (#"\bband\b"#, .band),
        (#"\bsled\b"#, .sled),
        (#"\bball\b"#, .ball),
        (#"\browing\b|\bski\b|\berg\b"#, .ergometer),
        (#"\bsmith\b"#, .machine),
        (#"\bmachine\b|hack squat|leg press|leg extension|leg curl"#, .machine),
        (#"\btrapbar\b|\bbarbell\b|\bezbar\b|landmine|\bt\s*bar\b|\bbb\b"#, .barbell),
        (#"\bplank\b|crunch|sit up|push\s*up|wall sit|\bhold\b|dips?\b|pull\s*up|chin\s*up|lunges|walking lunges|\bbw\b|burpee|crab walk|wheel roll"#, .bodyweight),
    ]

    /// Canonical keys too short/generic to trust the keyword classifier on
    /// -- mostly superset-split fragments that lost their parent exercise's
    /// context. Always flagged.
    private static let ambiguousFragments: Set<String> = [
        "reverse", "close", "hold", "side", "unilateral", "clean", "rest",
        "curl", "press", "pull", "push", "row",
    ]

    /// Olympic-lift-style movements spanning multiple patterns in one rep --
    /// the classifier still picks a bucket (so the entry wheel has *a*
    /// home), but the choice is a judgment call, always surfaced.
    private static let debatablePatternWords: Set<String> = ["clean", "snatch", "jerk"]

    /// CONTRACT-M8.md: name-based `recordingMetric` fallback, mirroring
    /// `migrate.py`'s `RECORDING_METRIC_NAME_RULES` (same rules, same order --
    /// see that file for the historical-data grounding of each rule; this
    /// Swift side has no session history to fall back on, so it's
    /// name-only). Anything not matched defaults to `.reps`, the overwhelming
    /// majority case.
    private static let recordingMetricRules: [(pattern: String, metric: RecordingMetric)] = [
        (#"\bplank\b|wall sit|hollow hold|\bhold\b"#, .time),
        (#"\browing\b|\bski\b"#, .distance),
        (#"farmer walk|\bsled\b"#, .rounds),
    ]

    public static func classify(key: String) -> ExerciseClassification {
        var reasons: [String] = []

        var pattern: MovementPattern = .unknown
        for rule in patternRules {
            if RegexSearch.contains(rule.pattern, in: key, caseInsensitive: true) {
                pattern = rule.movementPattern
                break
            }
        }

        var equipment: Equipment = .other
        for rule in equipmentRules {
            if RegexSearch.contains(rule.pattern, in: key, caseInsensitive: true) {
                equipment = rule.equipment
                break
            }
        }

        var needsReview = false
        if debatablePatternWords.contains(where: { RegexSearch.contains(#"\b\#($0)\b"#, in: key, caseInsensitive: false) }) {
            needsReview = true
            reasons.append("olympic-lift-style movement (\"\(pattern.rawValue)\" chosen as the closest single bucket) — genuinely spans multiple movement patterns, confirm the bucket")
        }
        if pattern == .unknown {
            needsReview = true
            reasons.append("movementPattern could not be inferred from name — fell back to 'unknown'")
        }
        if equipment == .other {
            needsReview = true
            reasons.append("equipment could not be inferred from name — fell back to 'other'")
        }
        if ambiguousFragments.contains(key) || key.count <= 4 {
            needsReview = true
            reasons.append("name is a short/generic fragment (likely from a superset split) — classification is low-confidence")
        }
        if reasons.isEmpty {
            reasons.append("classified via keyword heuristic — confirm before relying on it for programming")
        }

        var recordingMetric: RecordingMetric = .reps
        for rule in recordingMetricRules {
            if RegexSearch.contains(rule.pattern, in: key, caseInsensitive: true) {
                recordingMetric = rule.metric
                break
            }
        }

        return ExerciseClassification(
            movementPattern: pattern,
            equipment: equipment,
            recordingMetric: recordingMetric,
            needsReview: needsReview,
            reason: reasons.joined(separator: "; ")
        )
    }
}
