import Foundation

/// The versioned blob stored on `SessionBlock.wodPayload` for a WOD/skill
/// section -- pairs the prescription (plan) with its result (outcome).
/// `schemaVersion` here is checked BEFORE attempting to decode the nested
/// `WODPrescription`/`WODResult` (see `SessionBlock.wodPayload`'s getter):
/// a payload written by a future app version, or one that's simply corrupt,
/// is preserved as opaque raw text rather than decoded, silently modified,
/// and re-encoded lossy (工程审阅 §5.2: "未知未來payload保留原文並限制編輯，
/// 不降級為空對象覆蓋").
public struct WODPayload: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var prescription: WODPrescription
    public var result: WODResult

    public init(schemaVersion: Int = WODPayload.currentSchemaVersion, prescription: WODPrescription, result: WODResult) {
        self.schemaVersion = schemaVersion
        self.prescription = prescription
        self.result = result
    }
}

/// Cheap peek at just `schemaVersion` before committing to a full
/// `WODPayload` decode -- lets `SessionBlock.wodPayload` refuse a
/// too-new payload without that decode attempt itself risking a partial/
/// lossy read of fields this build doesn't know about.
struct WODPayloadVersionEnvelope: Decodable {
    var schemaVersion: Int
}
