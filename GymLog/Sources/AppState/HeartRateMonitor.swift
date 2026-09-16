import CoreBluetooth
import Foundation
import Observation

/// 训练中的实时心率（2026-09-04，教练的"备选功能"）。
///
/// ## 为什么这条路走得通
/// 教练用的 Garmin CIRQA 支持把心率作为标准 BLE 心率带向外广播。CIRQA 是无屏
/// 手环，这个开关**不在手环上**，在手机的 Garmin Connect App 里：選單 →
/// Garmin 裝置 → CIRQA → 健康與健身 → 廣播心率 → 狀態。（对外广播给第三方
/// App 是免费的；被 Connect+ 订阅挡住的是"在 Garmin Connect App 内查看实时
/// 心率"，与这里无关。）一旦开启，它就是一个再普通不过的
/// Bluetooth SIG Heart Rate Service（`0x180D`）外设，iOS 这边用 CoreBluetooth
/// 直接订阅 Heart Rate Measurement 特征（`0x2A37`）即可，不需要 Garmin 的
/// Health API、不需要 Connect IQ、也不需要 Garmin Connect 在后台运行。
///
/// ## 两个必须绕开的坑
/// 1. **CIRQA 的广告包里不声明 `0x180D`**，它以一个普通 Garmin 设备的身份广
///    播（这正是它在部分设备上配不上的原因）。所以这里 **不能** 用
///    `scanForPeripherals(withServices: [heartRateService])` ——那样永远扫不到
///    它。必须传 `nil` 全量扫描，再按"广告包声明了心率服务 **或** 有设备名"
///    过滤，让教练自己从列表里点自己的手环。
/// 2. **固件版本**：CIRQA 2.50 曾经把 BLE 心率广播弄坏过，3.20 修回来了。连不
///    上时先让教练确认手环固件和"心率广播"开关，而不是怀疑 App。
///
/// ## 权限
/// 首次 `startSession()` 时才创建 `CBCentralManager`，所以蓝牙权限弹窗出现在
/// 教练主动点"开始运动"的那一刻，而不是 App 一启动就弹。
///
/// 心率只用于训练过程中的实时显示与本次课的汇总，**不写进 SwiftData**——
/// CONTRACT.md 的数据模型没有心率字段，本轮也不动它。
@Observable
public final class HeartRateMonitor: NSObject {

    public static let heartRateService = CBUUID(string: "180D")
    public static let heartRateMeasurement = CBUUID(string: "2A37")

    /// 上次连上的外设，下次"开始运动"时优先自动重连，省掉每次都要选一遍。
    private static let rememberedPeripheralKey = "heartRateMonitor.lastPeripheralID"

    public enum Status: Equatable {
        case idle
        case scanning
        case connecting
        case connected
        /// 蓝牙关着 / 没授权 / 连接失败，`message` 直接拿去展示。
        case unavailable(String)
    }

    public struct DiscoveredSensor: Identifiable, Equatable {
        public let id: UUID
        public let name: String
        public let rssi: Int
        /// 广告包里明确声明了心率服务——这类设备排在列表前面。
        public let advertisesHeartRate: Bool
    }

    public private(set) var status: Status = .idle
    public private(set) var discovered: [DiscoveredSensor] = []
    public private(set) var connectedName: String?

    public private(set) var currentBPM: Int?
    public private(set) var minBPM: Int?
    public private(set) var maxBPM: Int?
    /// When the last valid sample was recorded (2026-09-07 审阅 B09: "显示
    /// 最新数据时间，过期 BPM 不再当'实时'"). `isStale`/`isCurrentReadingStale`
    /// below are the pure decision this feeds; the UI is responsible for
    /// re-checking it periodically (this property itself does not
    /// self-clear `currentBPM` on a timer).
    public private(set) var lastSampleAt: Date?
    /// 本次课到目前为止的平均心率（每收到一个采样点就并进去，不保留全部样本）。
    public var averageBPM: Int? {
        guard sampleCount > 0 else { return nil }
        return Int((Double(sampleSum) / Double(sampleCount)).rounded())
    }

    private var sampleSum = 0
    private var sampleCount = 0

