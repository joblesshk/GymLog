import Foundation
import Observation
import SwiftData

/// 2026-09-13 全局語音改造：把語音服務/錄音/語言模式/候選澄清狀態從
/// `TodayView` 私有 `@State` 提升到這裡，讓 `ContentView` 能在根層構造
/// 唯一一份，今天/學員/歷史/動作庫/設置五個主要頁面共用同一個協調器，
/// 而不是每頁各自持有一份互不相通的語音狀態（執行 Prompt §4.1「全局入口
/// 統一入口，複用 CurrentClientStore/TodayDraftStore/ClientSwitchCoordinator/
/// TabSelectionStore，不在每頁複製一套錄音/語音服務」）。
///
/// 沒有 SwiftUI 依賴（只用 `Observation`/`Foundation`/`SwiftData`），因此
/// 留在 GymLogKit——跟 `VoiceCommandService`/`VoiceRecordingSession` 同一個
/// 理由，也讓 `GymLogKitTests` 能直接 `@testable import` 單元測試候選過時
/// 保護等邏輯，不需要拉起真正的 SwiftUI 視圖層。
@MainActor
@Observable
public final class VoiceCommandCoordinator {
    public let service: VoiceCommandService
    public let recordingSession: VoiceRecordingSession

    /// 面板是否顯示——`ContentView` 用一個 `.sheet(isPresented:)` 綁定它。
    public var isPanelPresented = false

    /// 2026-09-13：獨立於界面顯示語言/設備地區，記住上次選擇
    /// （`VoiceLanguageModePreference` 直接讀寫 `UserDefaults`）。
    public var languageMode: VoiceLanguageMode {
        didSet { VoiceLanguageModePreference.current = languageMode }
    }

    public var lastOutcome: VoiceCommandOutcome?
    public var lastRecognizedTranscript: String?

    /// 待確認的「原始文字重送」——只有 `.needsPreviewConfirm` 時才用得到。
    public var pendingConfirmText: String?
    /// 待確認的「點選候選後才跳出需要確認」——例如替換動作候選指到一個
    /// 已有記錄成績的 entry。
    public var pendingConfirmClarification: (pending: PendingClarification, candidateID: String)?

    /// 2026-09-13 修正候選等待期間保護不足的真實 bug：舊版 UI 在使用者
    /// 「點下候選/確認」那一刻才呼叫 `draft.currentRevisionToken()`，等於
    /// 拿「現在」的草稿狀態跟「現在」比較，恒真——完全沒有驗證「候選/預覽
    /// 產生之後，草稿有沒有被改動過」。這裡把候選/預覽產生那一刻的
    /// token 存下來，`resolveCandidate`/`confirmPending` 用的是這個保存
    /// 下來的原始 token，而不是呼叫當下重新抓的，過時檢測才是真的在比較
    /// 兩個不同時間點。
    private var originTokenForPendingClarification: DraftRevisionToken?
    private var originTokenForPendingConfirm: DraftRevisionToken?

    /// 錄音「開始」那一刻捕獲的 token——跟 `VoiceCommandService.apply
    /// (rawText:contextToken:...)` 的既有設計一致，錄音期間手動編輯草稿
    /// 必須被偵測到。
    private var pendingRecordingToken: DraftRevisionToken?

    // 註：「重量改成五十公斤」這類不重報動作名字、靠代詞指代上一個成功
    // 目標的後續命令，本輪尚未實作（見 CURRENT-STATUS.md 已知限制）——
    // 需要先讓 `VoiceCommandOutcome.applied` 帶出目標 entry 身份、再讓
    // `VoiceCommandParser` 認得「這個」/「重量改成」這類代詞語法，兩邊都
    // 沒做之前，先不在這裡放一個沒有實際消費者的狀態欄位。

    public init(languageMode: VoiceLanguageMode = VoiceLanguageModePreference.current) {
        self.service = VoiceCommandService()
        self.recordingSession = VoiceRecordingSession()
        self.languageMode = languageMode
    }

    public var canUndo: Bool { service.canUndo }

    // MARK: - Panel lifecycle

    public func openPanel() {
        isPanelPresented = true
    }

