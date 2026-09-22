import SwiftUI
import Charts
import UIKit
import GymLogKit

/// 训练中的心率显示（2026-09-04，教练的"备选功能"；2026-09-15 设计改版）。
///
/// 平时只是顶部计时条旁边一枚窄胶囊：没连时显示「記錄心率」（原「開始運動」
/// 看不出跟心率有关——这是这轮改版唯一改动的字串），连上后心形按实际 BPM
/// 的节奏搏动、数字升为主角。点一下打开 `HeartRateSheet` 选设备 / 看本次
/// 汇总 / 结束。真正的蓝牙逻辑全在 `HeartRateMonitor`（GymLogKit）里。
struct HeartRateChip: View {
    @Bindable var monitor: HeartRateMonitor
    /// 學員年齡——僅用來估算心率區間色帶的參考上限（`220 - age`，最粗略的
    /// Fox 公式，非醫療級）。`nil`（學員沒填年齡）時面板不猜一個假上限，直
    /// 接不顯示區間色帶，而不是拿一個沒人核實過的數字誤導教練。
    var age: Int? = nil
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant
    @State private var showSheet = false
    // `isCurrentReadingStale` is a plain computed property keyed off
    // `Date()`, not an `@Observable`-tracked field -- reading it from `body`
    // does not register a dependency, so a connection that goes quiet
    // without disconnecting would never re-render this view on its own.
    // Poll it explicitly while connected instead of trusting SwiftUI to
    // notice time passing.
    @State private var isStale = false

