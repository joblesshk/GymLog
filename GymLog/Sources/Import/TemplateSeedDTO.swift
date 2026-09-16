import Foundation

// MARK: - Wire-format DTOs for `Resources/template_seed.json`.
//
// CONTRACT-M5.md §4.2. Mirrors the separation-of-concerns rationale at the
// top of SeedDTO.swift: these are decode-only shapes for the coordinator's
// hand-written template data, kept apart from the `SessionTemplate` /
// `TemplateBlock` / `TemplateExerciseSlot` `@Model` types (CONTRACT-M4.md
// §3) that `SeedImporter.importTemplateSeed` builds from them.
//
// The one deliberate wire-format deviation from CONTRACT-M4.md §3's model
// shape: `TemplateSlotDTO.exerciseName` (not `exerciseId`). The coordinator
// hand-wrote this JSON from real historical sessions and can't reliably
// reproduce the migration script's id-hashing algorithm, so slots reference
// exercises by their exact `Exercise.canonicalName` instead; resolution to
// `TemplateExerciseSlot.exerciseID` happens at import time in
// `SeedImporter.importTemplateSeed`, against already-imported `Exercise` rows.
//
// `TemplateBlockDTO.blockType` and `TemplateSlotDTO.defaultRepTarget` reuse
// the existing `BlockType` (ClassificationEnums.swift) and `RepTarget`
// (RepTarget.swift) `Decodable` implementations directly -- both already
// decode exactly the CONTRACT.md §7.5 / §7.7-7.8 wire formats with graceful
// unknown-value fallback, so there is no reason to re-derive that logic here.

struct TemplateSeedFile: Decodable {
    let schemaVersion: Int
    let source: String
    let templates: [SessionTemplateDTO]
}

struct SessionTemplateDTO: Decodable {
    let id: String
    let name: String
    let templateNote: String?
    let order: Int
    let blocks: [TemplateBlockDTO]
}

struct TemplateBlockDTO: Decodable {
    let order: Int
    let blockType: BlockType
    let restSeconds: Int
    /// `nil` (absent from the JSON) means `.strength`, same default as
    /// `TemplateBlock.init`'s `sectionKind` parameter -- only WOD template
    /// blocks (2026-09-17「WOD 模板」) need to write this explicitly.
    let sectionKind: SectionKind?
    /// A WOD template block carries its prescription here instead of
    /// `slots` (which stays `[]` for a WOD block in the JSON -- WOD
    /// movements aren't `TemplateExerciseSlot`s). `WODPrescription` is
    /// already a plain `Codable` struct with no custom `CodingKeys` (see
    /// `Sources/Models/WOD/WODPrescription.swift`), so this decodes its
    /// wire format directly with no separate DTO needed.
    let wodPrescription: WODPrescription?
    let slots: [TemplateSlotDTO]
}

struct TemplateSlotDTO: Decodable {
    let order: Int
    /// NOT `exerciseId` -- see file-level note above.
    let exerciseName: String
    let defaultSets: Int
    let defaultRepTarget: RepTarget
}