    public func closePanel() {
        isPanelPresented = false
        recordingSession.cancelIfRecording()
    }

    /// App 進背景/課次切換/學員切換時呼叫——正在錄的音沒有意義繼續錄，
    /// 待處理的候選/確認狀態也一併清空，避免污染下一個學員/課次。
    public func resetForContextChange() {
        recordingSession.cancelIfRecording()
        lastOutcome = nil
        lastRecognizedTranscript = nil
        pendingConfirmText = nil
        pendingConfirmClarification = nil
        originTokenForPendingClarification = nil
        originTokenForPendingConfirm = nil
        pendingRecordingToken = nil
    }

    // MARK: - 文字指令

    public func submitText(_ text: String, draft: TodayDraftStore, allExercises: [Exercise], context: ModelContext, clientID: String) {
        guard draft.isActive else {
            handleInactiveSession(text, draft: draft, allExercises: allExercises, context: context, clientID: clientID)
            return
        }
        let token = draft.currentRevisionToken()
        let outcome = service.apply(rawText: text, contextToken: token, draft: draft, allExercises: allExercises, context: context, clientID: clientID)
        handle(outcome, originToken: token, draft: draft)
        if case .needsPreviewConfirm = outcome {
            pendingConfirmText = text
        }
    }

    // MARK: - 錄音

    public func startRecording(draft: TodayDraftStore, contextualStrings: [String] = []) {
        pendingRecordingToken = draft.currentRevisionToken()
        recordingSession.start(locale: languageMode.recognitionLocale, contextualStrings: contextualStrings)
    }

    public func stopRecording() {
        recordingSession.stop()
    }

    /// `recordingSession.finalTranscript` 有新值時，呼叫方（面板的
    /// `.onChange`）呼叫這個方法；呼叫完之後呼叫方負責清空
    /// `finalTranscript`（跟原本 sheet 的既有慣例一致）。
    public func handleFinalTranscript(_ transcript: String, draft: TodayDraftStore, allExercises: [Exercise], context: ModelContext, clientID: String) {
        lastRecognizedTranscript = transcript
        guard draft.isActive else {
            pendingRecordingToken = nil
            handleInactiveSession(transcript, draft: draft, allExercises: allExercises, context: context, clientID: clientID)
            return
        }
        guard let token = pendingRecordingToken else { return }
        pendingRecordingToken = nil
        let outcome = service.apply(rawText: transcript, contextToken: token, draft: draft, allExercises: allExercises, context: context, clientID: clientID)
        handle(outcome, originToken: token, draft: draft)
    }

    // MARK: - 沒有進行中課次時的語音入口

    /// 2026-09-13 真機試用反饋："在新建空課次之前...按語音是沒有任何效果
    /// 的"——舊版面板在 `!draft.isActive` 時直接把文字輸入/錄音整條路都
    /// disable 掉，語音在開課之前完全是死的，使用者必須先手動點按鈕開課
    /// 才能開始用語音。這裡改成：沒有進行中課次時，語音/文字輸入仍然
    /// 可用，但走這條專門的分支——辨認到"新建/開始"+"課次/訓練"這類開課
    /// 意圖就直接開課；同一句話裡如果還帶了動作內容（"新建空課次，添加
    /// 深蹲三組十次"），開課之後立刻把整句話原樣再跑一次正常管線，讓
    /// 新增動作/模糊回退接手，不需要使用者開課後再說一遍。
    private func handleInactiveSession(_ text: String, draft: TodayDraftStore, allExercises: [Exercise], context: ModelContext, clientID: String) {
        guard !clientID.isEmpty else {
            lastOutcome = .rejected(reason: "請先在頁面上方選擇一位學員")
            return
        }
        guard VoiceCommandParser.looksLikeSessionStartRequest(text) else {
            lastOutcome = .rejected(reason: "目前沒有進行中的課次，請說「新建空課次」開始")
            return
        }
        draft.startNew(clientID: clientID)
        lastOutcome = .applied(summary: "已新建空課次", canUndo: false)
        // 開課次之後，`draft.isActive` 已經是 true——直接把整句原話再跑一次
        // 正常管線；只有真的找到東西（成功套用、或帶候選的澄清）才覆蓋掉
        // 上面"已新建空課次"這句成功訊息，單純"新建空課次"這種沒有動作
        // 內容的句子被模糊回退硬湊成"無法識別的指令"時，不要蓋掉剛剛開課
        // 成功的訊息。
        let token = draft.currentRevisionToken()
        let followUp = service.apply(rawText: text, contextToken: token, draft: draft, allExercises: allExercises, context: context, clientID: clientID)
        switch followUp {
        case .applied:
            handle(followUp, originToken: token, draft: draft)
        case .needsClarification(_, let candidates, _) where !candidates.isEmpty:
            handle(followUp, originToken: token, draft: draft)
        case .needsPreviewConfirm:
            handle(followUp, originToken: token, draft: draft)
            pendingConfirmText = text
        default:
            break
        }
    }

