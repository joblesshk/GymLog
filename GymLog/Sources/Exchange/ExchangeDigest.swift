import Foundation
import CryptoKit

/// SHA-256 content digest for an `ExchangePackage` -- same canonical-JSON
/// idiom as `SessionDigest` (`.sortedKeys`, since `JSONEncoder` does not
/// guarantee stable key order across separate encode calls for the same
/// value otherwise). Hashes `payloadKind` + `client` + `sessions` +
/// `exercises` only -- deliberately EXCLUDES `packageID`/`createdAt`/
/// `formatVersion`/`originInstallationID`, so re-exporting genuinely
/// unchanged content on a later day produces the same digest (that's the
/// whole point: `ExchangeImporter` uses this to tell "re-sent, unchanged"
/// apart from "re-sent, content actually changed").
public enum ExchangeDigest {
    private struct DigestBody: Encodable {
        let payloadKind: ExchangePayloadKind
        let client: ExchangeClientRef
        let sessions: [ExchangeSessionDTO]
        let exercises: [ExchangeExerciseSnapshot]
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static func compute(payloadKind: ExchangePayloadKind, client: ExchangeClientRef, sessions: [ExchangeSessionDTO], exercises: [ExchangeExerciseSnapshot]) -> String {
        let body = DigestBody(payloadKind: payloadKind, client: client, sessions: sessions, exercises: exercises)
        guard let data = try? encoder.encode(body) else { return sha256("") }
        return sha256(data)
    }

    /// Digest of a single session's own content (used per-record during
    /// import to decide new/idempotent/content-changed) -- same body shape
    /// minus the package-level `client`/`exercises` wrapper, since a
    /// session's own digest must not change just because a SIBLING session
    /// in the same package changed.
    public static func computeSessionDigest(_ session: ExchangeSessionDTO) -> String {
        guard let data = try? encoder.encode(session) else { return sha256("") }
        return sha256(data)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ text: String) -> String {
        sha256(Data(text.utf8))
    }
}
