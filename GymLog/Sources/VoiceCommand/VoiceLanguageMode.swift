import Foundation

/// 2026-09-13 全局語音改造：用戶明確要求的兩個可選識別模式──「普通話＋
/// 英文」與「粵語＋英文」，兩者都是本輪交付的核心能力，不是其中一個是
/// 「默認」另一個是「附加」。這個枚舉刻意不是 `zh-CN`/`zh-HK` 這種 BCP-47
/// locale 的直接別名，也不跟 `AppLanguage`（界面顯示語言）綁定──執行
/// Prompt §4.1「模式選擇獨立於界面語言、設備地區和 IP，記住上次選擇」；
/// 使用者可能界面用英文、卻用粵語錄音，兩者是完全獨立的兩個維度。
public enum VoiceLanguageMode: String, CaseIterable, Codable, Sendable {
    case mandarinEnglish
    case cantoneseEnglish

    public var displayLabel: String {
        switch self {
        case .mandarinEnglish: return L("普通話＋英文", "Mandarin + English")
        case .cantoneseEnglish: return L("粵語＋英文", "Cantonese + English")
        }
    }

    /// Legacy parser compatibility only; the cloud recorder ignores this locale.
    public var recognitionLocale: Locale {
        switch self {
        case .mandarinEnglish: return Locale(identifier: "zh-CN")
        case .cantoneseEnglish: return Locale(identifier: "zh-HK")
        }
    }
}

/// 記住用戶上次選擇的語言模式──跟 `LanguageContext`（`AppLanguage.swift`）
/// 同一個「直接讀寫 `UserDefaults`，不快取」寫法，這樣 GymLogKit（沒有
/// SwiftUI／`@AppStorage`）跟 App target 的 SwiftUI 層可以共享同一個
/// 持久化位置，不需要靠參數層層傳遞。
public enum VoiceLanguageModePreference {
    private static let key = "voiceLanguageMode"

    public static var current: VoiceLanguageMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key), let mode = VoiceLanguageMode(rawValue: raw) else {
                return .mandarinEnglish
            }
            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}
