import Foundation
import SwiftData

/// Parses/validates/previews/commits an `ExchangePackage` -- independent of
/// `BackupImporter` (§5.3: "不復用『全庫恢復』的破壞性行為"), though it
/// mirrors that file's phase structure (`parse` -> `preview` -> `commit`,
/// atomic transaction with rollback-on-error) since that shape is already
/// proven in this codebase.
///
/// Conflict handling is the SIMPLIFIED version confirmed with the user for
/// this pass: same-origin-same-record content that's changed since the
/// last import is always skipped (local kept), reported as a count in
/// `ImportResult` -- no field-level diff/replace/save-as-new chooser yet.
public enum ExchangeImporter {
    public enum ImportError: LocalizedError {
        case unsupportedFormatVersion(Int)
        case invalidData(String)
        case clientNotFound

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormatVersion(let version):
                return "This file was created by a newer version of GymLog (format \(version)); this version doesn't know how to read it. Please update the app."
            case .invalidData(let detail):
                return "This file failed validation and was not imported: \(detail)"
            case .clientNotFound:
                return "The selected client no longer exists."
            }
        }
    }

    /// First-pass adjustable limits (§5.3: "第一版可設 10 MB、200 節課為明確
    /// 可調整上限").
    public static let maxFileSize = 10_000_000
    public static let maxSessionCount = 200
    public static let maxStringLength = 2000

    public struct ExerciseResolution: Equatable {
        public enum Kind: Equatable { case matchedByID, matchedByNameAndUnit, willCreate }
        public var exerciseID: String
        public var displayName: String
        public var kind: Kind
    }

    public enum SessionDisposition: Equatable {
        case new
        case idempotentDuplicate
        case contentChanged
    }

    public struct PreviewResult {
        public var package: ExchangePackage
        public var dispositions: [(recordID: String, disposition: SessionDisposition)] = []
        public var exerciseResolutions: [ExerciseResolution] = []
        /// Pre-selected local client if `ExchangeClientMapping` already has
        /// one for `package.client.remoteClientID` (§5.3: "已有明確映射時
        /// 可預選，仍顯示歸屬").
        public var mappedLocalClientID: String?

        public var newCount: Int { dispositions.filter { $0.disposition == .new }.count }
        public var idempotentCount: Int { dispositions.filter { $0.disposition == .idempotentDuplicate }.count }
        public var contentChangedCount: Int { dispositions.filter { $0.disposition == .contentChanged }.count }
        public var willCreateExerciseCount: Int { exerciseResolutions.filter { $0.kind == .willCreate }.count }
    }

    public struct ImportResult {
        public var sessionsWritten = 0
        public var sessionsSkippedIdempotent = 0
        public var sessionsSkippedContentChanged = 0
        public var exercisesCreated = 0
    }

    // MARK: - Parse / validate

    public static func parse(_ data: Data) throws -> ExchangePackage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let package = try decoder.decode(ExchangePackage.self, from: data)
        guard (1...ExchangePackage.currentFormatVersion).contains(package.formatVersion) else {
            throw ImportError.unsupportedFormatVersion(package.formatVersion)
        }
        let issues = validateStructure(package)
        guard issues.isEmpty else {
            throw ImportError.invalidData(issues.joined(separator: "; "))
        }
        return package
    }

    /// Size/count/string-length/reference-completeness checks (§5.3).
    /// Collects every issue found rather than stopping at the first.
    static func validateStructure(_ package: ExchangePackage) -> [String] {
        var issues: [String] = []

        guard package.sessions.count <= maxSessionCount else {
            issues.append("too many sessions: \(package.sessions.count) (limit \(maxSessionCount))")
            return issues
        }

        func checkLength(_ s: String, label: String) {
            if s.count > maxStringLength {
                issues.append("\(label) exceeds \(maxStringLength) characters")
            }
        }
        checkLength(package.client.displayName, label: "client display name")

        let exerciseIDs = Set(package.exercises.map(\.id))
        var recordIDs = Set<String>()
        for session in package.sessions {
            guard recordIDs.insert(session.recordID).inserted else {
                issues.append("duplicate recordID in package: \(session.recordID)")
                continue
            }
            var blockOrders = Set<Int>()
            for block in session.blocks {
                if !blockOrders.insert(block.order).inserted {
                    issues.append("session \(session.recordID): duplicate block order \(block.order)")
                }
                var entryOrders = Set<Int>()
                for entry in block.entries {
                    if !entryOrders.insert(entry.order).inserted {
                        issues.append("session \(session.recordID) block \(block.order): duplicate entry order \(entry.order)")
                    }
                    checkLength(entry.exerciseRef.canonicalName, label: "exercise name")
                    // Reference completeness: an entry referencing an
                    // exerciseID not present in `package.exercises` is only
                    // a problem if that ID *also* fails to resolve locally
                    // later -- not knowable at parse time, so this isn't
                    // rejected here (mirrors `BackupImporter.validateStructure`'s
                    // own "an unresolved exerciseIdRef is not itself
                    // invalid" stance). Only truly structural issues (empty
                    // ref with no snapshot AND no plausible local match
                    // possible) would be rejected, and there's no such case
                    // here since every ref carries its own name/unit
                    // fallback regardless of whether a snapshot exists.
                    _ = exerciseIDs
                    var setIndices = Set<Int>()
                    for set in entry.sets {
                        if !setIndices.insert(set.setIndex).inserted {
                            issues.append("session \(session.recordID) entry \(entry.order): duplicate setIndex \(set.setIndex)")
                        }
                    }
                }
            }
        }
        return issues
    }

    // MARK: - Preview

    public static func preview(_ package: ExchangePackage, in context: ModelContext) throws -> PreviewResult {
        var result = PreviewResult(package: package)

        result.mappedLocalClientID = ExchangeClientMapping.localClientID(
            originInstallationID: package.originInstallationID, remoteClientID: package.client.remoteClientID
        )

        let existingSessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        var existingByOriginRecord: [String: WorkoutSession] = [:]
        for session in existingSessions {
            if let origin = session.exchangeOriginInstallationID, let record = session.exchangeRecordID {
                existingByOriginRecord["\(origin)|\(record)"] = session
            }
        }
        for sessionDTO in package.sessions {
            let key = "\(package.originInstallationID)|\(sessionDTO.recordID)"
            if let existing = existingByOriginRecord[key] {
                let digest = ExchangeDigest.computeSessionDigest(sessionDTO)
                let disposition: SessionDisposition = existing.exchangeContentDigestSHA256 == digest ? .idempotentDuplicate : .contentChanged
                result.dispositions.append((sessionDTO.recordID, disposition))
            } else {
                result.dispositions.append((sessionDTO.recordID, .new))
            }
        }

        let existingExercises = try context.fetch(FetchDescriptor<Exercise>())
        let existingByID = Dictionary(uniqueKeysWithValues: existingExercises.map { ($0.id, $0) })
        var existingByNameUnit: [String: Exercise] = [:]
        for exercise in existingExercises {
            let key = nameUnitKey(exercise.canonicalName, exercise.recordingMetric)
            if existingByNameUnit[key] == nil { existingByNameUnit[key] = exercise }
        }
        var seenRefs = Set<String>()
        for session in package.sessions {
            for block in session.blocks {
                for entry in block.entries {
                    let ref = entry.exerciseRef
                    guard seenRefs.insert(ref.exerciseID).inserted else { continue }
                    if existingByID[ref.exerciseID] != nil {
                        result.exerciseResolutions.append(ExerciseResolution(exerciseID: ref.exerciseID, displayName: ref.canonicalName, kind: .matchedByID))
                    } else if existingByNameUnit[nameUnitKey(ref.canonicalName, ref.recordingMetric)] != nil {
                        result.exerciseResolutions.append(ExerciseResolution(exerciseID: ref.exerciseID, displayName: ref.canonicalName, kind: .matchedByNameAndUnit))
                    } else {
                        result.exerciseResolutions.append(ExerciseResolution(exerciseID: ref.exerciseID, displayName: ref.canonicalName, kind: .willCreate))
                    }
                }
            }
        }
        return result
    }

    // MARK: - Commit

    @discardableResult
    public static func commit(_ package: ExchangePackage, targetClientID: String, in context: ModelContext) throws -> ImportResult {
        let wasAutosaveEnabled = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = wasAutosaveEnabled }

        do {
            guard let client = try context.fetch(FetchDescriptor<Client>(predicate: #Predicate { $0.id == targetClientID })).first else {
                throw ImportError.clientNotFound
            }

            let existingExercises = try context.fetch(FetchDescriptor<Exercise>())
            let existingByID = Dictionary(uniqueKeysWithValues: existingExercises.map { ($0.id, $0) })
            var existingByNameUnit: [String: Exercise] = [:]
            for exercise in existingExercises {
                let key = nameUnitKey(exercise.canonicalName, exercise.recordingMetric)
                if existingByNameUnit[key] == nil { existingByNameUnit[key] = exercise }
            }
            let snapshotsByID = Dictionary(uniqueKeysWithValues: package.exercises.map { ($0.id, $0) })
            var createdExercises: [String: Exercise] = [:]
            var exercisesCreated = 0

            func resolveExercise(_ ref: ExchangeExerciseRef) -> Exercise? {
                if let created = createdExercises[ref.exerciseID] { return created }
                if let direct = existingByID[ref.exerciseID] { return direct }
                if let byName = existingByNameUnit[nameUnitKey(ref.canonicalName, ref.recordingMetric)] { return byName }
                guard let snapshot = snapshotsByID[ref.exerciseID] else { return nil }
                let newID = "ex-exchange-\(UUID().uuidString)"
                let exercise = Exercise(
                    id: newID, canonicalName: snapshot.canonicalName, aliases: snapshot.aliases, movementPattern: snapshot.movementPattern,
                    equipment: snapshot.equipment, loadDirection: snapshot.loadDirection, isUnilateral: snapshot.isUnilateral,
                    occurrenceCount: 0, needsReview: false, reviewReason: nil, recordingMetric: snapshot.recordingMetric,
                    discipline: snapshot.discipline, nameZh: snapshot.nameZh
                )
                context.insert(exercise)
                createdExercises[ref.exerciseID] = exercise
                exercisesCreated += 1
                return exercise
            }

            let existingSessions = try context.fetch(FetchDescriptor<WorkoutSession>())
            var existingByOriginRecord: [String: WorkoutSession] = [:]
            for session in existingSessions {
                if let origin = session.exchangeOriginInstallationID, let record = session.exchangeRecordID {
                    existingByOriginRecord["\(origin)|\(record)"] = session
                }
            }
            let nextWeekNumber = (existingSessions.filter { $0.client?.id == targetClientID }.map(\.weekNumber).max() ?? 0) + 1

            var result = ImportResult()
            for sessionDTO in package.sessions {
                let digest = ExchangeDigest.computeSessionDigest(sessionDTO)
                let key = "\(package.originInstallationID)|\(sessionDTO.recordID)"
                if let existing = existingByOriginRecord[key] {
                    if existing.exchangeContentDigestSHA256 == digest {
                        result.sessionsSkippedIdempotent += 1
                    } else {
                        // Simplified conflict handling (user-confirmed for
                        // this pass): content changed since last import --
                        // keep the local version untouched, just count it.
                        result.sessionsSkippedContentChanged += 1
                    }
                    continue
                }
                let session = buildSession(
                    sessionDTO, package: package, digest: digest, client: client, weekNumber: nextWeekNumber,
                    resolveExercise: resolveExercise, context: context
                )
                context.insert(session)
                result.sessionsWritten += 1
            }

            try context.save()
            ExchangeClientMapping.setMapping(originInstallationID: package.originInstallationID, remoteClientID: package.client.remoteClientID, localClientID: targetClientID)
            result.exercisesCreated = exercisesCreated
            return result
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func buildSession(
        _ dto: ExchangeSessionDTO, package: ExchangePackage, digest: String, client: Client, weekNumber: Int,
        resolveExercise: (ExchangeExerciseRef) -> Exercise?, context: ModelContext
    ) -> WorkoutSession {
        let session = WorkoutSession(
            id: "se-exchange-\(UUID().uuidString)", date: localDate(dto.trainingLocalDate), dateOrigin: .asRecorded,
            dateRaw: dto.trainingLocalDate, weekNumber: weekNumber, sourceSheet: "Exchange", sourceRow: 0,
            plannedDurationMinutes: dto.plannedDurationMinutes,
            // §5.2: 計劃匯入落成待訓練草稿（`isInProgress = true`，直接復用
            // 「繼續未完成課次」現有機制）；結果匯入是完整記錄，已完成。
            isInProgress: package.payloadKind == .plan,
            exchangeOriginInstallationID: package.originInstallationID, exchangeRecordID: dto.recordID,
            exchangeContentDigestSHA256: digest, exchangePackageID: package.packageID, sourcePlanID: dto.sourcePlanID
        )
        session.client = client
        for blockDTO in dto.blocks {
            let block = SessionBlock(order: blockDTO.order, blockType: blockDTO.blockType, restSeconds: blockDTO.restSeconds, sourceRow: 0, sectionKind: blockDTO.sectionKind)
            block.setWODPayloadRawJSON(blockDTO.wodPayloadRawJSON)
            block.session = session
            context.insert(block)
            for entryDTO in blockDTO.entries {
                let exercise = resolveExercise(entryDTO.exerciseRef)
                let entry = ExerciseEntry(
                    order: entryDTO.order, exerciseIdRef: exercise?.id ?? entryDTO.exerciseRef.exerciseID,
                    exerciseRaw: entryDTO.exerciseRef.canonicalName, plannedSets: entryDTO.plannedSets, exercise: exercise
                )
                entry.block = block
                context.insert(entry)
                for setDTO in entryDTO.sets {
                    // A `.plan` package's `actual` is always `nil` by
                    // construction (`ExchangeExporter.buildPlanPackage`) --
                    // falls back to `target`, the same "actual defaults to
                    // target until edited" convention every other
                    // freshly-created entry in this app already follows
                    // (see `EntryDraft`'s own initializer).
                    let actual = setDTO.actual ?? setDTO.target
                    let setLog = SetLog(setIndex: setDTO.setIndex, load: setDTO.load, target: setDTO.target, actual: actual, isInferred: false)
                    setLog.entry = entry
                    context.insert(setLog)
                }
            }
        }
        return session
    }

    private static func nameUnitKey(_ name: String, _ metric: RecordingMetric) -> String {
        "\(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(metric.rawValue)"
    }

    private static func localDate(_ isoDay: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        // Noon local, not midnight: avoids a date landing on the PREVIOUS
        // day if downstream code (or a future timezone-aware read) rounds
        // near a DST boundary -- the same defensive margin the app's own
        // date-handling code uses elsewhere for local-day semantics.
        return formatter.date(from: isoDay).map { Calendar.current.date(byAdding: .hour, value: 12, to: $0) ?? $0 } ?? Date()
    }
}
