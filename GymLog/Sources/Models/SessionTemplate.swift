import Foundation
import SwiftData

/// CONTRACT-M4.md §3. A coach-authored, globally-shared session template --
/// "which exercises make up one ~1-hour session" -- distinct from
/// `WorkoutSession` in one deliberate way: templates carry no `LoadValue`.
/// Weight is still resolved per-client via M2's existing last-value prefill
/// when a template seeds a new session; a template only plans exercises,
/// set counts, and rep targets.
@Model
public final class SessionTemplate {
    @Attribute(.unique) public var id: String
    public var name: String
    public var templateNote: String?
    public var order: Int

    @Relationship(deleteRule: .cascade, inverse: \TemplateBlock.template)
    public var blocks: [TemplateBlock]? = []

    public init(id: String, name: String, templateNote: String? = nil, order: Int) {
        self.id = id
        self.name = name
        self.templateNote = templateNote
        self.order = order
    }

    public var orderedBlocks: [TemplateBlock] {
        (blocks ?? []).sorted { $0.order < $1.order }
    }

    /// CONTRACT-M4.md §3's coarse duration heuristic: flat warmup/cooldown
    /// plus each block's (sets * assumed-40s-execution + sets * rest),
    /// rounded to the nearest 5 minutes. A rough fit-check, not a stopwatch.
    public var estimatedMinutes: Int {
        let warmupCooldown = 8.0
        let blockSeconds = orderedBlocks.reduce(0.0) { total, block in
            let setsInBlock = block.orderedSlots.reduce(0) { $0 + $1.defaultSets }
            return total + Double(setsInBlock) * (40.0 + Double(block.restSeconds))
        }
        let raw = warmupCooldown + blockSeconds / 60.0
        return max(5, Int((raw / 5.0).rounded()) * 5)
    }
}

/// One block within a template -- mirrors `SessionBlock`'s shape (single /
/// superset / dropset / circuit), minus the fields that only make sense for
/// an actual recorded session (`note`, `sourceRow`).
@Model
public final class TemplateBlock {
    @Attribute(.unique) public var id: String
    public var order: Int
    private var blockTypeRaw: String
    public var restSeconds: Int
    private var sectionKindRaw: String = SectionKind.strength.rawValue
    /// A WOD template block stores only the PRESCRIPTION -- never a result
    /// (工程审阅 §5.2: "WOD模板只保存處方，不含已完成成績"). Same versioned-
    /// JSON-string, decode-with-graceful-fallback convention as
    /// `SessionBlock.wodPayload`; see that property's doc comment for the
    /// unsupported-future-version handling this mirrors.
    private var wodPrescriptionJSON: String?

    public var template: SessionTemplate?

    @Relationship(deleteRule: .cascade, inverse: \TemplateExerciseSlot.block)
    public var slots: [TemplateExerciseSlot]? = []

    public init(
        id: String, order: Int, blockType: BlockType, restSeconds: Int,
        sectionKind: SectionKind = .strength, wodPrescription: WODPrescription? = nil
    ) {
        self.id = id
        self.order = order
        self.blockTypeRaw = blockType.rawValue
        self.restSeconds = restSeconds
        self.sectionKindRaw = sectionKind.rawValue
        self.wodPrescriptionJSON = wodPrescription.flatMap { JSONColumnCoding.encode($0) }
    }

    public var blockType: BlockType {
        get { BlockType(rawValue: blockTypeRaw) ?? .unknown }
        set { blockTypeRaw = newValue.rawValue }
    }

    public var sectionKind: SectionKind {
        get { SectionKind(rawValue: sectionKindRaw) ?? .strength }
        set { sectionKindRaw = newValue.rawValue }
    }

    public var wodPrescriptionRawJSON: String? { wodPrescriptionJSON }

    /// `nil` when there's no WOD prescription, the stored `schemaVersion` is
    /// newer than this build supports, or the JSON is corrupt -- same rule
    /// as `SessionBlock.wodPayload`.
    public var wodPrescription: WODPrescription? {
        get {
            guard let json = wodPrescriptionJSON else { return nil }
            guard let envelope: WODPayloadVersionEnvelope = JSONColumnCoding.decode(json),
                  envelope.schemaVersion <= WODPrescription.currentSchemaVersion else { return nil }
            return JSONColumnCoding.decode(json)
        }
        set {
            wodPrescriptionJSON = newValue.flatMap { JSONColumnCoding.encode($0) }
        }
    }

    public func setWODPrescriptionRawJSON(_ json: String?) {
        wodPrescriptionJSON = json
    }

    public var hasUnsupportedWODPrescription: Bool {
        wodPrescriptionJSON != nil && wodPrescription == nil
    }

    public var orderedSlots: [TemplateExerciseSlot] {
        (slots ?? []).sorted { $0.order < $1.order }
    }
}

/// One exercise slot within a template block. `exerciseID` references
/// `Exercise.id` by string, the same loose-reference convention
/// `ExerciseEntry` already uses (no SwiftData foreign-key relationship to
/// `Exercise`, consistent with how the frozen data layer resolves it).
@Model
public final class TemplateExerciseSlot {
    @Attribute(.unique) public var id: String
    public var order: Int
    public var exerciseID: String
    public var defaultSets: Int

    private var defaultRepTargetJSON: String

    public var block: TemplateBlock?

    public init(id: String, order: Int, exerciseID: String, defaultSets: Int, defaultRepTarget: RepTarget) {
        self.id = id
        self.order = order
        self.exerciseID = exerciseID
        self.defaultSets = defaultSets
        self.defaultRepTargetJSON = JSONColumnCoding.encode(defaultRepTarget) ?? #"{"kind":"unknown","raw":""}"#
    }

    /// Same encode/decode-with-graceful-fallback pattern as
    /// `SetLog.target`/`SetLog.actual` (see that file's persistence note),
    /// sharing the actual (de)serialization via `JSONColumnCoding` --
    /// each `@Model` still owns its own JSON string column and computed
    /// property (SwiftData gives no mixin for stored properties), but the
    /// encode/decode logic itself has no reason to be copy-pasted.
    public var defaultRepTarget: RepTarget {
        get { JSONColumnCoding.decode(defaultRepTargetJSON) ?? .unknown(raw: "") }
        set { defaultRepTargetJSON = JSONColumnCoding.encode(newValue) ?? #"{"kind":"unknown","raw":""}"# }
    }
}