    /// 2026-09-16 設計改版 §2：本次課走勢圖需要的逐點記錄——`averageBPM`
    /// 那套只並總和/計數，畫不出線。`elapsedSeconds` 相對 `sessionStartedAt`，
    /// 而不是絕對時間戳，圖表橫軸直接就是「第幾秒」，不用再減一次。一節課
    /// 心率帶通常 1 秒發一次樣本，兩三個小時封頂也就一萬多個 `(Int, Int)`，
    /// 用不著降採樣或設上限。
    public struct HeartRateSample: Equatable {
        public let elapsedSeconds: Int
        public let bpm: Int
    }
    public private(set) var samples: [HeartRateSample] = []
    private var sessionStartedAt: Date?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    /// `startSession()` 在蓝牙还没 poweredOn 时被调用的话，扫描要推迟到
    /// `centralManagerDidUpdateState` 里再发起。
    private var wantsScan = false

    // 2026-09-06 审查报告 #7：不支持心率的设备会陷入"连接—发现无服务—主动断
    // 开—`didDisconnectPeripheral` 只看 `wantsScan` 就重连—再次无服务"的死循环。
    /// 我们自己因为"没有心率服务"而主动断开的外设 id——它的断开回调不能触发
    /// 自动重连，否则就是上面的循环。
    private var rejectingPeripheralID: UUID?
    /// 连续重连失败次数，超过上限就停下来把状态交给教练，而不是无限重试。
    private var reconnectAttempts = 0
    private static let maxReconnectAttempts = 3
    /// `central.connect` 本身没有超时参数——CoreBluetooth 会无限等待。加一个
    /// 应用层超时，卡住的连接也能被判定失败、计入上面的重试上限。
    private static let connectTimeout: TimeInterval = 15
    private var connectTimeoutWorkItem: DispatchWorkItem?

    // MARK: - Session control

