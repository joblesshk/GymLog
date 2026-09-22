import SwiftUI
import GymLogKit

/// 训练中的心率显示（2026-09-04，教练的"备选功能"）。
///
/// 平时只是顶部计时条旁边一枚窄胶囊：没连时显示「開始運動」，连上后显示实时
/// BPM 并随心跳轻微放大。点一下打开 `HeartRateSheet` 选设备 / 看本次汇总 /
/// 结束。真正的蓝牙逻辑全在 `HeartRateMonitor`（GymLogKit）里。
struct HeartRateChip: View {
    @Bindable var monitor: HeartRateMonitor
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant
    @State private var showSheet = false
    @State private var pulse = false

    var body: some View {
        Button {
            if case .idle = monitor.status {
                monitor.startSession()
            }
            showSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isLive ? DS.C.danger : DS.C.textLow)
                    .scaleEffect(pulse ? 1.18 : 1)
                    .animation(.easeInOut(duration: 0.28), value: pulse)
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(DS.C.textHi)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(DS.C.inset, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onChange(of: monitor.currentBPM) { _, newValue in
            guard newValue != nil else { return }
            pulse = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { pulse = false }
        }
        .sheet(isPresented: $showSheet) {
            HeartRateSheet(monitor: monitor)
        }
    }

    private var isLive: Bool { monitor.currentBPM != nil }

    private var label: String {
        if let bpm = monitor.currentBPM { return "\(bpm)" }
        switch monitor.status {
        case .idle: return language.t("開始運動", "Start")
        case .scanning: return language.t("搜尋中", "Scanning")
        case .connecting: return language.t("連接中", "Connecting")
        case .connected: return "--"
        case .unavailable: return language.t("不可用", "Unavailable")
        }
    }
}

/// 设备选择 + 本次课心率汇总。
struct HeartRateSheet: View {
    @Bindable var monitor: HeartRateMonitor
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    var body: some View {
        NavigationStack {
            List {
                Section {
                    liveRow
                        .listRowBackground(DS.C.surface)
                } header: {
                    Text(language.t("即時心率", "Live"))
                        .sectionLabelStyle()
                }

                if monitor.averageBPM != nil {
                    Section {
                        summaryRow
                            .listRowBackground(DS.C.surface)
                    } header: {
                        Text(language.t("本次課", "This session"))
                            .sectionLabelStyle()
                    }
                }

                if case .connected = monitor.status {} else {
                    Section {
                        if monitor.discovered.isEmpty {
                            Text(language.t("正在搜尋附近的裝置…", "Looking for nearby devices…"))
                                .font(DS.F.body)
                                .foregroundStyle(DS.C.textLow)
                                .listRowBackground(DS.C.surface)
                        }
                        ForEach(monitor.discovered) { sensor in
                            Button {
                                monitor.connect(to: sensor)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(sensor.name)
                                            .font(DS.F.listRow)
                                            .foregroundStyle(DS.C.textHi)
                                        if sensor.advertisesHeartRate {
                                            Text(language.t("心率裝置", "Heart-rate device"))
                                                .font(DS.F.subtitle)
                                                .foregroundStyle(DS.C.accent)
                                        }
                                    }
                                    Spacer()
                                    Text("\(sensor.rssi) dBm")
                                        .font(DS.F.subtitle)
                                        .monospacedDigit()
                                        .foregroundStyle(DS.C.textLow)
                                }
                            }
                            .listRowBackground(DS.C.surface)
                        }
                    } header: {
                        Text(language.t("選擇裝置", "Select a device"))
                            .sectionLabelStyle()
                    } footer: {
                        Text(language.t(
                            // CIRQA 沒有螢幕，這個開關在手機的 Garmin Connect
                            // App 裡而不是手環上——寫清楚完整路徑，不要只說
                            // 「先開啟心率廣播」。
                            "先開啟手環的「廣播心率」，它才會出現在這裡。CIRQA 沒有螢幕，開關在手機的 Garmin Connect App 裡："
                                + "選單 → Garmin 裝置 → 選 CIRQA → 健康與健身（Health & Wellness）→ 廣播心率（Broadcast Heart Rate）→ 把「狀態」打開。\n"
                                + "在同一頁順手開啟「裝置控制」，以後長按手環按鈕 3 秒就能直接開關，廣播時 LED 閃黃燈。\n"
                                + "仍然找不到手環的話，確認固件已更新到 3.20 以上（2.50 有已知的廣播故障）。廣播心率較耗電，用完可以關掉。",
                            "Turn on the band's heart-rate broadcast first, or it won't appear here. The CIRQA has no screen, so the switch is in the Garmin Connect app on your phone: "
                                + "Menu → Garmin Devices → CIRQA → Health & Wellness → Broadcast Heart Rate → turn Status on.\n"
                                + "Enable \"Device Control\" on that same page and you can then hold the band's button for 3 seconds to toggle it; the LED flashes yellow while broadcasting.\n"
                                + "If the band still doesn't show up, update its firmware to 3.20 or later — 2.50 has a known broadcast bug. Broadcasting drains the battery faster, so turn it off when you're done."
                        ))
                        .font(DS.F.subtitle)
                        .foregroundStyle(DS.C.textLow)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.C.canvas)
            .navigationTitle(language.t("心率", "Heart Rate"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.t("完成", "Done")) { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.C.textHi)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.t("結束", "Stop")) {
                        monitor.endSession()
                        dismiss()
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.C.danger)
                    .disabled(monitor.status == .idle)
                }
            }
        }
    }

    @ViewBuilder
    private var liveRow: some View {
        if case .unavailable(let message) = monitor.status {
            Text(message)
                .font(DS.F.body)
                .foregroundStyle(DS.C.danger)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(monitor.currentBPM == nil ? DS.C.textLow : DS.C.danger)
                Text(monitor.currentBPM.map(String.init) ?? "--")
                    .font(DS.F.timer())
                    .monospacedDigit()
                    .foregroundStyle(DS.C.textHi)
                Text("BPM")
                    .font(DS.F.dataUnit)
                    .foregroundStyle(DS.C.textLow)
                Spacer()
                if let name = monitor.connectedName {
                    Text(name)
                        .font(DS.F.subtitle)
                        .foregroundStyle(DS.C.textLow)
                        .lineLimit(1)
                }
            }
        }
    }

    private var summaryRow: some View {
        HStack {
            summaryCell(language.t("平均", "Avg"), monitor.averageBPM)
            Spacer()
            summaryCell(language.t("最低", "Min"), monitor.minBPM)
            Spacer()
            summaryCell(language.t("最高", "Max"), monitor.maxBPM)
        }
    }

    private func summaryCell(_ title: String, _ value: Int?) -> some View {
        VStack(spacing: 2) {
            Text(value.map(String.init) ?? "--")
                .font(DS.F.dataNumber())
                .monospacedDigit()
                .foregroundStyle(DS.C.textHi)
            Text(title)
                .font(DS.F.dataLabel)
                .foregroundStyle(DS.C.textLow)
        }
    }
}
