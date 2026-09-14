import Foundation

// MARK: - CONTRACT.md §7 classification enums
//
// All five enums are String-raw-value enums with a graceful fallback for any
// string not defined in CONTRACT.md §7. Per §7's own rule ("所有枚举在 JSON 中
// 一律为小驼峰字符串... 遇到未知值时，两侧都必须降级为兜底分支并记录，不得崩溃"),
// this applies uniformly to all five enums below -- including loadDirection,
// dateOrigin, and blockType, which CONTRACT.md doesn't enumerate an explicit
// fallback case for. Where the contract already lists a catch-all value
// (`unknown` for movementPattern, `other` for equipment) that value IS the
// fallback. Where it doesn't (loadDirection, dateOrigin, blockType), an
// `.unknown` case is added purely as a decode-safety net -- it is never
// something the importer intentionally emits, only something it lands on
// when fed a string outside the contract's domain.

/// §7.1 movementPattern
public enum MovementPattern: String, Codable, CaseIterable, Identifiable {
    case push, pull, squat
    case hipHinge
    case core, carry, conditioning
    case unknown

    public var id: String { rawValue }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let value = MovementPattern(rawValue: raw) {
            self = value
        } else {
            ImportLog.warnUnknownEnum("MovementPattern", value: raw)
            self = .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .push: return L("推", "Push")
        case .pull: return L("拉", "Pull")
        case .squat: return L("蹲", "Squat")
        case .hipHinge: return L("髖鉸鏈", "Hip Hinge")
        case .core: return L("核心", "Core")
        case .carry: return L("負重行走", "Carry")
        case .conditioning: return L("體能", "Conditioning")
        case .unknown: return L("未分類", "Uncategorized")
        }
    }
}

/// §7.2 equipment
public enum Equipment: String, Codable, CaseIterable, Identifiable {
    case barbell, dumbbell, machine, cable, kettlebell, bodyweight, band, sled, ball, ergometer
    case other

    public var id: String { rawValue }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let value = Equipment(rawValue: raw) {
            self = value
        } else {
            ImportLog.warnUnknownEnum("Equipment", value: raw)
            self = .other
        }
    }

    public var displayName: String {
        switch self {
        case .barbell: return L("槓鈴", "Barbell")
        case .dumbbell: return L("啞鈴", "Dumbbell")
        case .machine: return L("器械", "Machine")
        case .cable: return L("繩索", "Cable")
        case .kettlebell: return L("壺鈴", "Kettlebell")
        case .bodyweight: return L("自重", "Bodyweight")
        case .band: return L("彈力帶", "Band")
        case .sled: return L("雪橇", "Sled")
        case .ball: return L("球類", "Ball")
        case .ergometer: return L("有氧器械", "Ergometer")
        case .other: return L("其他", "Other")
        }
    }
}

/// §7.3 loadDirection. Business-critical: assisted exercises get *stronger*
/// as the recorded number goes down (less assistance needed). `.unknown` is
/// a decode-safety fallback only -- CONTRACT.md defines exactly two valid
/// values (`higherIsStronger` default, `lowerIsStronger`). Treat `.unknown`
/// as non-inverted (same trend direction as higherIsStronger) so a bad string
/// never silently flips a chart; it's tracked separately so it surfaces in
/// review rather than masquerading as a confirmed classification.
public enum LoadDirection: String, Codable, CaseIterable, Identifiable {
    case higherIsStronger
    case lowerIsStronger
    case unknown

    public var id: String { rawValue }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let value = LoadDirection(rawValue: raw), value != .unknown {
            self = value
        } else {
            ImportLog.warnUnknownEnum("LoadDirection", value: raw)
            self = .unknown
        }
    }

    /// Whether progress means the recorded number decreasing.
    public var isInverted: Bool { self == .lowerIsStronger }
}

/// §7.4 dateOrigin
public enum DateOrigin: String, Codable, CaseIterable, Identifiable {
    case asRecorded
    case reconstructed
    case unknown

