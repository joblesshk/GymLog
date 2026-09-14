import Foundation
import os

/// Reads/writes the single in-progress `TodayDraftSnapshot` to disk. A
/// plain JSON file, not `UserDefaults` -- a session's blocks/entries/rounds
/// can add up to a few KB, past the size `UserDefaults` is meant for, and a
/// dedicated file is trivial to inspect/delete by hand if something ever
/// goes wrong with it.
///
/// `directory` is injectable so tests can point this at a temp directory
/// instead of the real Application Support folder (see
/// `DraftPersistenceTests`).
public struct DraftPersistence {
    public let directory: URL
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let resolved = directory ?? Self.defaultDirectory()
        self.directory = resolved
        self.fileURL = resolved.appendingPathComponent("today-draft.json")
    }

    private static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("GymLog", isDirectory: true)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Overwrites whatever draft was previously saved -- there is only ever
    /// one "in-progress session" at a time (CONTRACT-UI.md's single-draft
    /// model), so this is never additive.
    ///
    /// Returns whether the write actually succeeded. 2026-09-07 审阅 B08:
    /// a failed autosave must still never crash or interrupt the coach's
    /// actual training session -- the caller (`TodayView`) surfaces this as
    /// a small, non-blocking indicator, not silence (the old behavior: log
    /// and otherwise pretend nothing happened).
    @discardableResult
    public func save(_ snapshot: TodayDraftSnapshot) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            Logger(subsystem: "org.example.gymlog", category: "draft").warning("DraftPersistence.save failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    public enum LoadResult: Equatable {
        case none
        case snapshot(TodayDraftSnapshot)
        /// The file existed but failed to decode. 2026-09-07 审阅 B08: the
        /// old behavior silently returned `nil` here, indistinguishable
        /// from "nothing was ever saved" -- the coach's actual in-progress
        /// work was gone with no trace it had ever existed. The corrupt
        /// bytes are moved aside to `quarantinedTo` (best-effort; `nil` if
        /// even that failed) instead of being overwritten by the next
        /// autosave, so there's something to inspect after the fact.
        case corrupted(quarantinedTo: URL?)
    }

    /// `.none` if nothing was ever saved. A broken snapshot never blocks the
    /// coach from starting a fresh session -- but is reported as
    /// `.corrupted`, not silently treated the same as `.none`.
    public func load() -> LoadResult {
        guard let data = try? Data(contentsOf: fileURL) else { return .none }
        if let decoded = try? Self.decoder.decode(TodayDraftSnapshot.self, from: data) {
            return .snapshot(decoded)
        }
        let quarantineURL = directory.appendingPathComponent("today-draft-corrupted-\(UUID().uuidString).json")
        let quarantined: URL? = (try? data.write(to: quarantineURL, options: .atomic)) != nil ? quarantineURL : nil
        try? FileManager.default.removeItem(at: fileURL)
        return .corrupted(quarantinedTo: quarantined)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
