import Foundation

/// M7 §3.1: the one seam the OQ-1 ZIP-reading decision hides behind. An
/// `.xlsx` file is a ZIP container of XML parts; whichever way that
/// container gets read (a hand-rolled reader today, or a third-party
/// library if that's ever revisited), `XLSXWorkbook` only ever talks to
/// this protocol, so switching implementations is a single-file diff.
public protocol ArchiveReading {
    /// All entry paths in the archive, in central-directory order (e.g.
    /// `"xl/worksheets/sheet2.xml"`).
    func entryNames() -> [String]

    /// The decompressed bytes of one entry. Throws if `name` isn't in the
    /// archive, or if the archive is malformed in a way that prevents
    /// reading that entry.
    func data(forEntry name: String) throws -> Data
}

public enum ArchiveReadingError: Error, Equatable {
    case notAnArchive
    case unsupportedArchive(reason: String)
    case entryNotFound(name: String)
    case corruptEntry(name: String, reason: String)
}
