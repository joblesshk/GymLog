import SwiftUI
import SwiftData
import GymLogKit

struct VoiceCommandPanel: View {
    let coordinator: CloudVoiceController
    @Bindable var draft: TodayDraftStore
    let allExercises: [Exercise]
    let clientID: String
    let clientDisplayName: String
    let context: ModelContext
    var showToday: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var inputText = ""
    @State private var editingText = false
    @FocusState private var textFocused: Bool
    private var recording: Bool { coordinator.recordingSession.status == .recording }
    private var processing: Bool { coordinator.busy || coordinator.recordingSession.status == .processing }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(clientDisplayName.isEmpty ? "請先選擇學員" : "\(clientDisplayName) · \(draft.sessionDate.formatted(date: .abbreviated, time: .omitted))")
                            .font(.subheadline).foregroundStyle(DS.C.textMid)
                            .accessibilityIdentifier("voice-command-target-bar")
                        Text(coordinator.needsClarification ? "補充一句，繼續安排" : (draft.isActive ? "接著調整你的訓練" : "說出今天的訓練計劃"))
                            .font(.title2.weight(.semibold))
                        Text("自動辨識語言。說出想法即可，我會按最可能的意思安排，列出推斷並補齊計劃數值；執行後可撤銷。實際成績只按明確口述記錄。")
                            .font(.subheadline).foregroundStyle(DS.C.textMid)
                    }
                    VStack(spacing: 14) {
                        Button {
                            if recording { coordinator.recordingSession.stop() }
                            else { coordinator.startRecording(draft: draft, exercises: allExercises, clientID: clientID) }
                        } label: {
                            ZStack {
                                Circle().fill(recording ? Color.red : DS.C.accent).frame(width: 88, height: 88)
                                if processing { ProgressView().tint(.white) }
                                else { Image(systemName: recording ? "stop.fill" : "mic.fill").font(.system(size: 30, weight: .medium)).foregroundStyle(.white) }
                            }
                        }.buttonStyle(.plain).disabled(processing || clientID.isEmpty)
                        .accessibilityLabel(recording ? "完成錄音" : "開始錄音")
                        .accessibilityIdentifier("voice-command-mic-button")
                        Text(recording ? "正在聆聽 · \(coordinator.recordingSession.elapsedSeconds)秒 · 點擊完成" : processing ? "正在處理，請稍候…" : "點一下開始說話")
                            .font(.subheadline).foregroundStyle(DS.C.textMid)
                        if recording || processing { Button("取消這次操作") { coordinator.cancel() } }
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)

                    if case .unavailable(let reason) = coordinator.recordingSession.status {
                        Text(reason).font(.subheadline).foregroundStyle(.orange)
                    }
                    if !coordinator.message.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(coordinator.message, systemImage: coordinator.succeeded ? "checkmark.circle" : coordinator.needsClarification ? "questionmark.circle" : "text.bubble")
                                .font(.headline).accessibilityIdentifier("cloud-voice-result")
                            ForEach(Array(coordinator.details.enumerated()), id: \.offset) { _, text in
                                Text(text).font(.subheadline)
                            }
                            if coordinator.needsConfirmation {
                                Button("確認修改已有成績") { coordinator.confirm(draft: draft, exercises: allExercises, context: context) }
                                    .buttonStyle(.borderedProminent)
                                Button("取消修改") { coordinator.cancel() }
                            }
                            if coordinator.succeeded && draft.isActive {
                                Button("查看今天的計劃") { coordinator.closePanel(); showToday(); dismiss() }
                                    .buttonStyle(.borderedProminent)
                            }
                            if coordinator.canUndo && !processing && !recording {
                                Button("撤銷上一句") { coordinator.undo(draft: draft, exercises: allExercises) }
                                    .accessibilityIdentifier("voice-command-undo-button")
                            }
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                            .background(DS.C.surface, in: RoundedRectangle(cornerRadius: 18))
                    }
                    if !coordinator.transcript.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("你的原話").font(.caption).foregroundStyle(DS.C.textLow)
                            Text(coordinator.transcript).font(.subheadline).textSelection(.enabled)
                                .accessibilityIdentifier("voice-command-recognized-transcript")
                            Button("編輯後重試") { inputText = coordinator.transcript; coordinator.clearClarification(); editingText = true }
                                .disabled(processing || recording)
                        }
                    }
                    if editingText || coordinator.needsClarification {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField(coordinator.needsClarification ? "補充動作或數值" : "輸入完整訓練指令", text: $inputText, axis: .vertical)
                                .focused($textFocused).lineLimit(3...8).padding(14).background(DS.C.inset, in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityIdentifier("voice-command-text-field")
                            Button(coordinator.needsClarification ? "補充並繼續" : "執行這句") {
                                textFocused = false
                                coordinator.submit(inputText, draft: draft, exercises: allExercises, clientID: clientID, context: context)
                                inputText = ""
                            }.buttonStyle(.borderedProminent)
                                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || recording || processing)
                                .accessibilityIdentifier("voice-command-submit-button")
                        }
                    } else {
                        Button("改用文字輸入") { editingText = true }
                            .accessibilityIdentifier("cloud-voice-show-text")
                    }
                    if coordinator.transcript.isEmpty {
                        Text("例如：今天建立訓練計劃，槓鈴背蹲四組八次六十公斤，再加平板支撐。\n之後可以說：剛才的背蹲第二組改成五十五公斤。")
                            .font(.footnote).foregroundStyle(DS.C.textLow)
                    }
                    NavigationLink("雲端設定", destination: CloudVoiceSettingsView())
                        .font(.footnote).accessibilityIdentifier("cloud-voice-settings-link")
                    if coordinator.hotwordCount > 0 {
                        Text("本次熱詞 \(coordinator.hotwordCount) 個 · \(coordinator.uncoveredCount) 個動作未納入本次識別詞表")
                            .font(.caption2).foregroundStyle(DS.C.textLow)
                    }
                }.padding(24)
            }.background(DS.C.canvas)
                .navigationTitle("語音安排").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { coordinator.closePanel(); dismiss() } } }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(processing || recording)
        .onChange(of: coordinator.recordingSession.finalTranscript) { _, value in
            if value != nil { coordinator.acceptRecording(draft: draft, exercises: allExercises, clientID: clientID, context: context) }
        }
        .onDisappear { coordinator.cancel() }
    }
}