    // MARK: - 候選/預覽確認

    public func chooseClarificationCandidate(
        _ candidate: ClarificationCandidate, pending: PendingClarification,
        draft: TodayDraftStore, allExercises: [Exercise], context: ModelContext, clientID: String
    ) {
        // 用「候選產生那一刻」保存的原始 token，不是現在重抓的——見上面
        // `originTokenForPendingClarification` 的說明。
        let token = originTokenForPendingClarification ?? draft.currentRevisionToken()
        let outcome = service.applyClarifiedChoice(
            pending, chosenCandidateID: candidate.id, contextToken: token,
            draft: draft, allExercises: allExercises, context: context, clientID: clientID
        )
        handle(outcome, originToken: token, draft: draft)
        if case .needsPreviewConfirm = outcome {
            pendingConfirmClarification = (pending, candidate.id)
        }
    }

    public func confirmPending(draft: TodayDraftStore, allExercises: [Exercise], context: ModelContext, clientID: String) {
        if let clarification = pendingConfirmClarification {
            let token = originTokenForPendingConfirm ?? draft.currentRevisionToken()
            let outcome = service.applyClarifiedChoice(
                clarification.pending, chosenCandidateID: clarification.candidateID, contextToken: token,
                draft: draft, allExercises: allExercises, context: context, clientID: clientID, forceApply: true
            )
            pendingConfirmClarification = nil
            originTokenForPendingConfirm = nil
            handle(outcome, originToken: token, draft: draft, skipConfirmCapture: true)
            return
        }
        guard let text = pendingConfirmText else { return }
        let token = originTokenForPendingConfirm ?? draft.currentRevisionToken()
        let outcome = service.apply(rawText: text, contextToken: token, draft: draft, allExercises: allExercises, context: context, clientID: clientID, forceApply: true)
        pendingConfirmText = nil
        originTokenForPendingConfirm = nil
        handle(outcome, originToken: token, draft: draft, skipConfirmCapture: true)
    }

    // MARK: - 撤銷（類型化，不受 UI 顯示語言影響）

    public func undo(draft: TodayDraftStore) {
        lastOutcome = service.applyUndo(draft: draft)
    }

    // MARK: - Shared outcome handling

    private func handle(_ outcome: VoiceCommandOutcome, originToken: DraftRevisionToken, draft: TodayDraftStore, skipConfirmCapture: Bool = false) {
        lastOutcome = outcome
        // 每次新的結果進來，先清空所有舊的待確認狀態——呼叫方會依 outcome
        // 的實際 case 在這之後重新設定需要保留的那一項，不能讓上一條命令
        // 留下的待確認狀態污染這一條全新的結果。
        pendingConfirmText = nil
        pendingConfirmClarification = nil
        originTokenForPendingClarification = nil
        if !skipConfirmCapture {
            originTokenForPendingConfirm = nil
        }
        switch outcome {
        case .needsPreviewConfirm:
            if !skipConfirmCapture {
                originTokenForPendingConfirm = originToken
            }
        case .needsClarification(_, let candidates, let pending):
            if pending != nil, !candidates.isEmpty {
                originTokenForPendingClarification = originToken
            }
        case .applied, .rejected, .staleDraft:
            break
        }
    }
}
