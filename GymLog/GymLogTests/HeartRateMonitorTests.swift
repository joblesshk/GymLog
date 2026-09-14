import XCTest
@testable import GymLogKit

/// `HeartRateMonitor.parseHeartRate` -- Bluetooth SIG Heart Rate Measurement
/// （`0x2A37`）的字节解析。
///
/// 这是心率功能里唯一能脱离真实硬件验证的部分，也恰好是最容易出错的部分：
/// 第 0 字节的 bit0 决定心率值是 8 位还是 16 位小端，读错就会把 70 bpm 读成
/// 17920。连接/扫描那一半依赖 CoreBluetooth 真机行为，只能靠真机验证。
final class HeartRateMonitorTests: XCTestCase {

    private func packet(_ bytes: [UInt8]) -> Data { Data(bytes) }

    // MARK: - 8 位格式（flags bit0 == 0，绝大多数心率带用这个）

    func testParsesEightBitHeartRate() {
        XCTAssertEqual(HeartRateMonitor.parseHeartRate(from: packet([0x00, 0x48])), 72)
    }

    func testParsesEightBitHeartRateAtUpperBound() {
        XCTAssertEqual(HeartRateMonitor.parseHeartRate(from: packet([0x00, 0xFF])), 255)
    }

    /// bit0 == 0，但其他标志位（传感器接触状态、能耗、RR 间期）是置位的——
    /// 这些位不能影响心率值本身的读法。
    func testIgnoresUnrelatedFlagBitsInEightBitFormat() {
        // 0b0001_1110: 接触状态已支持且已接触 + 有能耗 + 有 RR 间期，bit0 仍是 0
        XCTAssertEqual(HeartRateMonitor.parseHeartRate(from: packet([0x1E, 0x5A, 0x01, 0x02])), 90)
    }

    // MARK: - 16 位格式（flags bit0 == 1）

    func testParsesSixteenBitHeartRateLittleEndian() {
        // 0x0110 小端 = 272
        XCTAssertEqual(HeartRateMonitor.parseHeartRate(from: packet([0x01, 0x10, 0x01])), 272)
    }

    /// 关键回归点：同样的两个字节，按 8 位读是 72、按 16 位读是别的数。
    /// flags 必须真的被用上，而不是永远当 8 位读。
    func testSixteenBitFlagIsActuallyHonoured() {
        let bytes: [UInt8] = [0x01, 0x48, 0x00]
        XCTAssertEqual(HeartRateMonitor.parseHeartRate(from: packet(bytes)), 72)

        let wide: [UInt8] = [0x01, 0x48, 0x01]
        XCTAssertEqual(HeartRateMonitor.parseHeartRate(from: packet(wide)), 328)
    }

    // MARK: - 残缺包

    func testReturnsNilForEmptyPacket() {
        XCTAssertNil(HeartRateMonitor.parseHeartRate(from: Data()))
    }

    func testReturnsNilWhenEightBitValueIsMissing() {
        XCTAssertNil(HeartRateMonitor.parseHeartRate(from: packet([0x00])))
    }

    /// 声明了 16 位却只给了 1 个字节——不能读越界，也不能拿半个值糊弄过去。
    func testReturnsNilWhenSixteenBitValueIsTruncated() {
        XCTAssertNil(HeartRateMonitor.parseHeartRate(from: packet([0x01, 0x48])))
    }

    // MARK: - 服务 / 特征 UUID

    /// 写死的是标准 SIG UUID，不是 Garmin 私有的——CIRQA 开启"心率广播"后就是
    /// 一个标准心率外设，这两个常量写错的话整条链路都对不上。
    func testUsesStandardSIGIdentifiers() {
        XCTAssertEqual(HeartRateMonitor.heartRateService.uuidString, "180D")
        XCTAssertEqual(HeartRateMonitor.heartRateMeasurement.uuidString, "2A37")
    }

    // MARK: - Staleness (2026-09-07 审阅 B09)
    //
    // Everything else B09 touches (connect/service/characteristic/
    // notify-subscribe timeout coverage, the missing-characteristic and
    // notify-confirmation-error handling, and the `peripheral === self
    // .peripheral` identity filter against late callbacks) lives entirely
    // inside `CBCentralManagerDelegate`/`CBPeripheralDelegate` methods
    // driven by `CBCentralManager`/`CBPeripheral` -- both are concrete,
    // effectively non-mockable CoreBluetooth classes with no injectable
    // seam in this class today. Those changes are code-reviewed and
    // exercised manually; this file only covers the pieces that don't
    // require a real or simulated peripheral: byte-level parsing (above)
    // and the pure staleness rule (below). Real-device verification across
    // an unsupported device, a missing characteristic, a subscribe
    // failure, a mid-session drop, and a fast disconnect→reconnect remains
    // required and is explicitly NOT claimed as done by this test file.

    func testFreshSampleIsNotStale() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(HeartRateMonitor.isStale(lastSampleAt: now, asOf: now.addingTimeInterval(2), staleAfter: 10))
    }

    func testSampleOlderThanThresholdIsStale() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(HeartRateMonitor.isStale(lastSampleAt: now, asOf: now.addingTimeInterval(11), staleAfter: 10))
    }

    func testExactlyAtThresholdIsNotYetStale() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(HeartRateMonitor.isStale(lastSampleAt: now, asOf: now.addingTimeInterval(10), staleAfter: 10))
    }

    func testNoSampleAtAllIsStale() {
        XCTAssertTrue(HeartRateMonitor.isStale(lastSampleAt: nil, asOf: Date()))
    }
}