    public var id: String { rawValue }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let value = DateOrigin(rawValue: raw), value != .unknown {
            self = value
        } else {
            ImportLog.warnUnknownEnum("DateOrigin", value: raw)
            self = .unknown
        }
    }
}

/// CONTRACT-M8.md: which unit an exercise's Round-table quantity column
/// actually measures. Not part of CONTRACT.md's frozen §3 Exercise schema --
/// an application-layer classification alongside movementPattern/equipment,
/// documented in CONTRACT-M8.md instead of amending the frozen contract.
/// `.unknown` is a decode-safety fallback only, like loadDirection/dateOrigin
/// -- the classifier always produces one of the other four.
public enum RecordingMetric: String, Codable, CaseIterable, Identifiable {
    case reps
    case time
    case distance
    case rounds
    case unknown

    public var id: String { rawValue }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let value = RecordingMetric(rawValue: raw), value != .unknown {
            self = value
        } else {
            ImportLog.warnUnknownEnum("RecordingMetric", value: raw)
            self = .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .reps: return L("次數", "Reps")
        case .time: return L("時間", "Time")
        case .distance: return L("距離", "Distance")
        case .rounds: return L("輪次", "Rounds")
        case .unknown: return L("未知", "Unknown")
        }
    }
}

/// 2026-09-09 教练要求：「exercise 里面可以分为：Gym 力量训练需要的 exercise
/// 和 CrossFit 所有的 movements」。
///
/// 三个值而不是一个布尔，是因为两类之间本来就是重叠的：Deadlift、Back Squat、
/// Thruster、Wall ball 既是健身房力量课的内容，也是 WOD 里天天写的动作；而
/// Kipping Pull-up、Wall Walk、Double-under 只在 CrossFit 里出现，Machine
/// chest fly、Latpull wide 只在力量课里出现。用布尔的话，「兩者皆是」只能被
/// 塞进其中一边，另一边的筛选就必然漏掉一批常用动作。
///
/// 筛选规则：选「力量」看 `.strength` + `.both`，选「CrossFit」看 `.crossfit`
/// + `.both`。
///
/// 不是 CONTRACT.md §7 的枚举，与 `RecordingMetric` 一样属于应用层分类。未知
/// 字符串退回 `.strength`——这个字段出现之前建立的每一行（包括教练自己新增的
/// 动作）默认就是力量，与它们的实际来源一致。
public enum ExerciseDiscipline: String, Codable, CaseIterable, Identifiable {
    case strength
    case crossfit
    case both

    public var id: String { rawValue }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let value = ExerciseDiscipline(rawValue: raw) {
            self = value
        } else {
            ImportLog.warnUnknownEnum("ExerciseDiscipline", value: raw)
            self = .strength
        }
    }

    public var displayName: String {
        switch self {
        case .strength: return L("力量", "Strength")
        case .crossfit: return "CrossFit"
        case .both: return L("兩者皆是", "Both")
        }
    }

    /// 这个动作是否属于某一套体系。`.both` 的动作对「力量」和「CrossFit」两
    /// 个筛选都为真——这正是三值枚举存在的理由。
    public func belongs(to discipline: ExerciseDiscipline) -> Bool {
        self == discipline || self == .both
    }
}

/// §7.5 blockType
public enum BlockType: String, Codable, CaseIterable, Identifiable {
    case single, superset, dropset, circuit
    case unknown

    public var id: String { rawValue }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let value = BlockType(rawValue: raw), value != .unknown {
            self = value
        } else {
            ImportLog.warnUnknownEnum("BlockType", value: raw)
            self = .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .single: return L("單組", "Single")
        case .superset: return L("超級組", "Superset")
        case .dropset: return L("遞減組", "Dropset")
        case .circuit: return L("循環組", "Circuit")
        case .unknown: return L("未知類型", "Unknown Type")
        }
    }
}
