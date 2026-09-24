import Foundation

public enum LoadWeightUnit: String, CaseIterable, Codable {
    case kg, lb
    public var kilogramsPerUnit: Double { self == .kg ? 1 : 0.45359237 }
}

extension LoadValue {
    public var numericKilograms: Double? {
        switch self {
        case .absolute(let kg, _), .perSide(let kg, _), .assisted(let kg, _), .sled(let kg, _): return kg
        default: return nil
        }
    }

    /// Keep the wire format compatible. A recognized source unit is a display
    /// preference only; the stored kilograms remain authoritative for analytics.
    public var weightUnit: LoadWeightUnit {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.range(of: #"\d\s*lbs?$"#, options: .regularExpression) == nil ? .kg : .lb
    }

    public var hasExplicitLoadMode: Bool {
        ["absolute:", "perSide:", "assisted:", "sled:"].contains { raw.hasPrefix($0) }
    }

    public var weightNumber: Double? {
        guard let kg = numericKilograms else { return nil }
        let unit = weightUnit
        let source = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^(absolute|perside|assisted|sled):\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*(kg|lbs?)$"#, with: "", options: .regularExpression)
        if let value = Double(source), value.isFinite, value >= 0,
           abs(value * unit.kilogramsPerUnit - kg) < 0.0001 { return value }
        return kg / unit.kilogramsPerUnit
    }

    public var formattedWeight: String {
        "\(SetEditDraft.formatNumber(weightNumber ?? 0))\(weightUnit.rawValue)"
    }
}

/// Transactional editor: presenting, changing units and cancelling never write
/// to the session. Existing imported values remain byte-for-byte unchanged when
/// the user confirms without edits.
public struct LoadSelectionDraft {
    public enum Mode: String, CaseIterable {
        case absolute, perSide, assisted, band, bodyweight, machineStack, sled, custom
        public var isNumeric: Bool { [.absolute, .perSide, .assisted, .sled].contains(self) }
    }
    public var mode: Mode
    public var number: String
    public var unit: LoadWeightUnit
    public var bandColor: String
    public var bandCount: String
    public var detail: String
    private let original: LoadValue
    private let initial: [String]

    private var fields: [String] { [mode.rawValue, number, unit.rawValue, bandColor, bandCount, detail] }
    public init(load: LoadValue, suggested: LoadWheelKind) {
        original = load
        unit = load.weightUnit
        number = SetEditDraft.formatNumber(load.weightNumber ?? 20)
        bandColor = "blue"; bandCount = "1"; detail = ""
        switch load {
        case .absolute: mode = suggested == .assisted && !load.hasExplicitLoadMode ? .assisted : .absolute
        case .perSide: mode = suggested == .assisted && !load.hasExplicitLoadMode ? .assisted : .perSide
        case .assisted: mode = .assisted
        case .sled: mode = .sled
        case .bodyweight: mode = .bodyweight
        case .band(let color, let count, _): mode = .band; bandColor = color; bandCount = String(count)
        case .machineStack(let level, _): mode = .machineStack; detail = level
        case .pinLoad(let desc, _): mode = .custom; detail = desc
        case .unknown(let raw):
            detail = raw
            if !raw.isEmpty { mode = .custom }
            else {
                switch suggested {
                case .absolute: mode = suggested == .assisted && !load.hasExplicitLoadMode ? .assisted : .absolute
                case .perSide: mode = .perSide
                case .assisted: mode = .assisted
                case .bodyweightPlus: mode = .bodyweight
                case .band(let colors): mode = .band; bandColor = colors.first ?? "blue"
                }
            }
        }
        initial = [mode.rawValue, number, unit.rawValue, bandColor, bandCount, detail]
    }

    public static func parseNumber(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite, value >= 0, value <= 100_000 else { return nil }
        return value
    }

    public var validationError: String? {
        if fields == initial { return nil }
        if mode.isNumeric, Self.parseNumber(number) == nil { return L("請輸入 0～100000 的重量", "Enter a weight from 0 to 100000") }
        if mode == .band {
            guard !bandColor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let count = Int(bandCount), (1...1000).contains(count) else {
                return L("請填寫彈力帶名稱及 1～1000 的數量", "Enter a band name and a count from 1 to 1000")
            }
        }
        if [.custom, .machineStack].contains(mode), detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L("請填寫負重描述", "Enter a load description")
        }
        return nil
    }

    public func resolved() -> LoadValue? {
        if fields == initial { return original }
        guard validationError == nil else { return nil }
        if mode.isNumeric {
            guard let value = Self.parseNumber(number) else { return nil }
            let kg = value * unit.kilogramsPerUnit
            let raw = "\(mode.rawValue): \(SetEditDraft.formatNumber(value)) \(unit.rawValue)"
            switch mode {
            case .absolute: return .absolute(kg: kg, raw: raw)
            case .perSide: return .perSide(kg: kg, raw: raw)
            case .assisted: return .assisted(kg: kg, raw: raw)
            case .sled: return .sled(kg: kg, raw: raw)
            default: return nil
            }
        }
        let description = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .band:
            let trimmed = bandColor.trimmingCharacters(in: .whitespacesAndNewlines)
            let color = BandColorName.canonical(trimmed) ?? trimmed
            let count = Int(bandCount) ?? 1
            return .band(color: color, count: count, raw: "\(color) x\(count)")
        case .bodyweight: return .bodyweight(raw: "BW")
        case .machineStack: return .machineStack(level: description, raw: description)
        case .custom: return .pinLoad(desc: description, raw: description)
        default: return nil
        }
    }
}
