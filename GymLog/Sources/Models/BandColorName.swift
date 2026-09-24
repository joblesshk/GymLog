import Foundation

/// Canonical storage keys and localized labels are deliberately separate.
/// Unknown brand/model names are preserved; only known colors are translated.
public enum BandColorName {
    private static let names: [String: (zh: String, en: String)] = [
        "black": ("黑", "Black"), "blue": ("藍", "Blue"),
        "green": ("綠", "Green"), "red": ("紅", "Red"),
        "purple": ("紫", "Purple"), "yellow": ("黃", "Yellow"),
        "orange": ("橙", "Orange"), "gray": ("灰", "Gray"),
        "white": ("白", "White"), "pink": ("粉紅", "Pink"),
        "light green": ("淺綠", "Light Green"), "light blue": ("淺藍", "Light Blue"),
        "dark green": ("深綠", "Dark Green"), "dark blue": ("深藍", "Dark Blue")
    ]

    private static func key(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "绿", with: "綠").replacingOccurrences(of: "蓝", with: "藍")
            .replacingOccurrences(of: "红", with: "紅").replacingOccurrences(of: "黄", with: "黃")
            .replacingOccurrences(of: "浅", with: "淺").replacingOccurrences(of: "弹", with: "彈")
            .replacingOccurrences(of: "带", with: "帶")
        for suffix in [" resistance band", " band", "彈力帶", "色帶", "帶", "色"] where value.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        if value == "grey" { return "gray" }
        if value == "粉" { return "pink" }
        for (key, pair) in names {
            if value == key || value == pair.zh { return key }
            // Historical manually entered bilingual labels.
            if ["\(key)(\(pair.zh))", "\(key)（\(pair.zh)）", "\(pair.zh)(\(key))", "\(pair.zh)（\(key)）"].map({ $0.replacingOccurrences(of: " ", with: "") }).contains(value.replacingOccurrences(of: " ", with: "")) {
                return key
            }
        }
        return nil
    }

    public static func canonical(_ input: String) -> String? {
        if let single = key(input) { return single }
        let parts = input.components(separatedBy: CharacterSet(charactersIn: "+＋/、,&＆"))
        guard parts.count > 1 else { return nil }
        let keys = parts.compactMap(key)
        guard keys.count == parts.count else { return nil }
        return keys.joined(separator: "+")
    }

    public static func display(_ input: String, language: AppLanguage) -> String {
        guard let canonical = canonical(input) else { return input }
        return canonical.components(separatedBy: "+").map { component in
            guard let pair = names[component] else { return component }
            return language.t(pair.zh, pair.en)
        }.joined(separator: language == .zhHant ? "＋" : " + ")
    }
}
