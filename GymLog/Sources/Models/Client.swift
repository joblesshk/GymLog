import Foundation
import SwiftData

/// CONTRACT.md §4. Source workbook's `Info` sheet is a blank template for
/// this migration, so every field except `name` legitimately arrives as
/// null -- the model must tolerate a fully-empty profile without special
/// casing.
@Model
public final class Client {
    @Attribute(.unique) public var id: String
    public var name: String
    public var phone: String?
    public var gender: String?
    public var age: Int?
    public var heightCm: Double?
    public var startWeightKg: Double?
    public var goal: String?
    public var frequency: String?
    public var bmr: Double?
    public var tdee: Double?
    public var habits: String?
    public var medicalHistory: String?

    @Relationship(deleteRule: .cascade, inverse: \Assessment.client)
    public var assessments: [Assessment]? = []

    @Relationship(deleteRule: .cascade, inverse: \BodyMetric.client)
    public var bodyMetrics: [BodyMetric]? = []

    @Relationship(deleteRule: .cascade, inverse: \WorkoutSession.client)
    public var sessions: [WorkoutSession]? = []

    public init(
        id: String,
        name: String,
        phone: String? = nil,
        gender: String? = nil,
        age: Int? = nil,
        heightCm: Double? = nil,
        startWeightKg: Double? = nil,
        goal: String? = nil,
        frequency: String? = nil,
        bmr: Double? = nil,
        tdee: Double? = nil,
        habits: String? = nil,
        medicalHistory: String? = nil
    ) {
        self.id = id
        self.name = name
        self.phone = phone
        self.gender = gender
        self.age = age
        self.heightCm = heightCm
        self.startWeightKg = startWeightKg
        self.goal = goal
        self.frequency = frequency
        self.bmr = bmr
        self.tdee = tdee
        self.habits = habits
        self.medicalHistory = medicalHistory
    }

    /// CONTRACT-M5.md §1: a freshly-added client (via the nav bar "+") has
    /// `name == ""` until the coach fills in the profile -- every UI call
    /// site that displays a client's name (not the ones editing it) should
    /// read this instead of `name` directly, so "默认用户" is consistent
    /// everywhere rather than each screen inventing its own fallback.
    public var displayName: String {
        name.isEmpty ? L("默認用戶", "Default User") : name
    }
}
