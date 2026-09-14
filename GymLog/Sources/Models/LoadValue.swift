import Foundation

/// CONTRACT.md §7.6. Wire format is a flat JSON object:
/// `{ "kind": "...", ...case-specific fields, "raw": "original cell text" }`.
///
/// See `SetLog.swift` for how this is persisted in SwiftData (JSON-string
/// backed computed property, not a native stored enum).
public enum LoadValue: Codable, Hashable {
    case absolute(kg: Double, raw: String)
    case perSide(kg: Double, raw: String)
    case bodyweight(raw: String)
    case assisted(kg: Double, raw: String)
    case band(color: String, count: Int, raw: String)
    case machineStack(level: String, raw: String)
    case pinLoad(desc: String, raw: String)
    case sled(kg: Double, raw: String)
    case unknown(raw: String)

    private enum CodingKeys: String, CodingKey {
        case kind, kg, color, count, level, desc, raw
    }

    public var raw: String {
        switch self {
        case .absolute(_, let raw), .perSide(_, let raw), .bodyweight(let raw),
             .assisted(_, let raw), .band(_, _, let raw), .machineStack(_, let raw),
             .pinLoad(_, let raw), .sled(_, let raw), .unknown(let raw):
            return raw
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? container.decode(String.self, forKey: .kind)) ?? "unknown"
        let raw = (try? container.decode(String.self, forKey: .raw)) ?? ""

        switch kind {
        case "absolute":
            if let kg = try? container.decode(Double.self, forKey: .kg) {
                self = .absolute(kg: kg, raw: raw)
            } else {
                ImportLog.warnDecodeFallback("LoadValue.absolute", reason: "missing/invalid kg for raw=\"\(raw)\"")
                self = .unknown(raw: raw)
            }
        case "perSide":
            if let kg = try? container.decode(Double.self, forKey: .kg) {
                self = .perSide(kg: kg, raw: raw)
            } else {
                ImportLog.warnDecodeFallback("LoadValue.perSide", reason: "missing/invalid kg for raw=\"\(raw)\"")
                self = .unknown(raw: raw)
            }
        case "bodyweight":
            self = .bodyweight(raw: raw)
        case "assisted":
            if let kg = try? container.decode(Double.self, forKey: .kg) {
                self = .assisted(kg: kg, raw: raw)
            } else {
                ImportLog.warnDecodeFallback("LoadValue.assisted", reason: "missing/invalid kg for raw=\"\(raw)\"")
                self = .unknown(raw: raw)
            }
        case "band":
            let color = (try? container.decode(String.self, forKey: .color)) ?? ""
            let count = (try? container.decode(Int.self, forKey: .count)) ?? 1
            self = .band(color: color, count: count, raw: raw)
        case "machineStack":
            let level = (try? container.decode(String.self, forKey: .level)) ?? raw
            self = .machineStack(level: level, raw: raw)
        case "pinLoad":
            let desc = (try? container.decode(String.self, forKey: .desc)) ?? raw
            self = .pinLoad(desc: desc, raw: raw)
        case "sled":
            if let kg = try? container.decode(Double.self, forKey: .kg) {
                self = .sled(kg: kg, raw: raw)
            } else {
                ImportLog.warnDecodeFallback("LoadValue.sled", reason: "missing/invalid kg for raw=\"\(raw)\"")
                self = .unknown(raw: raw)
            }
        case "unknown":
            self = .unknown(raw: raw)
        default:
            ImportLog.warnUnknownEnum("LoadValue.kind", value: kind)
            self = .unknown(raw: raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .absolute(let kg, let raw):
            try container.encode("absolute", forKey: .kind)
            try container.encode(kg, forKey: .kg)
            try container.encode(raw, forKey: .raw)
        case .perSide(let kg, let raw):
            try container.encode("perSide", forKey: .kind)
            try container.encode(kg, forKey: .kg)
            try container.encode(raw, forKey: .raw)
        case .bodyweight(let raw):
            try container.encode("bodyweight", forKey: .kind)
            try container.encode(raw, forKey: .raw)
        case .assisted(let kg, let raw):
            try container.encode("assisted", forKey: .kind)
            try container.encode(kg, forKey: .kg)
            try container.encode(raw, forKey: .raw)
        case .band(let color, let count, let raw):
            try container.encode("band", forKey: .kind)
            try container.encode(color, forKey: .color)
            try container.encode(count, forKey: .count)
            try container.encode(raw, forKey: .raw)
        case .machineStack(let level, let raw):
            try container.encode("machineStack", forKey: .kind)
            try container.encode(level, forKey: .level)
            try container.encode(raw, forKey: .raw)
        case .pinLoad(let desc, let raw):
            try container.encode("pinLoad", forKey: .kind)
            try container.encode(desc, forKey: .desc)
            try container.encode(raw, forKey: .raw)
        case .sled(let kg, let raw):
            try container.encode("sled", forKey: .kind)
            try container.encode(kg, forKey: .kg)
            try container.encode(raw, forKey: .raw)
        case .unknown(let raw):
            try container.encode("unknown", forKey: .kind)
            try container.encode(raw, forKey: .raw)
        }
    }
}

// MARK: - Human-readable display (Chinese UI)
extension LoadValue {
    private static let colorNames: [String: (zh: String, en: String)] = [
        "purple": ("紫", "Purple"), "blue": ("藍", "Blue"), "green": ("綠", "Green"), "red": ("紅", "Red"),
        "black": ("黑", "Black"), "yellow": ("黃", "Yellow"), "orange": ("橙", "Orange"), "grey": ("灰", "Grey"), "gray": ("灰", "Grey"),
        "white": ("白", "White"), "pink": ("粉", "Pink")
    ]

    private static func formatKg(_ kg: Double) -> String {
        if kg == kg.rounded() {
            return String(format: "%.0f", kg)
        }
        return String(format: "%.1f", kg)
    }

    /// e.g. `.assisted(30)` -> "辅助 30kg" / "Assisted 30kg"
    public var displayText: String {
        switch self {
        case .absolute(let kg, _):
            return "\(Self.formatKg(kg))kg"
        case .perSide(let kg, _):
            return L("單側 \(Self.formatKg(kg))kg", "\(Self.formatKg(kg))kg/side")
        case .bodyweight:
            return L("自重", "Bodyweight")
        case .assisted(let kg, _):
            // Shown as a negative number (e.g. "-10kg") -- the coach's own
            // ask, so assistance can't read as weight actually lifted.
            // Storage/PR-trend direction (`LoadDirection.isInverted`) is
            // unaffected; only this display string carries the "-".
            return L("輔助 -\(Self.formatKg(kg))kg", "Assisted -\(Self.formatKg(kg))kg")
        case .band(let color, let count, _):
            let names = Self.colorNames[color.lowercased()] ?? (color, color)
            let name = LanguageContext.current.t(names.zh, names.en)
            if LanguageContext.current == .zhHant {
                return count > 1 ? "\(name)帶 x\(count)" : "\(name)帶"
            } else {
                return count > 1 ? "\(name) Band x\(count)" : "\(name) Band"
            }
        case .machineStack(let level, _):
            return L("器械配重 \(level)", "Machine stack \(level)")
        case .pinLoad(let desc, _):
            return L("插銷配重 \(desc)", "Pin load \(desc)")
        case .sled(let kg, _):
            return L("雪橇 \(Self.formatKg(kg))kg", "Sled \(Self.formatKg(kg))kg")
        case .unknown(let raw):
            return raw.isEmpty ? L("未記錄", "Not recorded") : L("未記錄（\(raw)）", "Not recorded (\(raw))")
        }
    }
}
