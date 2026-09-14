import Foundation
import SwiftData

/// Builds an `ExchangePackage` for the coach/student exchange feature (P2,
/// `执行Prompt与实施计划.md` §5) and writes it to a temp file for a share
/// sheet -- same "temp file, hand to `ActivityShareSheet`" shape as
/// `BackupExporter.writeTempFile`/`HistoryCSVExporter`.
///
/// `@MainActor`: `buildPlanPackage` reads `BlockDraft`/`EntryDraft`/
/// `WODBlockDraft` (P1's `EntryDraft.swift`/`WODBlockDraft.swift`), which
/// are themselves `@MainActor @Observable` -- every call site is already
/// UI code on the main actor (`TodayView`/`HistoryListView`), so this
/// matches where the type is actually used rather than introducing any new
/// threading behavior.
@MainActor
public enum ExchangeExporter {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// 今天頁「分享計劃」(§5.2): builds a `.plan` package straight from the
    /// live in-memory draft -- no save required first. Every `actual` is
    /// stripped regardless of what's currently typed into the draft (a
    /// plan carries prescription only). `existingSessionID` should be
    /// `TodayDraftStore.persistedSessionID` when the draft has already been
    /// 暫存 at least once -- reusing that as `recordID` lets re-sharing
    /// after further edits be recognized by the receiver as an update to
    /// the SAME plan rather than a brand-new one; pass `nil` for a draft
    /// that's never been saved (gets a fresh one-off `recordID`).
    public static func buildPlanPackage(
        blocks: [BlockDraft], client: Client, trainingDate: Date, weekNumber: Int,
        plannedDurationMinutes: Int?, existingSessionID: String?
    ) -> ExchangePackage {
        var exerciseSnapshots: [String: ExchangeExerciseSnapshot] = [:]
        let sessionDTO = ExchangeSessionDTO(
            recordID: existingSessionID ?? "se-exchange-\(UUID().uuidString)",
            sourcePlanID: nil,
            trainingLocalDate: localDateString(trainingDate),
            weekNumber: weekNumber,
            plannedDurationMinutes: plannedDurationMinutes,
            blocks: blocks.enumerated().map { index, block in
                blockDTO(block, order: index, includeActual: false, exerciseSnapshots: &exerciseSnapshots)
            }
        )
        return makePackage(payloadKind: .plan, client: client, sessions: [sessionDTO], exerciseSnapshots: exerciseSnapshots)
    }

    /// 歷史頁「分享結果」(§5.2), single or multi-select, one client at a
    /// time. Only completed sessions make sense here (an in-progress
    /// session's "result" isn't final yet) -- callers should already be
    /// filtering to `!session.isInProgress`, same as `copyLastSession`'s
    /// own convention elsewhere in the app; this function doesn't
    /// re-filter so a caller with a deliberate reason to include one can.
    public static func buildResultsPackage(sessions: [WorkoutSession], client: Client) -> ExchangePackage {
        var exerciseSnapshots: [String: ExchangeExerciseSnapshot] = [:]
        let sessionDTOs = sessions.map { session -> ExchangeSessionDTO in
            ExchangeSessionDTO(
                recordID: session.id,
                sourcePlanID: session.sourcePlanID,
                trainingLocalDate: localDateString(session.date),
                weekNumber: session.weekNumber,
                plannedDurationMinutes: session.plannedDurationMinutes,
                blocks: session.orderedBlocks.enumerated().map { index, block in
                    blockDTO(block, order: index, exerciseSnapshots: &exerciseSnapshots)
                }
            )
        }
        return makePackage(payloadKind: .results, client: client, sessions: sessionDTOs, exerciseSnapshots: exerciseSnapshots)
    }

