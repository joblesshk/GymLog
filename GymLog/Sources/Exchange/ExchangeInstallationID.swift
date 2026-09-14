import Foundation

/// P2 (2026-09-11) §5.3: "來源設備標識只是命名空間，不是身份認證" -- a stable
/// per-install UUID, generated once and persisted in `UserDefaults`, used
/// ONLY to namespace `(originInstallationID, recordID)` pairs for dedup/
/// content-change detection (`ExchangeImporter`). It proves nothing about
/// who's holding the device; never used for anything resembling auth.
public enum ExchangeInstallationID {
    private static let key = "exchangeInstallationID"

    public static var current: String {
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
}