    /// 教练点「開始運動」。重置本次课的心率统计，然后开始找手环。
    public func startSession() {
        currentBPM = nil
        minBPM = nil
        maxBPM = nil
        sampleSum = 0
        sampleCount = 0
        samples = []
        sessionStartedAt = Date()
        discovered = []
        wantsScan = true
        reconnectAttempts = 0
        rejectingPeripheralID = nil

        // 回调队列指定成主队列：这个类的所有状态都直接驱动 SwiftUI，让
        // CoreBluetooth 直接在主线程回调，省掉一层手写的线程跳转。
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
            return // poweredOn 之后由 centralManagerDidUpdateState 接手
        }
        beginScanIfPossible()
    }

    /// 教练点「結束」。断开连接，但保留本次课的 min/max/avg 供收尾查看。
    public func endSession() {
        wantsScan = false
        rejectingPeripheralID = nil
        cancelConnectTimeout()
        central?.stopScan()
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        connectedName = nil
        currentBPM = nil
        status = .idle
    }

    public func connect(to sensor: DiscoveredSensor) {
        guard let central,
              let target = central.retrievePeripherals(withIdentifiers: [sensor.id]).first
        else { return }
        central.stopScan()
        reconnectAttempts = 0
        startConnecting(target, displayName: sensor.name)
    }

    /// Shared by manual selection, saved-peripheral auto-reconnect, and
    /// unexpected-disconnect auto-reconnect, so all three get the same
    /// connect-timeout safety net (审查报告 #7).
    private func startConnecting(_ target: CBPeripheral, displayName: String?) {
        guard let central else { return }
        peripheral = target
        target.delegate = self
        status = .connecting
        connectedName = displayName ?? target.name
        scheduleConnectTimeout(for: target)
        central.connect(target, options: nil)
    }

    private func scheduleConnectTimeout(for target: CBPeripheral) {
        connectTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.handleConnectTimeout(for: target)
        }
        connectTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeout, execute: workItem)
    }

    private func cancelConnectTimeout() {
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
    }

    private func handleConnectTimeout(for target: CBPeripheral) {
        guard peripheral === target else { return }
        central?.cancelPeripheralConnection(target)
        registerReconnectFailure(message: L("連接逾時，請確認手環已開啟心率廣播", "Connection timed out — check that heart-rate broadcast is on"))
    }

    /// Counts one failed connection attempt against `maxReconnectAttempts`;
    /// once exhausted, stops trying instead of looping forever and hands
    /// the coach an explicit message.
    private func registerReconnectFailure(message: String) {
        peripheral = nil
        connectedName = nil
        reconnectAttempts += 1
        guard wantsScan, reconnectAttempts <= Self.maxReconnectAttempts else {
            wantsScan = false
            status = .unavailable(message)
            return
        }
        status = .unavailable(message)
        forgetRememberedSensor()
        beginScanIfPossible()
    }

    /// 忘掉记住的设备，下次开始运动时重新选。
    public func forgetRememberedSensor() {
        UserDefaults.standard.removeObject(forKey: Self.rememberedPeripheralKey)
    }

    // MARK: - Parsing

    /// Bluetooth SIG Heart Rate Measurement（`0x2A37`）：第 0 字节是 flags，
    /// bit0 决定心率值是 8 位还是 16 位小端。其余标志位（能耗、RR 间期、传感器
    /// 接触状态）本功能用不到，直接忽略。
    ///
    /// `static` 且不碰任何实例状态，方便直接单测，不需要真的连一个手环。
    public static func parseHeartRate(from data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { return nil }
        let isWide = flags & 0x01 == 1
        if isWide {
            guard bytes.count >= 3 else { return nil }
            return Int(UInt16(bytes[1]) | (UInt16(bytes[2]) << 8))
        } else {
            guard bytes.count >= 2 else { return nil }
            return Int(bytes[1])
        }
    }

    // MARK: - Internals

    private func beginScanIfPossible() {
        guard let central, central.state == .poweredOn, wantsScan else { return }

        // 先试自动重连上次那只手环：它此刻可能已经连着系统、不再广播，
        // 全量扫描反而扫不到。
        if let saved = UserDefaults.standard.string(forKey: Self.rememberedPeripheralKey),
           let uuid = UUID(uuidString: saved),
           let known = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            startConnecting(known, displayName: known.name)
            return
        }

        status = .scanning
        // 关键：withServices 必须是 nil。CIRQA 广播心率时不在广告包里声明
        // 0x180D（见类文档），按服务过滤的话它永远不会出现在结果里。
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    private func record(bpm: Int) {
        // 心率带偶尔会吐 0（没贴合皮肤）或明显离谱的值，直接丢掉而不是
        // 让它污染 min/avg。
        guard (25...240).contains(bpm) else { return }
        let now = Date()
        currentBPM = bpm
        lastSampleAt = now
        minBPM = min(minBPM ?? bpm, bpm)
        maxBPM = max(maxBPM ?? bpm, bpm)
        sampleSum += bpm
        sampleCount += 1
        let elapsed = sessionStartedAt.map { Int(now.timeIntervalSince($0).rounded()) } ?? 0
        // 同一秒可能收到不只一次樣本（重連、裝置重送）——後者覆蓋前者，不
        // 疊加成兩個點，折線圖的橫軸才不會出現同一秒兩個不同高度的樣本。
        if samples.last?.elapsedSeconds == elapsed {
            samples[samples.count - 1] = HeartRateSample(elapsedSeconds: elapsed, bpm: bpm)
        } else {
            samples.append(HeartRateSample(elapsedSeconds: elapsed, bpm: bpm))
        }
    }

    /// Pure, directly-testable staleness rule (2026-09-07 审阅 B09): a
    /// sample older than `staleAfter` must not be presented as a live
    /// reading, even though the connection itself is still `.connected` --
    /// a dropped-contact sensor can stop sending updates entirely without
    /// CoreBluetooth ever reporting a disconnect.
    public static func isStale(lastSampleAt: Date?, asOf now: Date, staleAfter: TimeInterval = 10) -> Bool {
        guard let lastSampleAt else { return true }
        return now.timeIntervalSince(lastSampleAt) > staleAfter
    }

    public var isCurrentReadingStale: Bool {
        Self.isStale(lastSampleAt: lastSampleAt, asOf: Date())
    }
}

// MARK: - CBCentralManagerDelegate

