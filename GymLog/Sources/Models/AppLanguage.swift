import Foundation

/// In-app language override (Settings › 外观/语言), independent of the
/// device's system locale. Two options only, per product decision: Traditional
/// Chinese (default) and English. Nothing in this app reads `Locale.current`
/// for UI copy -- every user-facing string branches on this value instead, so
/// switching takes effect instantly without relaunching.
public enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case zhHant
    case en

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .zhHant: return "繁體中文"
        case .en: return "English"
        }
    }

    /// Picks between a Traditional Chinese string and an English string.
    public func t(_ zh: String, _ en: String) -> String {
        self == .zhHant ? zh : en
    }
}

/// Live, always-fresh read of the current `AppLanguage` for the model-layer
/// `displayName`/`displayText` computed properties (`ClassificationEnums.swift`,
/// `LoadValue.swift`, `RepTarget.swift`, `Client.swift`, `ChartMetric.swift`,
/// `FrequencyAnalyzer.swift`). Those stay plain properties -- not functions
/// taking a language argument -- so none of their many call sites across the
/// view layer need to change; they just start returning the right language
/// once the coach flips the switch in Settings.
///
/// Reads straight from `UserDefaults` every time rather than caching, so it
/// can never go stale relative to the `@AppStorage("appLanguage")` instances
/// views hold for their own literal copy -- both ultimately read/write the
/// same `UserDefaults` key.
public enum LanguageContext {
    public static var current: AppLanguage {
        if let raw = UserDefaults.standard.string(forKey: "appLanguage"),
           let language = AppLanguage(rawValue: raw) {
            return language
        }
        return .zhHant
    }
}

/// Shorthand for model-layer display strings: `L("繁體", "English")` picks
/// based on `LanguageContext.current`.
public func L(_ zh: String, _ en: String) -> String {
    LanguageContext.current.t(zh, en)
}
