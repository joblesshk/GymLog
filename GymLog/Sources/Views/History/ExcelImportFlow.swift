import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import GymLogKit

/// Orchestrates the whole Excel-import journey -- file picker → background
/// parse → client identity resolution → exercise-library auto-fill →
/// preview → commit. Presented as a sheet from `HistoryListView`; reports
/// its outcome back via `onImportComplete` rather than owning its own
/// success/failure banner, so `HistoryListView` can display it the same way
/// it would any other local status.
///
/// Two steps that used to need the coach's confirmation are now fully
/// automatic (coach-requested change, see 工程记录.md):
/// - **Client identity**: if the workbook's `Info` sheet has a non-empty
///   `Name` that differs from the currently-selected client, the import
///   targets a DIFFERENT client instead -- an existing one by that name if
///   there is one, otherwise a brand-new client seeded from every other
///   `Info` field the sheet has (phone/gender/age/height/weight/goal/
///   frequency/BMR/TDEE/habits/medical history). A blank `Name` (true for
///   every real file this app has seen so far -- `ExcelClientInfoParser`'s
///   own header comment) just falls back to the client already selected,
///   exactly like before this change.
/// - **Exercise library**: any exercise name the workbook references that
///   isn't already in the library gets created automatically (still
///   `needsReview = true`, still classified by `ExerciseClassifier`) rather
///   than stopping to ask the coach per name via `UnresolvedExerciseSheet`
///   (removed). The coach still sees exactly how many were added, in the
///   `確認導入` preview before anything commits.
struct ExcelImportFlow: View {
    let client: Client
    let onImportComplete: (ImportStatusBanner.Status) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant
    @Query private var allExercises: [Exercise]
    @Query(sort: \Client.name) private var allClients: [Client]

    // Starts `false`, not `true`: the real picker is only turned on in
    // `.onAppear` below, and only when the `GYMLOG_EXCEL_IMPORT_PATH` test
    // hook isn't set -- starting `true` raced the hook, since
    // `.fileImporter(isPresented:)` reacting to the initial `true` value
    // and `.onAppear` flipping it back to `false` both happen on the same
    // first render, and the picker had already committed to presenting by
    // the time the hook's mutation landed.
    @State private var showingFilePicker = false
    @State private var isProcessing = false
    @State private var errorMessage: String?

    @State private var parsedWorkbook: ParsedWorkbook?
    @State private var rawWorkbook: XLSXWorkbook?
    @State private var sourceFileName = ""

    // The client this import will actually write to -- may differ from
    // `client` (see the type's own doc comment above). Resolved once,
    // right after parsing, and reused by both the preview pass and the
    // real commit so they can never disagree about the target.
    @State private var resolvedClient: Client?
    @State private var isNewClient = false
    @State private var exerciseResolutions: [String: Exercise] = [:]
    @State private var newExerciseCount = 0
    // Newly-created Exercises for unresolved names, kept OUT of
    // `modelContext` until the coach actually confirms the import (see
    // `resolveClient`/`proceedAfterParse` below) -- 2026-09-06 审查报告 #2.
    @State private var newlyCreatedExercises: [Exercise] = []

    @State private var previewResult: XLSXHistoryImporter.ImportResult?
    @State private var showingPreview = false

    /// > 20MB / a runaway row count both indicate "wrong file" rather than
    /// a legitimately large training log -- CONTRACT-M7.md §7 step 10 /
    /// §9.4. Real files are ~65KB; this is a generous multiple, not a tight
    /// bound.
    private static let maxFileSize = 20_000_000

