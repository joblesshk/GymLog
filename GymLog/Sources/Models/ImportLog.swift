import Foundation
import os

/// Shared logger for import-time decode fallbacks (unrecognized enum strings,
/// malformed LoadValue/RepTarget payloads, etc). Centralized here so every
/// "degraded gracefully" event in the model layer goes through one place,
/// per CONTRACT.md §11.4 ("未知枚举值降级为兜底分支... 记录日志，不得崩溃").
enum ImportLog {
    static let logger = Logger(subsystem: "org.example.gymlog", category: "import")

    /// Ring buffer of human-readable fallback messages collected during the
    /// most recent import run, surfaced in the import summary UI so a coach
    /// (or us, during dev) can see what got degraded without digging through
    /// the system log.
    private static var _messages: [String] = []
    private static let lock = NSLock()

    static func warnUnknownEnum(_ typeName: String, value: String) {
        record("Unrecognized \(typeName) value \"\(value)\" -> falling back to unknown/other.")
    }

    static func warnDecodeFallback(_ context: String, reason: String) {
        record("Decode fallback in \(context): \(reason)")
    }

    private static func record(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        lock.lock()
        _messages.append(message)
        lock.unlock()
    }

    static func drainMessages() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let msgs = _messages
        _messages.removeAll()
        return msgs
    }
}
