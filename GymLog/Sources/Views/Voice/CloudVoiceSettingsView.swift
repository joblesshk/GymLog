import SwiftUI
import GymLogKit

struct CloudVoiceSettingsView: View {
    @State private var config = CloudVoiceConfiguration.load()
    @State private var message = ""
    @State private var checking = false
    @State private var consented = CloudDataConsent.isGranted
    @State private var showingConsent = false
    private let configured = CloudRelaySession.isConfigured
    var body: some View {
        Form {
            // Builds without a relay address are self-hosted checkouts; App Store builds ship one.
            Section(configured ? L("雲端服務", "Cloud Service") : L("自備雲端服務", "Self-Hosted Service")) {
                Label(configured ? L("已連接 GymLog 雲端服務", "GymLog cloud service available") : L("尚未設定服務地址", "No service address set"), systemImage: "network")
                Text(configured
                     ? L("語音安排和 AI 訓練評價需要網絡連接。離線記錄和熱量估算不受影響。",
                         "Voice planning and AI training review need a network connection. Offline logging and energy estimates are unaffected.")
                     : L("此版本不附帶雲端服務。請依專案部署說明設定自己的服務地址，並將供應商密鑰保存在服務端。離線記錄和熱量估算不受影響。",
                         "This build has no cloud service. Follow the project's deployment guide to set your own service address and keep provider keys on the server. Offline logging and energy estimates are unaffected."))
                    .font(.footnote)
                Button(checking ? "正在檢查…" : "檢查連接") {
                    checking = true
                    Task {
                        do {
                            let usage = try await CloudRelaySession.shared.usage()
                            let reset = Date(timeIntervalSince1970: usage.resetsAt).formatted(date: .abbreviated, time: .shortened)
                            message = "本月已用 \(usage.used)／\(usage.limit) 條，剩餘 \(usage.remaining) 條。下次重置：\(reset)。"
                        } catch { message = "暫時無法連接，請檢查網絡後重試。" }
                        checking = false
                    }
                }.disabled(checking || !CloudRelaySession.isConfigured).accessibilityIdentifier("cloud-voice-check-connection")
                if !message.isEmpty { Text(message).font(.footnote) }
            }
            Section(L("資料處理", "Data Handling")) {
                Text(L("錄音、轉寫文字及訓練上下文經 Cloudflare 中轉，由火山引擎（字節跳動）識別語音、DeepSeek 理解指令和生成評價；這些服務可能在中國大陸處理資料。錄音不在本機長期保存。供應商密鑰保存在服務端，不會下載至你的手機。",
                       "Recordings, transcripts and training context are relayed through Cloudflare; Volcengine (ByteDance) recognizes speech and DeepSeek interprets commands and writes reviews. These services may process data in mainland China. Recordings are not kept on this device, and provider keys stay on the server."))
                    .font(.footnote)
                LabeledContent(L("同意狀態", "Consent"), value: consented ? L("已同意", "Agreed") : L("未同意", "Not agreed"))
                if consented {
                    Button(L("撤回同意", "Withdraw Consent"), role: .destructive) { CloudDataConsent.revoke(); consented = false }
                        .accessibilityIdentifier("cloud-consent-withdraw")
                } else {
                    Button(L("查看說明並同意", "Review and Agree")) { showingConsent = true }
                        .accessibilityIdentifier("cloud-consent-review")
                }
            }
            Section {
                Stepper("最多注入 \(config.hotwordLimit) 個熱詞", value: $config.hotwordLimit, in: 50...2000, step: 50)
                Button("保存設定") {
                    do { try config.save(); message = "已保存" }
                    catch { message = "無法保存，請重試。" }
                }.accessibilityIdentifier("cloud-voice-save-settings")
            } header: { Text("進階") } footer: {
                Text("熱詞取自完整動作庫。每次提交雲端處理計一條；語音識別與後續理解不重複扣額度。提交後取消或失敗仍計入，檢查連接不扣額度。每月按香港時間重置。")
            }
        }
        .navigationTitle("雲端連接")
        .sheet(isPresented: $showingConsent) {
            ScrollView {
                CloudConsentView(onAgree: { CloudDataConsent.grant(); consented = true; showingConsent = false },
                                 onDecline: { showingConsent = false })
                    .padding(24)
            }
            .background(DS.C.canvas)
        }
    }
}