    private static func makePackage(payloadKind: ExchangePayloadKind, client: Client, sessions: [ExchangeSessionDTO], exerciseSnapshots: [String: ExchangeExerciseSnapshot]) -> ExchangePackage {
        let clientRef = ExchangeClientRef(remoteClientID: stableRemoteClientID(for: client), displayName: client.displayName)
        let exercises = Array(exerciseSnapshots.values).sorted { $0.id < $1.id }
        let digest = ExchangeDigest.compute(payloadKind: payloadKind, client: clientRef, sessions: sessions, exercises: exercises)
        return ExchangePackage(
            packageID: UUID().uuidString, createdAt: Date(), originInstallationID: ExchangeInstallationID.current,
            payloadKind: payloadKind, client: clientRef, sessions: sessions, exercises: exercises, contentDigestSHA256: digest
        )
    }

    public static func writeTempFile(_ package: ExchangePackage, suggestedFileName: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(suggestedFileName)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(package).write(to: url, options: .atomic)
        return url
    }

    public static func suggestedFileName(clientName: String, payloadKind: ExchangePayloadKind, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let kindLabel = payloadKind == .plan ? "計劃" : "結果"
        let safeName = clientName.isEmpty ? "學員" : clientName
        return "\(safeName)_\(kindLabel)_\(formatter.string(from: date)).gymlogshare"
    }

    /// Plain-text item handed to `ActivityShareSheet` alongside the file --
    /// `.gymlogshare` is a UTType this app declares itself, so a recipient
    /// who hasn't installed GymLog yet has a device that doesn't recognize
    /// the extension at all (see 工程记录.md 2026-09-12 一節): Files/Mail/
    /// Messages show no useful preview and no "Open in GymLog" option. This
    /// text rides along in the same share (Mail/Messages show it as the
    /// message body; AirDrop's own preview shows it before the receiver
    /// accepts) so the file isn't a dead end with zero context.
    public static func shareReminderText(payloadKind: ExchangePayloadKind, language: AppLanguage) -> String {
        let kindLabel = language.t(
            payloadKind == .plan ? "訓練計劃" : "訓練結果",
            payloadKind == .plan ? "training plan" : "training results"
        )
        return language.t(
            "這是來自 GymLog 的\(kindLabel)分享檔案（.gymlogshare）。請用 GymLog App 打開——如果還沒有安裝，請先到 App Store 搜尋「GymLog」安裝後再打開這個檔案。",
            "This is a GymLog \(kindLabel) share file (.gymlogshare). Open it with the GymLog app — if you don't have it yet, search \u{201C}GymLog\u{201D} on the App Store first, then open this file."
        )
    }

    // MARK: - Client identity