    var body: some View {
        Button {
            if case .idle = monitor.status {
                monitor.startSession()
            }
            showSheet = true
        } label: {
            HStack(spacing: 6) {
                HeartbeatGlyph(monitor: monitor, size: 18)
                content
            }
            .padding(.horizontal, isLiveBPM ? 11 : 14)
            .padding(.vertical, 8)
            .frame(height: 44)
            .background(background, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("heart-rate-control")
        .task(id: monitor.status) { await pollStaleness() }
        .sheet(isPresented: $showSheet) {
            HeartRateSheet(monitor: monitor, age: age)
        }
    }

    @MainActor
    private func pollStaleness() async {
        guard case .connected = monitor.status else {
            isStale = false
            return
        }
        while !Task.isCancelled {
            isStale = monitor.isCurrentReadingStale
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch monitor.status {
        case .idle:
            Text(language.t("記錄心率", "Track HR"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.C.textHi)
                .lineLimit(1)
        case .scanning:
            Text(language.t("搜尋中", "Scanning"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.C.textMid)
                .lineLimit(1)
        case .connecting:
            Text(language.t("連接中", "Connecting"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.C.textMid)
                .lineLimit(1)
        case .connected:
            bpmReadout
        case .unavailable:
            Text(language.t("不可用", "Unavailable"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.C.danger)
                .lineLimit(1)
        }
    }

    private var bpmReadout: some View {
        HStack(alignment: .lastTextBaseline, spacing: 3) {
            Text(isStale ? "--" : (monitor.currentBPM.map(String.init) ?? "--"))
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(isStale ? DS.C.textLow : DS.C.textHi)
            Text("BPM")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DS.C.textLow)
        }
    }

    private var isLiveBPM: Bool {
        if case .connected = monitor.status { return true }
        return false
    }

    private var background: Color {
        switch monitor.status {
        case .connected where !isStale:
            return DS.C.heartRate.opacity(0.10)
        case .unavailable:
            return DS.C.danger.opacity(0.10)
        default:
            return DS.C.inset
        }
    }

    private var accessibilityText: String {
        switch monitor.status {
        case .idle: return language.t("點擊開始記錄心率", "Tap to start tracking heart rate")
        case .scanning: return language.t("搜尋心率裝置中", "Scanning for a heart-rate device")
        case .connecting: return language.t("連接心率裝置中", "Connecting to heart-rate device")
        case .connected:
            if isStale {
                return language.t("心率訊號中斷", "Heart-rate signal lost")
            }
            let bpm = monitor.currentBPM.map(String.init) ?? "--"
            return language.t("心率 \(bpm) BPM", "Heart rate \(bpm) BPM")
        case .unavailable: return language.t("心率不可用", "Heart rate unavailable")
        }
    }
}

/// 跳動的心形圖示——胶囊 18-20pt、面板 hero 52pt 共用同一套狀態機：
/// 閒置＝空心；搜尋中＝空心 + 1.4s 慢速呼吸；連接中＝半透明實心、靜止；
/// 已連接＝實心 + 按 `60/BPM` 秒一次的搏動（HANDOFF.md §2 動效規格：scale
/// 1→1.18(12%,easeOut)→1.02→1.09→1，`easeInOut`）；訊號中斷（新狀態，
/// `monitor.isCurrentReadingStale`——數據仍是 `.connected` 但 10 秒沒有新樣
/// 本，比如貼合鬆脫）＝ `heart.slash`、停止搏動；不可用＝空心 + danger 色。
/// 「減少動態效果」開啟時完全不做縮放，只用顏色 + 圖示區分狀態。
struct HeartbeatGlyph: View {
    let monitor: HeartRateMonitor
    var size: CGFloat = 18

    @State private var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: iconName)
            .font(.system(size: size * 0.72, weight: .semibold))
            .foregroundStyle(color)
            .opacity(opacity)
            .frame(width: size, height: size)
            .scaleEffect(reduceMotion ? 1 : scale)
            .task(id: taskKey) { await runLoop() }
    }

    /// 状态机的关键节点变化时重启循环；`currentBPM` 本身的抖动不重启（循环
    /// 内部每一拍都会重新读取最新 BPM，节奏自然跟上变化）。
    private var taskKey: String {
        switch monitor.status {
        case .connected: return "connected"
        case .scanning: return "scanning"
        default: return "idle"
        }
    }

    private var iconName: String {
        switch monitor.status {
        case .idle, .scanning: return "heart"
        case .connecting: return "heart.fill"
        case .connected: return monitor.isCurrentReadingStale ? "heart.slash" : "heart.fill"
        case .unavailable: return "heart"
        }
    }

    private var color: Color {
        switch monitor.status {
        case .idle, .scanning: return DS.C.textLow
        case .connecting: return DS.C.heartRate
        case .connected: return monitor.isCurrentReadingStale ? DS.C.textLow : DS.C.heartRate
        case .unavailable: return DS.C.danger
        }
    }

    private var opacity: Double {
        if case .connecting = monitor.status { return 0.45 }
        return 1
    }

    @MainActor
    private func runLoop() async {
        guard !reduceMotion else { return }
        switch monitor.status {
        case .scanning:
            await breathe()
        case .connected:
            await beat()
        default:
            scale = 1
        }
    }

    /// 搜尋中的緩慢呼吸：1.4s 一次，`hb` 曲線但只取第一個波峰做簡化。
    private func breathe() async {
        while !Task.isCancelled {
            withAnimation(.easeInOut(duration: 0.7)) { scale = 1.12 }
            try? await sleep(0.7)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.7)) { scale = 1 }
            try? await sleep(0.7)
        }
    }

    /// 已連接的搏動：週期 = 60 / BPM 秒，曲線見上方文檔註解。BPM 尚未到位
    /// （剛連上、還沒收到第一筆）或訊號中斷時只是等待，不搏動。
    private func beat() async {
        while !Task.isCancelled {
            guard !monitor.isCurrentReadingStale, let bpm = monitor.currentBPM, bpm > 0 else {
                scale = 1
                try? await sleep(0.3)
                continue
            }
            let cycle = 60.0 / Double(bpm)
            withAnimation(.easeOut(duration: cycle * 0.12)) { scale = 1.18 }
            try? await sleep(cycle * 0.12)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: cycle * 0.14)) { scale = 1.02 }
            try? await sleep(cycle * 0.14)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: cycle * 0.12)) { scale = 1.09 }
            try? await sleep(cycle * 0.12)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: cycle * 0.17)) { scale = 1 }
            try? await sleep(cycle * 0.45)
        }
    }

    private func sleep(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// 三格訊號強度條，6/9/12pt 遞增高度；用相對 RSSI 門檻決定點亮幾格，弱訊號
/// 只亮第一格。沒有官方訊號分級標準，門檻是常見的藍牙 RSSI 經驗值。
private struct SignalBars: View {
    let rssi: Int
    var tint: Color = DS.C.textLow

    private var litCount: Int {
        if rssi >= -65 { return 3 }
        if rssi >= -80 { return 2 }
        return 1
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < litCount ? tint : DS.C.hairline)
                    .frame(width: 3, height: 6 + CGFloat(index) * 3)
            }
        }
    }
}