extension HeartRateMonitor: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            beginScanIfPossible()
        case .poweredOff:
            status = .unavailable(L("藍牙已關閉，請在控制中心打開", "Bluetooth is off — turn it on in Control Center"))
        case .unauthorized:
            status = .unavailable(L("未授權使用藍牙，請到系統設定中允許", "Bluetooth access denied — allow it in Settings"))
        case .unsupported:
            status = .unavailable(L("此裝置不支援藍牙", "This device doesn't support Bluetooth"))
        case .resetting, .unknown:
            status = .unavailable(L("藍牙正在重置，請稍候", "Bluetooth is resetting — please wait"))
        @unknown default:
            status = .unavailable(L("藍牙狀態不明", "Bluetooth state unknown"))
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let advertisesHeartRate = advertised.contains(Self.heartRateService)
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? ""
        // 全量扫描会扫出一堆无名信标，只留有名字的（CIRQA 会报自己的名字）
        // 或明确声明心率服务的。
        guard advertisesHeartRate || !name.isEmpty else { return }

        let sensor = DiscoveredSensor(
            id: peripheral.identifier,
            name: name.isEmpty ? L("未命名裝置", "Unnamed device") : name,
            rssi: RSSI.intValue,
            advertisesHeartRate: advertisesHeartRate
        )
        if let index = discovered.firstIndex(where: { $0.id == sensor.id }) {
            discovered[index] = sensor
        } else {
            discovered.append(sensor)
        }
        // 声明了心率服务的排前面，其次按信号强度——教练手腕上那只离手机最近。
        discovered.sort {
            $0.advertisesHeartRate != $1.advertisesHeartRate
                ? $0.advertisesHeartRate
                : $0.rssi > $1.rssi
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        // 2026-09-07 审阅 B09: the connect timeout used to be cancelled HERE
        // -- the instant the TCP-level connection succeeded -- leaving
        // service discovery, characteristic discovery, and notification
        // subscription with NO timeout coverage at all. A device that
        // connects but never calls back for one of those stages (rather
        // than explicitly failing) got stuck in `.connecting` forever. The
        // single timeout scheduled by `startConnecting` now stays armed
        // straight through to `didUpdateNotificationStateFor` (the only
        // point that actually reaches `.connected`) or an explicit failure
        // at any intermediate step -- see `cancelConnectTimeout()`'s other
        // call sites below.
        connectedName = peripheral.name ?? connectedName
        // 记住这个外设留到发现心率服务/特征之后（见 didDiscoverCharacteristicsFor）
        // ——在这里就记住的话，一个连得上但没有心率服务的设备也会被记住，下次
        // 开始运动会优先自动重连它（审查报告 #7）。
        peripheral.discoverServices([Self.heartRateService])
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral === self.peripheral else { return }
        cancelConnectTimeout()
        registerReconnectFailure(message: L("連接失敗，請確認手環已開啟心率廣播", "Connection failed — check that heart-rate broadcast is on"))
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        // 2026-09-07 审阅 B09: identity filter -- if a fresh `startSession()`
        // already swapped in a different `self.peripheral` before this
        // (old) peripheral's disconnect callback arrived, it must not
        // touch the new session's state at all (including falling through
        // to the auto-reconnect branch below, which would otherwise try to
        // reconnect to the WRONG, already-abandoned peripheral).
        guard peripheral === self.peripheral else { return }
        currentBPM = nil
        self.peripheral = nil
        cancelConnectTimeout()

        if rejectingPeripheralID == peripheral.identifier {
            // 我们自己因为它没有心率服务而主动断开——不重连这台设备，回去扫描
            // 找别的（审查报告 #7 的核心修复：区分主动拒绝和意外掉线）。
            rejectingPeripheralID = nil
            connectedName = nil
            // 万一它恰好是"记住的设备"（比如曾经能用、固件后来变了），也一并
            // 忘掉，否则下次开始运动会一直优先自动重连回这台不兼容的设备。
            if UserDefaults.standard.string(forKey: Self.rememberedPeripheralKey) == peripheral.identifier.uuidString {
                forgetRememberedSensor()
            }
            guard wantsScan else { return }
            beginScanIfPossible()
            return
        }

        connectedName = nil
        guard wantsScan else { return }
        // 训练还在进行中却掉线（走远了 / 手环休眠），自动找回来，但计入重连
        // 上限，别无限重试。
        reconnectAttempts += 1
        guard reconnectAttempts <= Self.maxReconnectAttempts else {
            wantsScan = false
            status = .unavailable(L("多次重連失敗，請重新選擇手環", "Repeated reconnect attempts failed — please reselect the sensor"))
            return
        }
        startConnecting(peripheral, displayName: peripheral.name)
    }
}

