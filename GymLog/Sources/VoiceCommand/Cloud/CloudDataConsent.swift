import Foundation

/// Explicit permission to send recordings and training data to the third-party speech and
/// language-model services behind the relay (App Review Guideline 5.1.2(i)). Nothing reaches
/// those services before this is granted: `CloudRelaySession.token()` refuses without it.
/// Bump `currentVersion` when what is sent, or to whom, changes, so people are asked again.
public enum CloudDataConsent {
    public static let currentVersion = 1
    static let key = "cloudDataConsentVersion"

    public static var isGranted: Bool { UserDefaults.standard.integer(forKey: key) >= currentVersion }
    public static func grant() { UserDefaults.standard.set(currentVersion, forKey: key) }
    public static func revoke() { UserDefaults.standard.removeObject(forKey: key) }

    static func require() throws {
        guard isGranted else {
            throw CloudVoiceError.message(L("需要先同意雲端資料處理說明，才能使用語音安排和 AI 評價。",
                                            "Agree to the cloud data notice before using voice planning or AI review."))
        }
    }
}