/// 设备选择 + 本次课心率汇总。以即時 BPM 為主體重做：大數字 + 心臟 hero、
/// 本次課平均/最低/最高、裝置列表帶訊號強度，手環設定說明摺疊進可展開列
/// （2026-09-15 設計改版 §2；沿用原字串：搜尋中/連接中/不可用/即時心率/
/// 本次課/平均/最低/最高/選擇裝置/心率裝置/完成/結束）。
struct HeartRateSheet: View {
    @Bindable var monitor: HeartRateMonitor
    var age: Int? = nil
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant
    @State private var showingSetupGuide = false
    // Same reasoning as `HeartRateChip`: `isCurrentReadingStale` doesn't
    // participate in `@Observable` tracking, so poll it explicitly.
    @State private var isStale = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    heroCard
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } header: {
                    Text(language.t("即時心率", "Live"))
                        .sectionLabelStyle()
                }

                if monitor.averageBPM != nil {
                    Section {
                        summaryCard
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    } header: {
                        Text(language.t("本次課", "This session"))
                            .sectionLabelStyle()
                    }
                }

                if case .connected = monitor.status, let name = monitor.connectedName {
                    Section {
                        connectedDeviceRow(name: name)
                    } header: {
                        Text(language.t("裝置", "Device"))
                            .sectionLabelStyle()
                    }
                } else {
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
                                deviceRow(name: sensor.name, rssi: sensor.rssi, advertisesHeartRate: sensor.advertisesHeartRate, isConnected: false)
                            }
                            .listRowBackground(DS.C.surface)
                        }
                    } header: {
                        Text(language.t("選擇裝置", "Select a device"))
                            .sectionLabelStyle()
                    }
                }

                Section {
                    DisclosureGroup(isExpanded: $showingSetupGuide) {
                        Text(setupGuideText)
                            .font(DS.F.subtitle)
                            .foregroundStyle(DS.C.textLow)
                            .padding(.top, 6)
                    } label: {
                        Text(language.t("找不到手環？設定說明", "Can't find your band? Setup guide"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DS.C.textMid)
                    }
                    .listRowBackground(DS.C.surface)
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
        .task(id: monitor.status) { await pollStaleness() }
    }

    @MainActor
    private func pollStaleness() async {
        guard case .connected = monitor.status else {
            isStale = false
            return
        }
        while !Task.isCancelled {
            isStale = monitor.isCurrentReadingStale
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: - Hero (即時心率)

    @ViewBuilder
    private var heroCard: some View {
        if case .unavailable(let message) = monitor.status {
            Text(message)
                .font(DS.F.body)
                .foregroundStyle(DS.C.danger)
                .padding(DS.Space.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .gymCard()
                .padding(.horizontal, DS.Space.pageMargin)
        } else {
            VStack(spacing: 10) {
                HStack(alignment: .center, spacing: 14) {
                    HeartbeatGlyph(monitor: monitor, size: 52)
                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Text(bpmDisplayText)
                            .font(.system(size: 64, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DS.C.textHi)
                            .tracking(-1)
                        Text("BPM")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DS.C.textLow)
                    }
                }
                connectionCaption
                heartRateZoneBand(bpm: liveBPMForZone)
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .gymCard()
            .padding(.horizontal, DS.Space.pageMargin)
        }
    }

    private var bpmDisplayText: String {
        guard case .connected = monitor.status, !isStale else { return "--" }
        return monitor.currentBPM.map(String.init) ?? "--"
    }

    /// 只在「已連接、有實際樣本、且教練填過年齡」時才有一個站得住腳的
    /// 即時 BPM 可以拿去定位區間——其餘狀態（未連、訊號中斷）色帶沒有
    /// 意義，寧可不顯示。
    private var liveBPMForZone: Int? {
        guard case .connected = monitor.status, !isStale else { return nil }
        return monitor.currentBPM
    }

    // MARK: - 心率區間色帶 (GymLog 改版設計 §2)

    private enum HRZone: Int, CaseIterable {
        case z1, z2, z3, z4, z5

        /// 5 區間各佔的寬度比例（總和 = 1），對應設計稿的 1:1:1:1.2:1。
        var widthWeight: Double { self == .z4 ? 1.2 : 1 }

        /// 這個區間的下界，佔估算最大心率的比例；上界是下一區間的下界
        /// （Z5 封頂到 1.0 以上，超過封頂一律算 Z5）。常見的 5 區間模型
        /// （50/60/70/80/90% of HRmax），非醫療級、僅供訓練參考。
        var lowerBound: Double {
            switch self {
            case .z1: return 0.5
            case .z2: return 0.6
            case .z3: return 0.7
            case .z4: return 0.8
            case .z5: return 0.9
            }
        }

        var label: (zh: String, en: String) {
            switch self {
            case .z1: return ("Z1", "Z1")
            case .z2: return ("Z2", "Z2")
            case .z3: return ("Z3", "Z3")
            case .z4: return ("Z4 · 無氧", "Z4 · Anaerobic")
            case .z5: return ("Z5", "Z5")
            }
        }

        var color: Color {
            switch self {
            case .z1: return Color(red: 0.863, green: 0.890, blue: 0.855) // #DCE3DA
            case .z2: return Color(red: 0.749, green: 0.827, blue: 0.769) // #BFD3C4
            case .z3: return Color(red: 0.910, green: 0.788, blue: 0.541) // #E8C98A
            case .z4: return Color(red: 0.871, green: 0.604, blue: 0.416) // #DE9A6A
            case .z5: return DS.C.heartRate
            }
        }
    }

    /// `220 - age`（Fox 公式）——最粗略的估算。教練填過學員年齡時用真實年齡；
    /// 沒填時退回 30 歲（190）當預設參考值，而不是整條色帶都不顯示——
    /// 2026-09-16：色帶本身是設計稿明確要求「常駐顯示」的區間對照表，跟今天
    /// 是誰、連沒連上心率帶無關，不能因為學員檔案漏填一個欄位就完全消失。
    private static let defaultAgeForZoneEstimate = 30
    private var estimatedMaxHR: Double {
        let effectiveAge = (age.map { $0 > 0 ? $0 : nil } ?? nil) ?? Self.defaultAgeForZoneEstimate
        return Double(220 - effectiveAge)
    }

    private func zone(forRatio ratio: Double) -> HRZone {
        HRZone.allCases.last { ratio >= $0.lowerBound } ?? .z1
    }

    /// `bpm` 為 `nil`（未連接/訊號中斷/教練還沒實測）時，色帶本身仍然顯示
    /// 當作固定的區間對照表——只是不畫指針、也不特別加粗哪個區間文字。這樣
    /// 教練沒接心率帶也能先看到「Z1–Z5 分別是什麼」，不必等真的連上裝置。
    @ViewBuilder
    private func heartRateZoneBand(bpm: Int?) -> some View {
        let maxHR = estimatedMaxHR
        let ratio = bpm.map { Double($0) / maxHR }
        let currentZone = ratio.map(zone(forRatio:))
        let totalWeight = HRZone.allCases.reduce(0) { $0 + $1.widthWeight }
        // 2026-09-16 第二次修正：先前兩版（`GeometryReader`、自訂 `Layout`）
        // 都靠 SwiftUI 的佈局協商去量這張卡片的實際寬度，教練這裡雖然沒回報
        // 「還是不見了」，但跟身體組成那條比例條是同一個元件模式、同一個
        // `List`/`.sheet` 情境——與其等下一輪才發現同樣的問題，直接一併換成
        // 跟比例條一致的作法：`UIScreen.main.bounds.width` 扣掉已知的外層
        // padding，在建構時就算出確定寬度，色段跟指針都用這個常數算絕對
        // 位置，不再經過任何容器測量。
        let bandWidth = UIScreen.main.bounds.width - 2 * DS.Space.pageMargin - 2 * 14
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .leading) {
                HStack(spacing: 2) {
                    ForEach(HRZone.allCases, id: \.self) { z in
                        Capsule().fill(z.color)
                            .frame(width: Self.hrSegmentWidth(z.widthWeight, totalWeight: totalWeight, bandWidth: bandWidth))
                    }
                }
                if let ratio {
                    let fraction = pointerFraction(ratio: ratio, totalWeight: totalWeight)
                    Capsule()
                        .fill(DS.C.textHi)
                        .frame(width: 4, height: 20)
                        .offset(x: min(max(0, bandWidth * fraction - 2), bandWidth - 4), y: -5)
                }
            }
            .frame(width: bandWidth, height: 10)
            HStack {
                ForEach(HRZone.allCases, id: \.self) { z in
                    Text(language.t(z.label.zh, z.label.en))
                        .font(.system(size: 10, weight: z == currentZone ? .semibold : .regular))
                        .foregroundStyle(z == currentZone ? DS.C.textHi : DS.C.textLow)
                    if z != .z5 { Spacer() }
                }
            }
            .frame(width: bandWidth)
        }
        .padding(.top, 6)
    }

    private static func hrSegmentWidth(_ weight: Double, totalWeight: Double, bandWidth: CGFloat) -> CGFloat {
        let spacing: CGFloat = 2
        let usable = max(0, bandWidth - spacing * CGFloat(HRZone.allCases.count - 1))
        return usable * (weight / totalWeight)
    }

    private func pointerFraction(ratio: Double, totalWeight: Double) -> Double {
        let clamped = max(HRZone.z1.lowerBound, min(ratio, 1.15))
        var accumulated: Double = 0
        for z in HRZone.allCases {
            let nextLower = HRZone(rawValue: z.rawValue + 1)?.lowerBound ?? 1.15
            if clamped < nextLower || z == .z5 {
                let span = nextLower - z.lowerBound
                let within = span > 0 ? (clamped - z.lowerBound) / span : 0
                return (accumulated + within * z.widthWeight) / totalWeight
            }
            accumulated += z.widthWeight
        }
        return 1
    }

    private var connectionCaption: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(connectionDotColor)
                .frame(width: 8, height: 8)
            Text(connectionCaptionText)
                .font(.system(size: 13))
                .foregroundStyle(DS.C.textMid)
        }
    }

    private var connectionDotColor: Color {
        switch monitor.status {
        case .connected: return isStale ? DS.C.textLow : DS.C.review
        case .scanning, .connecting: return DS.C.textLow
        default: return DS.C.hairline
        }
    }

    private var connectionCaptionText: String {
        switch monitor.status {
        case .idle: return language.t("尚未連接", "Not connected")
        case .scanning: return language.t("搜尋中", "Scanning")
        case .connecting: return language.t("連接中", "Connecting")
        case .connected:
            if isStale {
                return language.t("訊號中斷", "Signal lost")
            }
            let name = monitor.connectedName ?? "--"
            return language.t("已連接 · \(name)", "Connected · \(name)")
        case .unavailable: return language.t("不可用", "Unavailable")
        }
    }

    // MARK: - Summary (本次課)

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                summaryCell(language.t("平均", "Avg"), monitor.averageBPM)
                summaryCell(language.t("最低", "Min"), monitor.minBPM)
                summaryCell(language.t("最高", "Max"), monitor.maxBPM)
            }
            if monitor.samples.count >= 2 {
                sessionTrendChart
            }
        }
        .padding(.horizontal, DS.Space.pageMargin)
    }

    /// 本次課心率走勢（GymLog 改版設計 §2，標註為可選；現在有
    /// `HeartRateMonitor.samples` 逐秒記錄可畫）。橫軸是經過秒數，不是絕對時
    /// 鐘時間——教練關心的是「訓練到第幾分鐘心率怎麼變化」，不是幾點幾分。
    private var sessionTrendChart: some View {
        let bpmValues = monitor.samples.map { Double($0.bpm) }
        let minV = bpmValues.min() ?? 0
        let maxV = bpmValues.max() ?? 0
        let padding = Swift.max((maxV - minV) * 0.15, 3)
        return VStack(alignment: .leading, spacing: 2) {
            Chart(monitor.samples, id: \.elapsedSeconds) { sample in
                LineMark(
                    x: .value("elapsed", sample.elapsedSeconds),
                    y: .value("bpm", sample.bpm)
                )
                .foregroundStyle(DS.C.heartRate)
                .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                .interpolationMethod(.monotone)
            }
            .chartYScale(domain: (minV - padding)...(maxV + padding))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 60)
            HStack {
                Text(Self.formatElapsed(monitor.samples.first?.elapsedSeconds ?? 0))
                Spacer()
                Text(language.t("本次課走勢", "This session's trend"))
                    .foregroundStyle(DS.C.textMid)
                Spacer()
                Text(Self.formatElapsed(monitor.samples.last?.elapsedSeconds ?? 0))
            }
            .font(.system(size: 10))
            .foregroundStyle(DS.C.textLow)
        }
    }

    private static func formatElapsed(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func summaryCell(_ title: String, _ value: Int?) -> some View {
        VStack(spacing: 5) {
            Text(value.map(String.init) ?? "--")
                .font(DS.F.dataNumber())
                .monospacedDigit()
                .foregroundStyle(DS.C.textHi)
            Text(title)
                .font(DS.F.dataUnit)
                .foregroundStyle(DS.C.textLow)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(DS.C.inset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Devices

    private func connectedDeviceRow(name: String) -> some View {
        let known = monitor.discovered.first(where: { $0.name == name })
        return deviceRow(
            name: name,
            rssi: known?.rssi,
            advertisesHeartRate: known?.advertisesHeartRate ?? true,
            isConnected: true
        )
        .listRowBackground(DS.C.surface)
    }

    private func deviceRow(name: String, rssi: Int?, advertisesHeartRate: Bool, isConnected: Bool) -> some View {
        HStack {
            HStack(spacing: 10) {
                Circle()
                    .fill(isConnected ? DS.C.review : DS.C.hairline)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(isConnected ? .system(size: 15, weight: .semibold) : DS.F.listRow)
                        .foregroundStyle(DS.C.textHi)
                    if advertisesHeartRate {
                        Text(language.t("心率裝置", "Heart-rate device"))
                            .font(DS.F.subtitle)
                            .foregroundStyle(DS.C.accent)
                    }
                }
            }
            Spacer()
            if let rssi {
                HStack(spacing: 8) {
                    Text("\(rssi) dBm")
                        .font(DS.F.subtitle)
                        .monospacedDigit()
                        .foregroundStyle(DS.C.textLow)
                    SignalBars(rssi: rssi, tint: isConnected ? DS.C.review : DS.C.textLow)
                }
            }
        }
        .frame(minHeight: 52)
    }

    private var setupGuideText: String {
        language.t(
            // CIRQA 沒有螢幕，這個開關在手機的 Garmin Connect App 裡——寫清楚完整路徑，不要只說
            // 「先開啟心率廣播」。
            "先開啟手環的「廣播心率」，它才會出現在這裡。CIRQA 沒有螢幕，開關在手機的 Garmin Connect App 裡："
                + "選單 → Garmin 裝置 → 選 CIRQA → 健康與健身（Health & Wellness）→ 廣播心率（Broadcast Heart Rate）→ 把「狀態」打開。\n"
                + "在同一頁順手開啟「裝置控制」，以後長按手環按鈕 3 秒就能直接開關，廣播時 LED 閃黃燈。\n"
                + "仍然找不到手環的話，確認固件已更新到 3.20 以上（2.50 有已知的廣播故障）。廣播心率較耗電，用完可以關掉。",
            "Turn on the band's heart-rate broadcast first, or it won't appear here. The CIRQA has no screen, so the switch is in the Garmin Connect app on your phone: "
                + "Menu → Garmin Devices → CIRQA → Health & Wellness → Broadcast Heart Rate → turn Status on.\n"
                + "Enable \"Device Control\" on that same page and you can then hold the band's button for 3 seconds to toggle it; the LED flashes yellow while broadcasting.\n"
                + "If the band still doesn't show up, update its firmware to 3.20 or later — 2.50 has a known broadcast bug. Broadcasting drains the battery faster, so turn it off when you're done."
        )
    }
}