// MARK: - CBPeripheralDelegate

extension HeartRateMonitor: CBPeripheralDelegate {
    /// Rejects the peripheral -- same "we chose to disconnect, don't
    /// auto-reconnect to it" path `didDiscoverServices`'s missing-service
    /// branch already used, now shared with every other failure point in
    /// the connect→ready pipeline (missing characteristic, notify-subscribe
    /// error/rejection) so none of them can leave the state machine stuck.
    private func rejectPeripheral(_ peripheral: CBPeripheral, message: String) {
        cancelConnectTimeout()
        status = .unavailable(message)
        rejectingPeripheralID = peripheral.identifier
        central?.cancelPeripheralConnection(peripheral)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        // 2026-09-07 审阅 B09: identity filter -- a late callback for a
        // peripheral object that is no longer `self.peripheral` (e.g. this
        // session already ended, or a fast disconnect→reconnect race
        // swapped in a different peripheral) must never mutate current
        // state.
        guard peripheral === self.peripheral else { return }
        if let error {
            rejectPeripheral(peripheral, message: L("搜尋心率服務失敗：\(error.localizedDescription)", "Failed to discover services: \(error.localizedDescription)"))
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.heartRateService }) else {
            // 标记这次断开是我们主动拒绝的，不是意外掉线——见
            // didDisconnectPeripheral 里对应的分支。
            rejectPeripheral(peripheral, message: L("此裝置沒有提供心率服務", "This device doesn't expose a heart-rate service"))
            return
        }
        peripheral.discoverCharacteristics([Self.heartRateMeasurement], for: service)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard peripheral === self.peripheral else { return }
        if let error {
            rejectPeripheral(peripheral, message: L("搜尋心率特徵失敗：\(error.localizedDescription)", "Failed to discover characteristics: \(error.localizedDescription)"))
            return
        }
        // 2026-09-07 审阅 B09: a missing characteristic used to just
        // `return` here with no failure handling at all -- status stayed
        // stuck at `.connecting` forever (the connect timeout had already
        // been cancelled at `didConnect`, so nothing would ever time it
        // out either). Now treated exactly like a missing service.
        guard let characteristic = service.characteristics?
            .first(where: { $0.uuid == Self.heartRateMeasurement }) else {
            rejectPeripheral(peripheral, message: L("此裝置沒有提供心率特徵", "This device doesn't expose a heart-rate characteristic"))
            return
        }
        // 2026-09-07 审阅 B09: no longer sets `.connected` here -- that used
        // to happen immediately after REQUESTING the subscription, before
        // it was confirmed. `didUpdateNotificationStateFor` below is the
        // only place that now sets `.connected`, and only once CoreBluetooth
        // has actually confirmed the subscription succeeded.
        peripheral.setNotifyValue(true, for: characteristic)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral === self.peripheral, characteristic.uuid == Self.heartRateMeasurement else { return }
        if let error {
            rejectPeripheral(peripheral, message: L("訂閱心率通知失敗：\(error.localizedDescription)", "Failed to subscribe to heart-rate updates: \(error.localizedDescription)"))
            return
        }
        guard characteristic.isNotifying else {
            rejectPeripheral(peripheral, message: L("訂閱心率通知未成功", "Heart-rate subscription did not take effect"))
            return
        }
        cancelConnectTimeout()
        status = .connected
        reconnectAttempts = 0
        // 心率服务、特征和订阅都确认可用了，现在才值得记住它、供下次自动重连
        // （审查报告 #7）。
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.rememberedPeripheralKey)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral === self.peripheral,
              characteristic.uuid == Self.heartRateMeasurement,
              let data = characteristic.value,
              let bpm = Self.parseHeartRate(from: data) else { return }
        record(bpm: bpm)
    }
}
