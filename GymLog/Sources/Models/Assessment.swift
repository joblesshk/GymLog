import Foundation
import SwiftData

/// Not specified in CONTRACT.md (the seed data's `assessments` array is
/// always empty for this migration -- source `Info` sheet is a blank
/// template). Structure follows 工程规划.md §1.1 / §3.1: the four movement-
/// pattern assessments (Squat / Hip hinge / Push / Pull) that mirror
/// `MovementPattern`. Kept minimal since M1 only needs the model to exist
/// and decode an empty array without error; UI for this is out of scope
/// until M4.
@Model
public final class Assessment {
    @Attribute(.unique) public var id: String
    private var patternRaw: String
    public var date: Date
    public var level: String?
    public var notes: String?

    public var client: Client?

    public init(id: String, pattern: MovementPattern, date: Date, level: String? = nil, notes: String? = nil) {
        self.id = id
        self.patternRaw = pattern.rawValue
        self.date = date
        self.level = level
        self.notes = notes
    }

    public var pattern: MovementPattern {
        get { MovementPattern(rawValue: patternRaw) ?? .unknown }
        set { patternRaw = newValue.rawValue }
    }
}