    var body: some View {
        Color.clear
            .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [UTType(filenameExtension: "xlsx") ?? .data]) { result in
                handleFileSelection(result)
            }
            // Verification-only launch hook (same family as
            // `GYMLOG_INITIAL_TAB`/`GYMLOG_INITIAL_SESSION_ID` in
            // ContentView.swift/HistoryListView.swift): setting
            // `GYMLOG_EXCEL_IMPORT_PATH=<absolute path>` feeds that file
            // straight into `handleFileSelection` instead of waiting on
            // `UIDocumentPickerViewController`, since the simulator has no
            // straightforward scripted way to pick a file from "On My
            // iPhone"/iCloud Drive. Every downstream step (parse, client
            // resolution, exercise auto-fill, preview, commit) still runs
            // for real -- only Apple's own picker chrome is bypassed, not
            // any of this feature's own code. No effect unless that env
            // var is explicitly set.
            .onAppear {
                if let path = ProcessInfo.processInfo.environment["GYMLOG_EXCEL_IMPORT_PATH"] {
                    handleFileSelection(.success(URL(fileURLWithPath: path)), requireSecurityScope: false)
                } else {
                    showingFilePicker = true
                }
            }
            .overlay {
                if isProcessing {
                    ProgressView(language.t("解析中…", "Parsing…"))
                        .padding(16)
                        .background(DS.C.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .sheet(isPresented: $showingPreview, onDismiss: { dismiss() }) {
                if let parsedWorkbook, let rawWorkbook, let previewResult, let resolvedClient {
                    ExcelImportPreviewSheet(
                        fileName: sourceFileName,
                        clientName: resolvedClient.displayName,
                        isNewClient: isNewClient,
                        sheetNames: Array(Set(parsedWorkbook.sessions.map(\.sourceSheet))).sorted(),
                        sessionCount: parsedWorkbook.sessions.count,
                        dateRangeText: dateRangeText(for: parsedWorkbook),
                        result: previewResult,
                        newExerciseCount: newExerciseCount,
                        exercisesNeedingReview: parsedWorkbook.exercises.filter(\.needsReview).count,
                        sessionsNeedingReview: parsedWorkbook.sessions.filter(\.needsReview).count,
                        onConfirm: { commitImport(parsedWorkbook: parsedWorkbook, rawWorkbook: rawWorkbook, client: resolvedClient) }
                    )
                }
            }
            .alert(language.t("導入失敗", "Import Failed"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { let wasShowing = errorMessage != nil; errorMessage = nil; if wasShowing { dismiss() } } }
            )) {
                Button(language.t("好", "OK"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    /// `requireSecurityScope` is `false` only for the `GYMLOG_EXCEL_IMPORT_PATH`
    /// test hook above: a plain `URL(fileURLWithPath:)` pointing inside this
    /// app's own sandbox was never obtained through the document picker, so
    /// it has no security-scoped bookmark to start -- calling
    /// `startAccessingSecurityScopedResource()` on it is meaningless (and,
    /// per Apple's docs, correctly returns `false`), not a sign the file is
    /// unreadable. A real user-picked URL always goes through the normal
    /// `true` path and keeps the exact same guard as before.
    private func handleFileSelection(_ result: Result<URL, Error>, requireSecurityScope: Bool = true) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let url):
            sourceFileName = url.lastPathComponent
            // Re-check the extension explicitly: `allowedContentTypes`
            // narrows the picker's own file list, but doesn't stop a
            // provider from handing back something else.
            guard url.pathExtension.lowercased() == "xlsx" else {
                errorMessage = language.t("請選擇 .xlsx 檔案。", "Please choose an .xlsx file.")
                return
            }
            let didStartScope = url.startAccessingSecurityScopedResource()
            guard didStartScope || !requireSecurityScope else {
                errorMessage = language.t("無法讀取這個檔案。", "Couldn't read that file.")
                return
            }
            isProcessing = true
            Task.detached(priority: .userInitiated) {
                defer { if didStartScope { url.stopAccessingSecurityScopedResource() } }
                do {
                    // 2026-09-07 审阅 B10: check the file's size BEFORE
                    // reading its bytes -- reading the whole file first (the
                    // old order) already paid the memory cost the size
                    // check exists to avoid, for any file that happened to
                    // be huge rather than merely mis-selected.
                    let fileSizeValues = try? url.resourceValues(forKeys: [.fileSizeKey])
                    guard let fileSize = fileSizeValues?.fileSize, fileSize < Self.maxFileSize else {
                        await MainActor.run {
                            isProcessing = false
                            errorMessage = language.t("檔案過大（超過 20MB），請確認選擇的是正確檔案。", "File too large (over 20MB) — please check you selected the right file.")
                        }
                        return
                    }
                    let data = try Data(contentsOf: url)
                    let archive = try ZipArchiveReader(data: data)
                    let workbook = try XLSXWorkbook(archive: archive)
                    let parsed = try WorkbookSessionParser.parse(workbook)
                    let clientInfo = ExcelClientInfoParser.parse(workbook)
                    await MainActor.run {
                        rawWorkbook = workbook
                        parsedWorkbook = parsed
                        isProcessing = false
                        proceedAfterParse(parsed, clientInfo: clientInfo)
                    }
                } catch {
                    await MainActor.run {
                        isProcessing = false
                        errorMessage = Self.describe(error, language: language)
                    }
                }
            }
        }
    }

    // MARK: - Client identity resolution

    /// Blank/no `Info.Name` -> the currently-selected client, unchanged
    /// from before this feature existed. A non-blank name that matches the
    /// current client (trimmed, case-insensitive -- coaches retype names
    /// with inconsistent casing/whitespace far more often than they mean
    /// two different people) also just keeps using it, profile fields and
    /// all, rather than treating a spelling-only match as "different."
    /// Otherwise: reuse an existing OTHER client with that exact name if
    /// one exists (so re-importing a second client's file twice doesn't
    /// spawn duplicates), and only create a new one as a last resort.
    /// Builds a candidate new `Client` WITHOUT inserting it into
    /// `modelContext` -- it's only inserted (in `commitImport`) once the
    /// coach actually confirms the import. Previously this inserted straight
    /// into the shared context during parsing, before the preview was even
    /// shown; cancelling the flow (or dismissing it any other way) never
    /// undid that insert, so a merely-previewed workbook could leave behind
    /// a phantom client the next time anything else in the app saved
    /// (2026-09-06 审查报告 #2).
    private func resolveClient(_ info: ParsedClientInfo?) -> (client: Client, isNew: Bool) {
        guard let info else { return (client, false) }
        let normalizedInfoName = normalize(info.name)
        if normalizedInfoName == normalize(client.displayName) {
            return (client, false)
        }
        if let existing = allClients.first(where: { normalize($0.displayName) == normalizedInfoName }) {
            return (existing, false)
        }
        let newClient = Client(
            id: "cl-excel-\(UUID().uuidString)",
            name: info.name,
            phone: info.phone,
            gender: info.gender,
            age: info.age,
            heightCm: info.heightCm,
            startWeightKg: info.startWeightKg,
            goal: info.goal,
            frequency: info.frequency,
            bmr: info.bmr,
            tdee: info.tdee,
            habits: info.habits,
            medicalHistory: info.medicalHistory
        )
        return (newClient, true)
    }

    private func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Exercise library auto-fill

    private func proceedAfterParse(_ parsed: ParsedWorkbook, clientInfo: ParsedClientInfo?) {
        let (client, isNew) = resolveClient(clientInfo)
        resolvedClient = client
        isNewClient = isNew

        let (resolved, unresolvedKeys) = XLSXHistoryImporter.resolveExercises(parsed, existing: allExercises)
        var resolutions = resolved
        var created: [Exercise] = []
        for key in unresolvedKeys {
            guard let parsedExercise = parsed.exercises.first(where: { $0.key == key }) else { continue }
            let exercise = Exercise(
                id: parsedExercise.id, canonicalName: parsedExercise.canonicalName, aliases: parsedExercise.aliases,
                movementPattern: parsedExercise.movementPattern, equipment: parsedExercise.equipment,
                loadDirection: parsedExercise.loadDirection, isUnilateral: parsedExercise.isUnilateral,
                occurrenceCount: parsedExercise.occurrenceCount, needsReview: true,
                reviewReason: language.t("由 Excel 導入時自動新建，未經教練確認分類", "Auto-created during Excel import, not yet confirmed by the coach"),
                recordingMetric: parsedExercise.recordingMetric
            )
            // Not inserted here -- see `newlyCreatedExercises` doc comment.
            resolutions[key] = exercise
            created.append(exercise)
        }
        exerciseResolutions = resolutions
        newlyCreatedExercises = created
        newExerciseCount = unresolvedKeys.count
        computePreview()
    }

    private func computePreview() {
        guard let parsedWorkbook, let rawWorkbook, let resolvedClient else { return }
        do {
            let result = try XLSXHistoryImporter.importSessions(
                parsedWorkbook, rawWorkbook: rawWorkbook, client: resolvedClient, sourceFileName: sourceFileName,
                exerciseResolutions: exerciseResolutions, preview: true, into: modelContext
            )
            previewResult = result
            showingPreview = true
        } catch {
            errorMessage = Self.describe(error, language: language)
        }
    }

    private func commitImport(parsedWorkbook: ParsedWorkbook, rawWorkbook: XLSXWorkbook, client: Client) {
        let start = Date()
        // Only now -- the coach has confirmed -- do the candidate client/
        // exercises actually enter the shared context. If `importSessions`
        // below throws, its own `context.rollback()` (preview: false path)
        // undoes these same-tick inserts along with everything else it
        // attempted, so a failed commit still leaves nothing stray behind.
        if isNewClient { modelContext.insert(client) }
        for exercise in newlyCreatedExercises { modelContext.insert(exercise) }
        do {
            let result = try XLSXHistoryImporter.importSessions(
                parsedWorkbook, rawWorkbook: rawWorkbook, client: client, sourceFileName: sourceFileName,
                exerciseResolutions: exerciseResolutions, into: modelContext
            )
            let elapsed = Date().timeIntervalSince(start)
            onImportComplete(.excelSuccess(result, elapsedSeconds: elapsed))
        } catch {
            onImportComplete(.failure(Self.describe(error, language: language)))
        }
    }

    private func dateRangeText(for parsed: ParsedWorkbook) -> String? {
        guard let first = parsed.sessions.first?.date, let last = parsed.sessions.last?.date else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return "\(formatter.string(from: first)) → \(formatter.string(from: last))"
    }

    private static func describe(_ error: Error, language: AppLanguage) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        if let parserError = error as? WorkbookSessionParserError {
            switch parserError {
            case .noLogSheets:
                return language.t("找不到訓練記錄：A 欄需要有「Week 1」這樣的課次標題列。", "No training log found: column A needs session header rows such as \"Week 1\".")
            case let .headerMismatch(sheet, row, _):
                return language.t("「\(sheet)」第 \(row) 行的表頭須依次為 Exercise, Sets, Weight 或 Weights, Rep range, Rep completed, Rest, Notes。", "Row \(row) of \"\(sheet)\" must have the headers Exercise, Sets, Weight or Weights, Rep range, Rep completed, Rest, Notes.")
            case let .invalidDate(sheet, row, raw):
                return language.t("「\(sheet)」第 \(row) 列的日期「\(raw)」無法識別；請填寫 Excel 日期，或「日/月」、「日/月/年」。", "The date \"\(raw)\" in row \(row) of \"\(sheet)\" can't be read; use an Excel date, or day/month or day/month/year text.")
            case .dateOrderingBroken:
                return language.t("課次日期前後順序混亂，請檢查日期欄是否填錯。", "Session dates are badly out of order; check the date column for mistakes.")
            }
        }
        if error is XLSXWorkbookError || error is ArchiveReadingError {
            return language.t("這個檔案看起來不是有效的訓練記錄 Excel 檔案。", "This file doesn't look like a valid training-log Excel file.")
        }
        return String(describing: error)
    }
}
