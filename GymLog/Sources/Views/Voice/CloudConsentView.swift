import SwiftUI
import GymLogKit

/// Shown before the first cloud request (voice planning or AI review). Names what is sent and to
/// whom, as App Review Guideline 5.1.2(i) requires for third-party AI services.
struct CloudConsentView: View {
    let onAgree: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(L("使用雲端 AI 前", "Before Using Cloud AI"), systemImage: "hand.raised.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(DS.C.textHi)
            Text(L("語音安排和 AI 訓練評價需要把資料傳送到第三方服務處理。同意前不會傳送任何內容。",
                   "Voice planning and AI training review send data to third-party services. Nothing is sent until you agree."))
                .font(.subheadline)
                .foregroundStyle(DS.C.textMid)
            item(L("會傳送的內容", "What is sent"),
                 L("語音安排：你的錄音或輸入的文字、動作庫名稱，以及今天的訓練計劃與記錄。\nAI 評價：這節課和最近幾節課的計劃與實際成績、訓練目標、估算用的體重，以及熱身、放鬆和訓練塊備註（備註可能寫有傷痛或身體狀況）。\n不會主動傳送學員姓名、電話或完整病史。",
                   "Voice planning: your recording or typed text, exercise names, and today's plan and results.\nAI review: planned and recorded results for this and recent sessions, the training goal, body weight used for estimates, and warm-up, cool-down and block notes (notes may mention pain or health conditions).\nClient names, phone numbers and full medical history are not sent."))
            item(L("接收方", "Who receives it"),
                 L("資料經 Cloudflare 中轉；語音由火山引擎（字節跳動）識別，文字理解和評價由 DeepSeek 生成。這些服務可能在中國大陸處理資料，並按各自政策保留記錄。",
                   "Data is relayed through Cloudflare; speech is recognized by Volcengine (ByteDance) and text is interpreted and reviewed by DeepSeek. These services may process data in mainland China and retain it under their own policies."))
            item(L("用途", "Purpose"),
                 L("只用於把語音轉成訓練安排和生成訓練評價，不用於廣告或追蹤。錄音不會在本機長期保存。",
                   "Only to turn speech into training plans and to generate reviews — never for advertising or tracking. Recordings are not kept on this device."))
            item(L("你的選擇", "Your choice"),
                 L("可隨時在「設置 › 雲端語音」撤回同意。不同意也能照常記錄訓練和查看熱量估算。錄入學員資料前，請確認已取得學員同意。",
                   "You can withdraw at any time in Settings › Cloud Voice. Without agreeing you can still log training and see energy estimates. Make sure your clients have agreed before you enter their information."))
            VStack(spacing: 10) {
                Button(action: onAgree) {
                    Text(L("同意並繼續", "Agree and Continue")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("cloud-consent-agree")
                Button(L("暫不使用", "Not Now"), action: onDecline)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("cloud-consent-decline")
            }
            .padding(.top, 4)
        }
    }

    private func item(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(DS.C.textLow)
            Text(text).font(.subheadline).foregroundStyle(DS.C.textHi)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
