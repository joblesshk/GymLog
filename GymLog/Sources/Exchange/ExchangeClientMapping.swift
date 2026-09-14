import Foundation

/// P2 §5.3: "兩端本地學員檔案通過明確關聯指向同一人；不按姓名自動合併" --
/// once a coach/student explicitly resolves "this remote client = my local
/// client X" during an import, that choice is remembered so future
/// exchanges from the same remote client pre-select the same local mapping
/// (§5.3: "已有明確映射時可預選，仍顯示歸屬") instead of asking every time.
///
/// `UserDefaults`-backed rather than a new SwiftData model: this is a small
/// per-installation preference (at most a few dozen entries in realistic
/// use), not training data -- the same weight class as `currentClientID`/
/// `appLanguage`, not a case for a new `@Model` + migration.
public enum ExchangeClientMapping {
    private static let key = "exchangeClientMappings"

    private static func mappingKey(originInstallationID: String, remoteClientID: String) -> String {
        "\(originInstallationID)|\(remoteClientID)"
    }

    private static var stored: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The local `Client.id` previously chosen for this remote client, if
    /// any.
    public static func localClientID(originInstallationID: String, remoteClientID: String) -> String? {
        stored[mappingKey(originInstallationID: originInstallationID, remoteClientID: remoteClientID)]
    }

    public static func setMapping(originInstallationID: String, remoteClientID: String, localClientID: String) {
        var current = stored
        current[mappingKey(originInstallationID: originInstallationID, remoteClientID: remoteClientID)] = localClientID
        stored = current
    }

    public static func removeMapping(originInstallationID: String, remoteClientID: String) {
        var current = stored
        current.removeValue(forKey: mappingKey(originInstallationID: originInstallationID, remoteClientID: remoteClientID))
        stored = current
    }
}
