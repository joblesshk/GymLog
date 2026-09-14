import Foundation
import SwiftData

/// Builds a full-app `BackupFile` from live SwiftData models and writes it
/// to a JSON file for a share sheet -- the export half of "完整备份与恢复"
/// (2026-09-06 审查报告"适合当前范围的功能"第一批).
public enum BackupExporter {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static func makeBackup(from context: ModelContext) throws -> BackupFile {
        let exercises = try context.fetch(FetchDescriptor<Exercise>()).map(exerciseDTO)
        let clients = try context.fetch(FetchDescriptor<Client>()).map(clientDTO)
        let templates = try context.fetch(FetchDescriptor<SessionTemplate>()).map(templateDTO)
        let counts = BackupCounts.compute(exercises: exercises, clients: clients, templates: templates)
        return BackupFile(generatedAt: Date(), counts: counts, exercises: exercises, clients: clients, templates: templates)
    }

    public static func data(from context: ModelContext) throws -> Data {
        try encoder.encode(makeBackup(from: context))
    }

    /// Writes the export to a fresh temp file and returns its URL, for
    /// handing straight to a share sheet -- same pattern as
    /// `HistoryCSVExporter.writeTempFile`. Caller owns cleanup (the OS
    /// periodically reclaims `temporaryDirectory` anyway).
    public static func writeTempFile(from context: ModelContext) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(suggestedFileName())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data(from: context).write(to: url, options: .atomic)
        return url
    }

    public static func suggestedFileName(exportedAt date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return "GymLog備份_\(formatter.string(from: date)).json"
    }

    // MARK: - Model -> DTO

    private static func exerciseDTO(_ exercise: Exercise) -> ExerciseBackupDTO {
        ExerciseBackupDTO(
            id: exercise.id, canonicalName: exercise.canonicalName, aliases: exercise.aliases,
            movementPattern: exercise.movementPattern, equipment: exercise.equipment, loadDirection: exercise.loadDirection,
            isUnilateral: exercise.isUnilateral, occurrenceCount: exercise.occurrenceCount, needsReview: exercise.needsReview,
            reviewReason: exercise.reviewReason, recordingMetric: exercise.recordingMetric,
            discipline: exercise.discipline, nameZh: exercise.nameZh, notes: exercise.notes
        )
    }

    private static func clientDTO(_ client: Client) -> ClientBackupDTO {
        ClientBackupDTO(
            id: client.id, name: client.name, phone: client.phone, gender: client.gender, age: client.age,
            heightCm: client.heightCm, startWeightKg: client.startWeightKg, goal: client.goal, frequency: client.frequency,
            bmr: client.bmr, tdee: client.tdee, habits: client.habits, medicalHistory: client.medicalHistory,
            assessments: (client.assessments ?? []).map(assessmentDTO),
            bodyMetrics: (client.bodyMetrics ?? []).map(bodyMetricDTO),
            sessions: (client.sessions ?? []).map(sessionDTO)
        )
    }

    private static func assessmentDTO(_ assessment: Assessment) -> AssessmentBackupDTO {
        AssessmentBackupDTO(id: assessment.id, pattern: assessment.pattern, date: assessment.date, level: assessment.level, notes: assessment.notes)
    }

    private static func bodyMetricDTO(_ metric: BodyMetric) -> BodyMetricBackupDTO {
        BodyMetricBackupDTO(
            id: metric.id, date: metric.date, weightKg: metric.weightKg, bodyFatPercent: metric.bodyFatPercent,
            skeletalMuscleKg: metric.skeletalMuscleKg, bmi: metric.bmi, visceralFatLevel: metric.visceralFatLevel,
            bmr: metric.bmr, tdee: metric.tdee, bodyFatMassKg: metric.bodyFatMassKg, notes: metric.notes
        )
    }

    private static func sessionDTO(_ session: WorkoutSession) -> WorkoutSessionBackupDTO {
        WorkoutSessionBackupDTO(
            id: session.id, date: session.date, dateOrigin: session.dateOrigin, dateRaw: session.dateRaw,
            weekNumber: session.weekNumber, sourceSheet: session.sourceSheet, sourceRow: session.sourceRow,
            warmup: session.warmup, warmupNote: session.warmupNote, cooldown: session.cooldown, cooldownNote: session.cooldownNote,
            needsReview: session.needsReview, reviewReason: session.reviewReason, plannedDurationMinutes: session.plannedDurationMinutes,
            importSourceFile: session.importSourceFile, importedAt: session.importedAt, sourceDigest: session.sourceDigest,
            importDigest: session.importDigest, isInProgress: session.isInProgress,
            blocks: session.orderedBlocks.map(blockDTO), insightJSON: session.insightJSON
        )
    }

    private static func blockDTO(_ block: SessionBlock) -> SessionBlockBackupDTO {
        SessionBlockBackupDTO(
            order: block.order, blockType: block.blockType, restSeconds: block.restSeconds, restRaw: block.restRaw,
            note: block.note, sourceRow: block.sourceRow, entries: block.orderedEntries.map(entryDTO),
            sectionKind: block.sectionKind, wodPayloadRawJSON: block.wodPayloadRawJSON
        )
    }

    private static func entryDTO(_ entry: ExerciseEntry) -> ExerciseEntryBackupDTO {
        ExerciseEntryBackupDTO(
            order: entry.order, exerciseIdRef: entry.exerciseIdRef, exerciseRaw: entry.exerciseRaw,
            plannedSets: entry.plannedSets, sets: entry.orderedSets.map(setDTO)
        )
    }

    private static func setDTO(_ set: SetLog) -> SetLogBackupDTO {
        SetLogBackupDTO(setIndex: set.setIndex, load: set.load, target: set.target, actual: set.actual, isInferred: set.isInferred)
    }

    private static func templateDTO(_ template: SessionTemplate) -> SessionTemplateBackupDTO {
        SessionTemplateBackupDTO(
            id: template.id, name: template.name, templateNote: template.templateNote, order: template.order,
            blocks: template.orderedBlocks.map(templateBlockDTO)
        )
    }

    private static func templateBlockDTO(_ block: TemplateBlock) -> TemplateBlockBackupDTO {
        TemplateBlockBackupDTO(
            id: block.id, order: block.order, blockType: block.blockType, restSeconds: block.restSeconds,
            slots: block.orderedSlots.map(templateSlotDTO),
            sectionKind: block.sectionKind, wodPrescriptionRawJSON: block.wodPrescriptionRawJSON
        )
    }

    private static func templateSlotDTO(_ slot: TemplateExerciseSlot) -> TemplateExerciseSlotBackupDTO {
        TemplateExerciseSlotBackupDTO(id: slot.id, order: slot.order, exerciseID: slot.exerciseID, defaultSets: slot.defaultSets, defaultRepTarget: slot.defaultRepTarget)
    }
}
