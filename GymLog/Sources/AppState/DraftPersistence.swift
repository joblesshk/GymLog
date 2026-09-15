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
    ///
    /// R06 (2026-09-16): refuses to write when the file already on disk is
    /// corrupted bytes `load()` couldn't quarantine (disk full/permissions
    /// at load time) -- that file is the coach's last-remaining recovery
    /// copy; a normal autosave must never silently overwrite it. Only
    /// `clear()`, or a `load()` that finally manages to quarantine it, frees
    /// this slot up again.
    @discardableResult
    public func save(_ snapshot: TodayDraftSnapshot) -> Bool {
        guard !isBlockedByUnquarantinedCorruption() else {
            Logger(subsystem: "org.example.gymlog", category: "draft").warning("DraftPersistence.save refused: an unquarantined corrupted draft is still on disk")
            return false
        }
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

    /// A file at `fileURL` that exists but doesn't decode as a
    /// `TodayDraftSnapshot` is, by construction, corrupted bytes `load()`
    /// tried and failed to move aside -- `save()` must not treat that slot
    /// as "just the previous draft" and overwrite it.
    private func isBlockedByUnquarantinedCorruption() -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else { return false }
        return (try? Self.decoder.decode(TodayDraftSnapshot.self, from: data)) == nil
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
    ///
    /// R06 (2026-09-16): the original file is removed only as a side effect
    /// of a successful `moveItem` (same-volume rename) into quarantine --
    /// never as a separate step. `moveItem` either fully succeeds (source
    /// gone, quarantine copy exists) or fully fails (source untouched, no
    /// quarantine copy); there is no window where a failed quarantine write
    /// still takes the original down with it, the way a copy-then-delete
    /// sequence could (e.g. under disk-full, where the copy fails but a
    /// following unconditional delete still runs).
    public func load() -> LoadResult {
        guard let data = try? Data(contentsOf: fileURL) else {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                Logger(subsystem: "org.example.gymlog", category: "draft").warning("DraftPersistence.load: file exists but could not be read (permissions?) -- treating as no draft, not deleting it")
            }
            return .none
        }
        if let decoded = try? Self.decoder.decode(TodayDraftSnapshot.self, from: data) {
            return .snapshot(decoded)
        }
        let quarantineURL = directory.appendingPathComponent("today-draft-corrupted-\(UUID().uuidString).json")
        do {
            try FileManager.default.moveItem(at: fileURL, to: quarantineURL)
            return .corrupted(quarantinedTo: quarantineURL)
        } catch {
            // Quarantine failed -- the corrupted bytes are the only
            // remaining trace of whatever the coach had in progress, so they
            // stay exactly where they are instead of being deleted. `save()`
            // (`isBlockedByUnquarantinedCorruption`) now refuses to write
            // over this file until it's cleared or a later `load()` finally
            // manages to move it aside.
            Logger(subsystem: "org.example.gymlog", category: "draft").warning("DraftPersistence.load: quarantine move failed, leaving corrupted file in place: \(String(describing: error), privacy: .public)")
            return .corrupted(quarantinedTo: nil)
        }
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
