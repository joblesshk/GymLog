import SwiftUI
import GymLogKit

struct CloudVoiceSettingsView: View {
    @State private var config = CloudVoiceConfiguration.load()
    @State private var message = ""
    @State private var checking = false
    var body: some View {
        Form {
            Section("自備雲端服務") {
                Label(CloudRelaySession.isConfigured ? "已設定服務地址" : "尚未設定服務地址", systemImage: "network")
                Text("此版本不附帶雲端服務。請依專案部署說明設定自己的服務地址，並將供應商密鑰保存在服務端。離線記錄和熱量估算不受影響。")
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
            Section("資料處理") {
                Text("錄音、轉寫文字及訓練上下文經 Cloudflare 中轉至語音識別和文字理解服務。錄音不在本機長期保存。供應商密鑰保存在服務端，不會下載至你的手機。")
                    .font(.footnote)
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
    }
}
