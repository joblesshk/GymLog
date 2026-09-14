import Foundation
import SwiftData

/// Not specified in CONTRACT.md (the seed data's `bodyMetrics` array is
/// always empty this period -- 工程规划.md §3.2: "本期留空占位"). Structure
/// follows the field list in 工程规划.md §3.2 ("日期、体重、体脂率、骨骼肌量、
/// BMI、内脏脂肪等级、BMR、TDEE..."). UI is a placeholder empty-state in M1;
/// this model only needs to exist and decode an empty array without error.
@Model
public final class BodyMetric {
    @Attribute(.unique) public var id: String
    public var date: Date
    public var weightKg: Double?
    public var bodyFatPercent: Double?
    public var skeletalMuscleKg: Double?
    public var bmi: Double?
    public var visceralFatLevel: Int?
    public var bmr: Double?
    public var tdee: Double?
    public var bodyFatMassKg: Double?
    public var notes: String?

    public var client: Client?

    public init(
        id: String,
        date: Date,
        weightKg: Double? = nil,
        bodyFatPercent: Double? = nil,
        skeletalMuscleKg: Double? = nil,
        bmi: Double? = nil,
        visceralFatLevel: Int? = nil,
        bmr: Double? = nil,
        tdee: Double? = nil,
        bodyFatMassKg: Double? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.date = date
        self.weightKg = weightKg
        self.bodyFatPercent = bodyFatPercent
        self.skeletalMuscleKg = skeletalMuscleKg
        self.bmi = bmi
        self.visceralFatLevel = visceralFatLevel
        self.bmr = bmr
        self.tdee = tdee
        self.bodyFatMassKg = bodyFatMassKg
        self.notes = notes
    }
}
