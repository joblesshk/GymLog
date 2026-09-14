import Foundation

/// A typed CrossFit-style quantity: reps, a duration, a distance, or a
/// machine's displayed calorie count. Deliberately separate from
/// `RepTarget` (§7.7's reps/time/distance/rounds/perSide/range) rather than
/// reusing it: `RepTarget.rounds` already means "旧 Round 的趟数" (a strength
/// entry's repeat-count of one parameter group, CONTRACT-M5.md §3.3), a
/// completely different concept from a CrossFit WOD's "轮" — conflating the
/// two was the exact mistake `工程审阅与CrossFit适配方案.md` §2 warned against.
///
/// `machineCalories` is its own case, not a unit conversion of `reps`: a
/// rower/bike's displayed calorie count is the ERGOMETER's computed work
/// output, not the athlete's true energy expenditure, and must never be
/// silently converted to/from meters or reps (工程审阅 §5.2's
/// `WorkoutQuantity` requirement).
///
/// Same flat-JSON-string persistence convention as `LoadValue`/`RepTarget`
/// (`{"kind":"...", "value":N, "raw":"..."}`) — see `SetLog.swift`'s
/// persistence note for why a JSON string column rather than SwiftData's
/// opaque transformable-enum storage.
public enum WorkoutQuantity: Codable, Hashable, Sendable {
    case reps(Int, raw: String)
    case seconds(Int, raw: String)
    case meters(Int, raw: String)
    case machineCalories(Int, raw: String)
    case unknown(raw: String)

    private enum CodingKeys: String, CodingKey {
        case kind, value, raw
    }

    public var raw: String {
        switch self {
        case .reps(_, let raw), .seconds(_, let raw), .meters(_, let raw),
             .machineCalories(_, let raw), .unknown(let raw):
            return raw
        }
    }

    /// The numeric magnitude, or `nil` for `.unknown` -- never a unit
    /// conversion between kinds (see the type's own doc comment).
    public var value: Int? {
        switch self {
        case .reps(let v, _), .seconds(let v, _), .meters(let v, _), .machineCalories(let v, _):
            return v
        case .unknown:
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? container.decode(String.self, forKey: .kind)) ?? "unknown"
        let raw = (try? container.decode(String.self, forKey: .raw)) ?? ""
        switch kind {
        case "reps":
            if let v = try? container.decode(Int.self, forKey: .value) { self = .reps(v, raw: raw) }
            else { self = .unknown(raw: raw) }
        case "seconds":
            if let v = try? container.decode(Int.self, forKey: .value) { self = .seconds(v, raw: raw) }
            else { self = .unknown(raw: raw) }
        case "meters":
            if let v = try? container.decode(Int.self, forKey: .value) { self = .meters(v, raw: raw) }
            else { self = .unknown(raw: raw) }
        case "machineCalories":
            if let v = try? container.decode(Int.self, forKey: .value) { self = .machineCalories(v, raw: raw) }
            else { self = .unknown(raw: raw) }
        case "unknown":
            self = .unknown(raw: raw)
        default:
            self = .unknown(raw: raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .reps(let v, let raw):
            try container.encode("reps", forKey: .kind); try container.encode(v, forKey: .value); try container.encode(raw, forKey: .raw)
        case .seconds(let v, let raw):
            try container.encode("seconds", forKey: .kind); try container.encode(v, forKey: .value); try container.encode(raw, forKey: .raw)
        case .meters(let v, let raw):
            try container.encode("meters", forKey: .kind); try container.encode(v, forKey: .value); try container.encode(raw, forKey: .raw)
        case .machineCalories(let v, let raw):
            try container.encode("machineCalories", forKey: .kind); try container.encode(v, forKey: .value); try container.encode(raw, forKey: .raw)
        case .unknown(let raw):
            try container.encode("unknown", forKey: .kind); try container.encode(raw, forKey: .raw)
        }
    }
}

extension WorkoutQuantity {
    public var displayText: String {
        switch self {
        case .reps(let v, _): return L("\(v) 次", "\(v) reps")
        case .seconds(let v, _): return RepTarget.formatSeconds(v)
        case .meters(let v, _): return L("\(v) 米", "\(v) m")
        case .machineCalories(let v, _): return L("\(v) 卡（器械顯示）", "\(v) cal (machine)")
        case .unknown(let raw): return raw.isEmpty ? L("未記錄", "Not recorded") : raw
        }
    }
}
