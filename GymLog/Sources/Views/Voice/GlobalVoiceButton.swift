import SwiftUI
import GymLogKit

/// 2026-09-13 全局語音改造：語音入口從「今天頁添加動作區域裡的一顆小
/// 按鈕」升級成 App 全局常駐入口——`ContentView` 在悬浮 `FloatingTabBar`
/// 上方疊一顆獨立的圓形麥克風按鈕，今天/學員/歷史/動作庫/設置五個主要
/// 頁面都能看到、點到，不綁定在任何單一頁面的佈局裡（執行 Prompt
/// §4.1「語音不再藏在添加動作下的小按鈕裡；需要全局入口」）。
///
/// 52pt 圓形——落在建議的 52–56pt 區間下緣，跟 `FloatingTabBar` 自身的
/// 圖標尺寸（21pt）與胶囊高度視覺上協調，不會比整條悬浮 Tab Bar 還顯眼。
struct GlobalVoiceButton: View {
    let coordinator: CloudVoiceController

    var body: some View {
        Button {
            coordinator.openPanel()
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(DS.C.onAccent)
                .frame(width: 52, height: 52)
                .background(DS.C.accent, in: Circle())
                .overlay(Circle().stroke(DS.C.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("global-voice-button")
        .accessibilityLabel(Text(LanguageContext.current.t("語音指令", "Voice Command")))
    }
}
