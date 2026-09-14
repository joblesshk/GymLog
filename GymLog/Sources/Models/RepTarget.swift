import Foundation

/// CONTRACT.md §7.7. Wire format is a flat JSON object:
/// `{ "kind": "...", ...case-specific fields, "raw": "original cell text" }`.
/// Used for both `target` (planned) and `actual` (completed) on `SetLog`.
public enum RepTarget: Codable, Hashable {
    case range(low: Int, high: Int, raw: String)
    case fixed(value: Int, raw: String)
    case time(seconds: Int, raw: String)
    case distance(meters: Int, raw: String)
    case rounds(count: Int, raw: String)
    /// CONTRACT.md §7.7/§7.8: per-side reps for unilateral work, e.g.
    /// `10,10` on `Leg extension SL`, `Bulgarian split squat`. Distinct from
    /// `LoadValue.perSide` (a weight, on the load axis) -- this is a rep
    /// count pair, on the target/actual axis.
    case perSide(left: Int, right: Int, raw: String)
    case unknown(raw: String)

    private enum CodingKeys: String, CodingKey {
        case kind, low, high, value, seconds, meters, count, left, right, raw
    }

    public var raw: String {
        switch self {
        case .range(_, _, let raw), .fixed(_, let raw), .time(_, let raw),
             .distance(_, let raw), .rounds(_, let raw), .perSide(_, _, let raw),
             .unknown(let raw):
            return raw
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? container.decode(String.self, forKey: .kind)) ?? "unknown"
        let raw = (try? container.decode(String.self, forKey: .raw)) ?? ""

        switch kind {
        case "range":
            if let low = try? container.decode(Int.self, forKey: .low),
               let high = try? container.decode(Int.self, forKey: .high) {
                self = .range(low: low, high: high, raw: raw)
            } else {
                ImportLog.warnDecodeFallback("RepTarget.range", reason: "missing/invalid low/high for raw=\"\(raw)\"")
                self = .unknown(raw: raw)
            }
        case "fixed":
            if let value = try? container.decode(Int.self, forKey: .value) {
                self = .fixed(value: value, raw: raw)
            } else {
                ImportLog.warnDecodeFallback("RepTarget.fixed", reason: "missing/invalid value for raw=\"\(raw)\"")
                self = .unknown(raw: raw)
            }
        case "time":
            if let seconds = try? container.decode(Int.self, forKey: .seconds) {
                self = .time(seconds: seconds, raw: raw)
            } else {
                ImportLog.warnDecodeFallback("RepTarget.time", reason: "missing/invalid seconds for raw=\"\(raw)\"")
                self = .unknown(raw: raw)
            }
        case "distance":
            if let meters = try? container.decode(Int.self, forKey: .meters) {
                self = .distance(meters: meters, raw: raw)
            } else {
                ImportLog.warnDecodeFallback("RepTarget.distance", reason: "missing/invalid meters for raw=\"\(raw)\"")
                self = .unknown(raw: raw)
            }
        case "rounds":
            if let count = try? container.decode(Int.self, forKey: .count) {
                self = .rounds(count: count, raw: raw)
            } else {
                ImportLog.warnDecodeFallback("RepTarget.rounds", reason: "missing/invalid count for raw=\"\(raw)\"")
                self = .unknown(raw: raw)
            }
        case "perSide":
            if let left = try? container.decode(Int.self, forKey: .left),
               let right = try? container.decode(Int.self, forKey: .right) {
                self = .perSide(left: left, right: right, raw: raw)
            } else {
                ImportLog.warnDecodeFallback("RepTarget.perSide", reason: "missing/invalid left/right for raw=\"\(raw)\"")
                self = .unknown(raw: raw)
            }
        case "unknown":
            self = .unknown(raw: raw)
        default:
            ImportLog.warnUnknownEnum("RepTarget.kind", value: kind)
            self = .unknown(raw: raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .range(let low, let high, let raw):
            try container.encode("range", forKey: .kind)
            try container.encode(low, forKey: .low)
            try container.encode(high, forKey: .high)
            try container.encode(raw, forKey: .raw)
        case .fixed(let value, let raw):
            try container.encode("fixed", forKey: .kind)
            try container.encode(value, forKey: .value)
            try container.encode(raw, forKey: .raw)
        case .time(let seconds, let raw):
            try container.encode("time", forKey: .kind)
            try container.encode(seconds, forKey: .seconds)
            try container.encode(raw, forKey: .raw)
        case .distance(let meters, let raw):
            try container.encode("distance", forKey: .kind)
            try container.encode(meters, forKey: .meters)
            try container.encode(raw, forKey: .raw)
        case .rounds(let count, let raw):
            try container.encode("rounds", forKey: .kind)
            try container.encode(count, forKey: .count)
            try container.encode(raw, forKey: .raw)
        case .perSide(let left, let right, let raw):
            try container.encode("perSide", forKey: .kind)
            try container.encode(left, forKey: .left)
            try container.encode(right, forKey: .right)
            try container.encode(raw, forKey: .raw)
        case .unknown(let raw):
            try container.encode("unknown", forKey: .kind)
            try container.encode(raw, forKey: .raw)
        }
    }
}

// MARK: - Human-readable display (Chinese UI)
extension RepTarget {
    /// `143` -> "2:23". Shared so every m:ss rendering of a `.time` seconds
    /// count (this file's own `displayText`, and the Round table's quantity
    /// cell in `EntryRowView.swift`) formats identically instead of each
    /// reimplementing the same division/modulo.
    public static func formatSeconds(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// e.g. `.range(8,12)` -> "8-12 次", `.time(143)` -> "2:23",
    /// `.perSide(10,10)` -> "左右各10次", `.perSide(8,10)` -> "左8 右10次"
    public var displayText: String {
        switch self {
        case .range(let low, let high, _):
            return L("\(low)-\(high) 次", "\(low)-\(high) reps")
        case .fixed(let value, _):
            return L("\(value) 次", "\(value) reps")
        case .time(let seconds, _):
            return Self.formatSeconds(seconds)
        case .distance(let meters, _):
            return L("\(meters) 米", "\(meters) m")
        case .rounds(let count, _):
            return L("\(count) 輪", "\(count) rounds")
        case .perSide(let left, let right, _):
            if left == right {
                return L("左右各\(left)次", "\(left) reps/side")
            }
            return L("左\(left) 右\(right)次", "L\(left) R\(right) reps")
        case .unknown(let raw):
            return raw.isEmpty ? L("未記錄", "Not recorded") : L("未記錄（\(raw)）", "Not recorded (\(raw))")
        }
    }
}
