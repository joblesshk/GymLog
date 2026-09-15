import Foundation
import SwiftData
import Observation

@MainActor @Observable
public final class CloudVoiceController {
    public let recordingSession = VoiceRecordingSession()
    public var isPanelPresented = false
    public private(set) var busy = false
    public private(set) var transcript = ""
    public private(set) var message = ""
    public private(set) var details = [String]()
    public private(set) var needsClarification = false
    public private(set) var needsConfirmation = false
    public private(set) var succeeded = false
    public private(set) var lastTarget: String?
    public private(set) var hotwordCount = 0
    public private(set) var uncoveredCount = 0
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var recordingOrigin: CloudDraftState?
    private var recordingClient = ""
    private var pending: (CloudVoicePlan, CloudDraftState, UUID, String)?
    private var clarificationOrigin: CloudDraftState?
    private var clarificationTranscript = ""
    private var lastState: CloudDraftState?
    private let interpreter: any CloudVoiceInterpreting
    private let executor = CloudVoiceExecutor()
    public init(interpreter: any CloudVoiceInterpreting = CloudVoiceInterpreter()) { self.interpreter = interpreter }
    public var canUndo: Bool { executor.canUndo }
    public func openPanel() { isPanelPresented = true }
    public func closePanel() { cancel(); isPanelPresented = false }
    public func cancel() {
        if busy || recordingSession.status == .recording || recordingSession.status == .processing || needsConfirmation {
            message = "已取消，沒有修改訓練。"; succeeded = false
        }
        generation = UUID(); task?.cancel(); task = nil; busy = false
        recordingSession.cancelIfRecording(); recordingOrigin = nil
        pending = nil; needsConfirmation = false
    }
    public func resetForContextChange() {
        cancel(); executor.reset(); lastTarget = nil; lastState = nil
        needsClarification = false; clarificationTranscript = ""; clarificationOrigin = nil
        transcript = ""; message = ""; details = []; succeeded = false
    }
    public func startRecording(draft: TodayDraftStore, exercises: [Exercise], clientID: String) {
        guard !busy else { return }
        guard !clientID.isEmpty else { message = "請先選擇學員。"; return }
        let config = CloudVoiceConfiguration.load()
        guard config.hasLLM else { message = "請先完成雲端設定。"; return }
        recordingOrigin = CloudDraftState(draft); recordingClient = clientID
        let catalog = ExerciseVocabularyCatalog(exercises: exercises)
        let selection = ContextualHotwordSelector.select(catalog: catalog,
            currentDraftExerciseIDs: draft.allEntries.map(\.exercise.id), limit: config.hotwordLimit)
        hotwordCount = selection.phrases.count; uncoveredCount = selection.uncoveredExerciseIDs.count
        message = ""; succeeded = false
        recordingSession.start(contextualStrings: selection.phrases)
    }
    public func acceptRecording(draft: TodayDraftStore, exercises: [Exercise], clientID: String, context: ModelContext) {
        guard let text = recordingSession.finalTranscript else { return }
        recordingSession.finalTranscript = nil
        guard let origin = recordingOrigin, origin == CloudDraftState(draft), recordingClient == clientID else {
            message = "錄音期間訓練或學員已改變，請重新說一次。"; return
        }
        recordingOrigin = nil
        var config = CloudVoiceConfiguration.load()
        config.llmKey = recordingSession.operationToken ?? ""
        recordingSession.operationToken = nil
        submit(text, draft: draft, exercises: exercises, clientID: clientID, context: context, configuration: config)
    }
    public func submit(_ text: String, draft: TodayDraftStore, exercises: [Exercise], clientID: String,
                       context: ModelContext, configuration: CloudVoiceConfiguration? = nil) {
        guard !busy else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !clientID.isEmpty else { message = "請選擇學員並說出訓練指令。"; return }
        guard text.count <= 6000 else { message = "這段指令太長，請分成幾次輸入。"; return }
        let origin = CloudDraftState(draft)
        let continued = needsClarification && clarificationOrigin == origin
        transcript = continued ? clarificationTranscript + "\n補充：" + text : text
        if lastState != origin { lastTarget = nil }
        let requestText = transcript
        let config = configuration ?? CloudVoiceConfiguration.load()
        generation = UUID(); let ticket = generation; let requestID = UUID()
        pending = nil; needsConfirmation = false; needsClarification = false
        message = "正在理解你的安排…"; details = []; succeeded = false; busy = true
        let catalogVersion = ExerciseVocabularyCatalog(exercises: exercises).version
        let input = Self.contextJSON(draft: draft, exercises: exercises, lastTarget: lastTarget, language: "auto")
        task = Task {
            do {
                let plan = try await interpreter.interpret(transcript: requestText, context: input, configuration: config)
                guard !Task.isCancelled, ticket == generation else { return }
                guard origin == CloudDraftState(draft), catalogVersion == ExerciseVocabularyCatalog(exercises: exercises).version else { throw CloudVoiceError.message("理解期間訓練已改變，請重新說一次。") }
                busy = false
                if let question = plan.clarification, !question.isEmpty {
                    message = question; needsClarification = true
                    clarificationOrigin = origin; clarificationTranscript = requestText; return
                }
                pending = (plan, origin, requestID, clientID)
                applyPending(draft: draft, exercises: exercises, context: context, confirmed: false)
            } catch {
                guard ticket == generation else { return }
                busy = false; message = Self.displayError(error); succeeded = false
            }
        }
    }
    public func clearClarification() { needsClarification = false; clarificationOrigin = nil; clarificationTranscript = "" }
    public func confirm(draft: TodayDraftStore, exercises: [Exercise], context: ModelContext) {
        applyPending(draft: draft, exercises: exercises, context: context, confirmed: true)
    }
    private func applyPending(draft: TodayDraftStore, exercises: [Exercise], context: ModelContext, confirmed: Bool) {
        guard let (plan, origin, id, clientID) = pending else { return }
        do {
            let result = try executor.apply(plan, transcript: transcript, requestID: id, origin: origin,
                draft: draft, exercises: exercises, clientID: clientID, context: context, confirmed: confirmed)
            message = result.summary; details = (plan.assumptions ?? []).map { "推斷：\($0)" } + result.details; lastTarget = result.lastTarget
            lastState = CloudDraftState(draft); succeeded = true; needsConfirmation = false; pending = nil
            clarificationOrigin = nil; clarificationTranscript = ""
        } catch is CloudVoiceExecutionNeedsConfirmation {
            message = "這次修改會移除或重置已有成績。請核對原話，確認後整句執行。"
            needsConfirmation = true
        } catch { message = Self.displayError(error); pending = nil; needsConfirmation = false }
    }
    public func undo(draft: TodayDraftStore, exercises: [Exercise]) {
        do { try executor.undo(draft: draft, exercises: exercises); message = "已撤銷上一句的全部修改"; details = []; lastTarget = nil; succeeded = true }
        catch { message = Self.displayError(error); succeeded = false }
    }
    static func displayError(_ error: Error) -> String {
        if let error = error as? CloudVoiceError { return error.localizedDescription }
        if error is CancellationError { return "已取消，沒有修改訓練。" }
        return "雲端連線或指令格式有問題，沒有修改訓練。原話已保留，請重試。"
    }
    static func contextJSON(draft: TodayDraftStore, exercises: [Exercise], lastTarget: String?, language: String) -> String {
        let catalog: [[String: Any]] = exercises.map { ["id": $0.id, "name": $0.canonicalName,
            "zh": $0.nameZh, "aliases": $0.aliases, "metric": $0.recordingMetric.rawValue, "equipment": $0.equipment.rawValue] }
        let entries: [[String: Any]] = draft.blocks.flatMap { block in block.entries.map { e in
            ["target": e.id.uuidString, "exerciseID": e.exercise.id, "blockID": block.id.uuidString,
             "blockType": block.blockType.rawValue, "metric": e.recordingMetric.rawValue,
             "sets": e.rounds.map { ["count": $0.setsCount, "target": RepTargetToRoundQuantity.quantity(from: $0.target, metric: e.recordingMetric),
                "actual": $0.actualRecorded ? RepTargetToRoundQuantity.quantity(from: $0.actual, metric: e.recordingMetric) as Any : NSNull(), "load": $0.load.displayText] }] as [String: Any]
        } }
        let object: [String: Any] = ["active": draft.isActive, "language": language,
            "lastTarget": lastTarget as Any? ?? NSNull(), "catalog": catalog, "entries": entries]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

extension CloudVoiceController {
    public static func forApplication() -> CloudVoiceController {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-cloudVoiceUITesting") {
            return CloudVoiceController(interpreter: CloudVoiceUIFixture())
        }
        #endif
        return CloudVoiceController()
    }
}
#if DEBUG
/// Explicit UI-test transport fixture, never an offline recognizer or a release fallback.
private struct CloudVoiceUIFixture: CloudVoiceInterpreting {
    func interpret(transcript: String, context: String, configuration: CloudVoiceConfiguration) async throws -> CloudVoicePlan {
        try await Task.sleep(nanoseconds: 100_000_000)
        if transcript == "Create test plan" {
            let data = try JSONSerialization.jsonObject(with: Data(context.utf8)) as! [String: Any]
            let catalog = data["catalog"] as! [[String: Any]]
            let ids = catalog.filter { ["back squat", "plank"].contains(($0["name"] as? String ?? "").lowercased()) }.map { $0["id"] as! String }
            guard ids.count == 2 else { throw CloudVoiceError.message("測試動作庫尚未載入。") }
            return CloudVoicePlan(operations: [.init(kind: .startSession, evidence: transcript)] + ids.map {
                .init(kind: .addExercise, evidence: transcript, exerciseID: $0)
            })
        }
        let data = try JSONSerialization.jsonObject(with: Data(context.utf8)) as! [String: Any]
        let catalog = data["catalog"] as! [[String: Any]]
        let row = catalog.first { ($0["name"] as? String ?? "").lowercased().contains("row") }!
        return CloudVoicePlan(assumptions: ["未指定划船種類，已選擇動作庫中的划船動作。"], operations: [
            .init(kind: .startSession, evidence: transcript),
            .init(kind: .addExercise, evidence: transcript, exerciseID: row["id"] as? String)
        ])
    }
}
#endif