    /// A stable id for THIS client from THIS installation's point of view,
    /// generated once and cached in `UserDefaults` keyed by the client's
    /// own local id -- separate from `Client.id` itself because the
    /// receiving side must never confuse "the sender's local database id"
    /// with any identity of its own; `remoteClientID` only ever means
    /// "same person across packages from this same sender."
    private static func stableRemoteClientID(for client: Client) -> String {
        let key = "exchangeRemoteClientID.\(client.id)"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    // MARK: - Model -> DTO

    private static func blockDTO(_ block: SessionBlock, order: Int, includeActual: Bool = true, exerciseSnapshots: inout [String: ExchangeExerciseSnapshot]) -> ExchangeBlockDTO {
        ExchangeBlockDTO(
            order: order, blockType: block.blockType, restSeconds: block.restSeconds, sectionKind: block.sectionKind,
            entries: block.orderedEntries.enumerated().map { index, entry in entryDTO(entry, order: index, includeActual: includeActual, exerciseSnapshots: &exerciseSnapshots) },
            wodPayloadRawJSON: block.wodPayloadRawJSON
        )
    }

    private static func entryDTO(_ entry: ExerciseEntry, order: Int, includeActual: Bool, exerciseSnapshots: inout [String: ExchangeExerciseSnapshot]) -> ExchangeEntryDTO {
        if let exercise = entry.exercise {
            exerciseSnapshots[exercise.id] = snapshot(exercise)
        }
        let ref = ExchangeExerciseRef(
            exerciseID: entry.exerciseIdRef, canonicalName: entry.exercise?.canonicalName ?? entry.exerciseRaw,
            nameZh: entry.exercise?.nameZh ?? "", recordingMetric: entry.exercise?.recordingMetric ?? .unknown,
            equipment: entry.exercise?.equipment ?? .other
        )
        return ExchangeEntryDTO(
            order: order, exerciseRef: ref, plannedSets: entry.plannedSets,
            sets: entry.orderedSets.map { set in
                ExchangeSetDTO(setIndex: set.setIndex, load: set.load, target: set.target, actual: includeActual ? set.actual : nil)
            }
        )
    }

    /// Draft-side block conversion, for `buildPlanPackage` -- `BlockDraft`/
    /// `EntryDraft` are `GymLogKit` types with no `ModelContext` involved
    /// (the draft is purely in-memory), so this is a separate small mapper
    /// rather than reusing the `SessionBlock`-based one above.
    private static func blockDTO(_ block: BlockDraft, order: Int, includeActual: Bool, exerciseSnapshots: inout [String: ExchangeExerciseSnapshot]) -> ExchangeBlockDTO {
        let wodJSON: String?
        if block.sectionKind == .wod, let wodDraft = block.wodDraft {
            wodJSON = wodPayloadRawJSON(from: wodDraft, includeResult: includeActual)
        } else {
            wodJSON = nil
        }
        return ExchangeBlockDTO(
            order: order, blockType: block.blockType, restSeconds: block.restSeconds, sectionKind: block.sectionKind,
            entries: block.entries.enumerated().map { index, entry in entryDTO(entry, order: index, includeActual: includeActual, exerciseSnapshots: &exerciseSnapshots) },
            wodPayloadRawJSON: wodJSON
        )
    }

    private static func entryDTO(_ entry: EntryDraft, order: Int, includeActual: Bool, exerciseSnapshots: inout [String: ExchangeExerciseSnapshot]) -> ExchangeEntryDTO {
        exerciseSnapshots[entry.exercise.id] = snapshot(entry.exercise)
        let ref = ExchangeExerciseRef(
            exerciseID: entry.exercise.id, canonicalName: entry.exercise.canonicalName, nameZh: entry.exercise.nameZh,
            recordingMetric: entry.exercise.recordingMetric, equipment: entry.exercise.equipment
        )
        let resolved = entry.resolvedSets()
        return ExchangeEntryDTO(
            order: order, exerciseRef: ref, plannedSets: entry.plannedSets,
            sets: resolved.enumerated().map { index, set in
                ExchangeSetDTO(setIndex: index, load: set.load, target: set.target, actual: includeActual ? set.actual : nil)
            }
        )
    }

    private static func snapshot(_ exercise: Exercise) -> ExchangeExerciseSnapshot {
        ExchangeExerciseSnapshot(
            id: exercise.id, canonicalName: exercise.canonicalName, nameZh: exercise.nameZh, aliases: exercise.aliases,
            movementPattern: exercise.movementPattern, equipment: exercise.equipment, recordingMetric: exercise.recordingMetric,
            discipline: exercise.discipline, loadDirection: exercise.loadDirection, isUnilateral: exercise.isUnilateral
        )
    }

    private static func wodPayloadRawJSON(from wodDraft: WODBlockDraft, includeResult: Bool) -> String? {
        let (prescriptionID, revision) = wodDraft.resolveIdentity()
        let prescription = wodDraft.resolvedPrescription(prescriptionID: prescriptionID, revision: revision)
        let result = includeResult ? wodDraft.resolvedResult() : WODResult()
        let throwaway = SessionBlock(order: 0, blockType: .single, sourceRow: 0, sectionKind: .wod, wodPayload: WODPayload(prescription: prescription, result: result))
        return throwaway.wodPayloadRawJSON
    }

    /// Local calendar day, `yyyy-MM-dd`, in the device's OWN current time
    /// zone -- deliberately NOT UTC (§5.3: "日期明確存訓練當地日期...不能
    /// 按接收者時區移動訓練日"). `createdAt` on the package header is the
    /// one field that's UTC; this one is a plain local-date string with no
    /// time-zone conversion applied on import.
    private static func localDateString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 1970, components.month ?? 1, components.day ?? 1)
    }
}
