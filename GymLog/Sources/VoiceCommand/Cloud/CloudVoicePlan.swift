import Foundation

/// Wire contract: the model proposes only these operations. Defaults are resolved locally.
public struct CloudVoicePlan: Codable, Equatable {
    public var version: Int
    public var assumptions: [String]?
    public var clarification: String?
    public var operations: [CloudVoiceOperation]
    public init(version: Int = 1, clarification: String? = nil, assumptions: [String]? = nil, operations: [CloudVoiceOperation]) {
        self.assumptions = assumptions; self.version = version; self.clarification = clarification; self.operations = operations
    }
}

public struct CloudVoiceOperation: Codable, Equatable {
    public enum Kind: String, Codable {
        case startSession, addExercise, updatePlan, recordActual, replaceExercise, removeExercise
        case moveExercise, composeSuperset, dissolveSuperset, setRest, undo
    }
    public var kind: Kind
    public var evidence: String
    /// Existing entry UUID or earlier add's ref. Never a display name.
    public var target: String?
    public var exerciseID: String?
    public var ref: String?
    public var targets: [String]?
    public var after: String?
    /// 1-based physical set; -1 means the final set.
    public var setIndex: Int?
    public var sets: Int?
    public var quantity: Double?
    public var unit: String?
    public var load: CloudVoiceLoad?
    public var restSeconds: Int?
    public init(kind: Kind, evidence: String, target: String? = nil, exerciseID: String? = nil,
                ref: String? = nil, targets: [String]? = nil, after: String? = nil,
                setIndex: Int? = nil, sets: Int? = nil, quantity: Double? = nil,
                unit: String? = nil, load: CloudVoiceLoad? = nil, restSeconds: Int? = nil) {
        self.kind = kind; self.evidence = evidence; self.target = target; self.exerciseID = exerciseID
        self.ref = ref; self.targets = targets; self.after = after; self.setIndex = setIndex
        self.sets = sets; self.quantity = quantity; self.unit = unit; self.load = load; self.restSeconds = restSeconds
    }
}

public struct CloudVoiceLoad: Codable, Equatable {
    public var kind: String
    public var value: Double?
    public var unit: String?
    public init(kind: String, value: Double? = nil, unit: String? = nil) { self.kind = kind; self.value = value; self.unit = unit }
    public func resolved() throws -> LoadValue {
        if kind == "bodyweight", value == nil, unit == nil { return .bodyweight(raw: "BW") }
        guard let value, value.isFinite, value >= 0, let unit, ["kg", "lb"].contains(unit) else {
            throw CloudVoiceError.message("重量或單位不完整，請說明公斤或磅。")
        }
        let kg = unit == "lb" ? value * 0.45359237 : value
        guard kg <= 1000 else { throw CloudVoiceError.message("重量超出可記錄範圍。") }
        let raw = "\(value) \(unit)"
        switch kind {
        case "absolute": return .absolute(kg: kg, raw: raw)
        case "perSide": return .perSide(kg: kg, raw: raw)
        case "assisted": return .assisted(kg: kg, raw: raw)
        default: throw CloudVoiceError.message("不支援這種重量設定，請用手動編輯。")
        }
    }
}
