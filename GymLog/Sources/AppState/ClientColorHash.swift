import Foundation

/// CONTRACT-UI.md §3.4: "每个学员一个稳定配色（由 `Client.id` 哈希决定，同一学员在
/// 任何界面同色）".
///
/// Deliberately NOT built on Swift's `Hasher`/`hashValue`: those are seeded
/// randomly per process launch (a deliberate DoS-hardening property of
/// `Hashable`), so the same client would get a different color every cold
/// start -- directly violating "stable". This uses a fixed, unseeded
/// djb2-style string hash instead, so the same `id` always maps to the same
/// hue, in this launch and every other one.
public enum ClientColorHash {
    /// Hue in [0, 1) for use with e.g. `Color(hue:saturation:brightness:)`.
    public static func hue(forID id: String) -> Double {
        var hash: UInt64 = 5381
        for byte in id.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte) // djb2: hash*33 + byte
        }
        return Double(hash % 360) / 360.0
    }
}
