import Foundation
import SwiftData

/// Which kind of content a block holds -- 2026-09-07 M1 CrossFit extension
/// (工程审阅与CrossFit适配方案.md §5.2). Literal `= .strength.rawValue`
/// default below -> every block created before this field existed picks up
/// `.strength` via SwiftData lightweight migration with no data loss, same
/// precedent as `Exercise.recordingMetric`/`nameZh` (see that model's own
/// comments). `blockType` keeps meaning single/superset/dropset/circuit
/// for ALL section kinds, including `.wod` -- it is deliberately NOT
/// repurposed to also carry the WOD format (AMRAP/For Time/EMOM/interval
/// lives in `WODPrescription.format` instead), per the review's explicit
/// "不要讓它同時代表計分形式".
public enum SectionKind: String, Codable, CaseIterable, Sendable {
    case strength
    case skill
    case wod
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SectionKind(rawValue: raw) ?? .unknown
    }

    public var displayName: String {
        switch self {
        case .strength: return L("力量", "Strength")
        case .skill: return L("技術", "Skill")
        case .wod: return "WOD"
        case .unknown: return L("未知段落", "Unknown Section")
        }
    }
}

/// CONTRACT.md §6. A training block -- the structural fix for supersets:
/// `A + B` is not a single exercise with a compound name, it's one block
/// containing two entries, each referencing its own `Exercise`.
@Model
public final class SessionBlock {
    public var order: Int
    private var blockTypeRaw: String
    public var restSeconds: Int?
    public var restRaw: String?
    public var note: String?
    public var sourceRow: Int
    private var sectionKindRaw: String = SectionKind.strength.rawValue
    /// Versioned WOD/skill payload, persisted as its exact JSON text -- same
    /// "JSON-string column, decode lazily with graceful fallback" pattern
    /// `SetLog`/`TemplateExerciseSlot` already use for `LoadValue`/
    /// `RepTarget`. `nil` for every `.strength` block and any block that
    /// predates this field. See `wodPayload`'s doc comment for the
    /// unsupported-future-version handling.
    private var wodPayloadJSON: String?

    public var session: WorkoutSession?

    @Relationship(deleteRule: .cascade, inverse: \ExerciseEntry.block)
    public var entries: [ExerciseEntry]? = []

    /// Composite identity for upsert: a block has no `id` of its own in
    /// CONTRACT.md, so it's identified by (session.id, order) during import.

    public init(
        order: Int,
        blockType: BlockType,
        restSeconds: Int? = nil,
        restRaw: String? = nil,
        note: String? = nil,
        sourceRow: Int,
        sectionKind: SectionKind = .strength,
        wodPayload: WODPayload? = nil
    ) {
        self.order = order
        self.blockTypeRaw = blockType.rawValue
        self.restSeconds = restSeconds
        self.restRaw = restRaw
        self.note = note
        self.sourceRow = sourceRow
        self.sectionKindRaw = sectionKind.rawValue
        self.wodPayloadJSON = wodPayload.flatMap { JSONColumnCoding.encode($0) }
    }

    public var blockType: BlockType {
        get { BlockType(rawValue: blockTypeRaw) ?? .unknown }
        set { blockTypeRaw = newValue.rawValue }
    }

    public var sectionKind: SectionKind {
        get { SectionKind(rawValue: sectionKindRaw) ?? .strength }
        set { sectionKindRaw = newValue.rawValue }
    }

    /// Raw JSON text of the WOD payload, if any -- available regardless of
    /// whether THIS build can decode it, so export/backup/CSV round-trip
    /// paths never have to silently drop an unsupported future payload.
    public var wodPayloadRawJSON: String? { wodPayloadJSON }

    /// `nil` when there is no WOD data, OR the stored payload's
    /// `schemaVersion` is newer than `WODPayload.currentSchemaVersion` (a
    /// future app version wrote it), OR the JSON is corrupt. Setting to a
    /// non-nil value always writes fresh, current-schema JSON -- this
    /// setter is never the thing that reads an unsupported payload back in
    /// (see `hasUnsupportedWODPayload`), so it can never turn "opaque but
    /// intact" into "silently rewritten lossy".
    public var wodPayload: WODPayload? {
        get {
            guard let json = wodPayloadJSON else { return nil }
            guard let envelope: WODPayloadVersionEnvelope = JSONColumnCoding.decode(json),
                  envelope.schemaVersion <= WODPayload.currentSchemaVersion else { return nil }
            return JSONColumnCoding.decode(json)
        }
        set {
            wodPayloadJSON = newValue.flatMap { JSONColumnCoding.encode($0) }
        }
    }

    /// Writes the exact raw JSON text verbatim, bypassing `wodPayload`'s
    /// typed encode/decode entirely. Used by restore paths (backup import)
    /// that must preserve a payload byte-for-byte -- including one this
    /// build can't decode -- rather than force it through the typed setter,
    /// which always (re-)writes CURRENT-schema JSON.
    public func setWODPayloadRawJSON(_ json: String?) {
        wodPayloadJSON = json
    }

    /// True when a WOD payload is present but this build can't decode it
    /// (future schema version, or corrupt) -- callers (UI, backup/export)
    /// should treat this as "present but unsupported / read-only", never
    /// as either "no WOD" or a crash.
    public var hasUnsupportedWODPayload: Bool {
        wodPayloadJSON != nil && wodPayload == nil
    }

    public var orderedEntries: [ExerciseEntry] {
        (entries ?? []).sorted { $0.order < $1.order }
    }

    public var isMultiEntry: Bool {
        (entries?.count ?? 0) > 1
    }
}
