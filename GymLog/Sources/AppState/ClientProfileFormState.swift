import Foundation
import SwiftData

/// CONTRACT-M4.md §4.3 -- local edit buffer for `Client`'s optional fields,
/// used by `ClientProfileView` (Sources/Views/Clients). Lives in `AppState`
/// (GymLogKit), not the view itself, for the same reason `EntryDraft`/
/// `PrefillResolver` do: pure Foundation logic with no SwiftUI import, so
/// `GymLogTests` can `@testable import GymLogKit` and verify the
/// string<->Int/Double round-trip directly, without needing a SwiftUI host.
///
/// Fields are staged as plain `String`s so `TextField` bindings never fight
/// `nil`/type conversion; `apply(to:)` is the single place that writes back
/// to the live `Client` object, called only on an explicit 保存 tap
/// (CONTRACT-M4.md's risk callout: a save bug here corrupts the real
/// coach's profile, not test fixture data).
public struct ClientProfileFormState: Equatable {
    public var name: String
    public var phone: String
    public var gender: String
    public var age: String
    public var heightCm: String
    public var startWeightKg: String
    public var goal: String
    public var frequency: String
    public var bmr: String
    public var tdee: String
    public var habits: String
    public var medicalHistory: String

    public init(
        name: String = "", phone: String = "", gender: String = "", age: String = "",
        heightCm: String = "", startWeightKg: String = "", goal: String = "",
        frequency: String = "", bmr: String = "", tdee: String = "",
        habits: String = "", medicalHistory: String = ""
    ) {
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

    public init(client: Client) {
        name = client.name
        phone = client.phone ?? ""
        gender = client.gender ?? ""
        age = client.age.map(String.init) ?? ""
        heightCm = client.heightCm.map { Self.formatDouble($0) } ?? ""
        startWeightKg = client.startWeightKg.map { Self.formatDouble($0) } ?? ""
        goal = client.goal ?? ""
        frequency = client.frequency ?? ""
        bmr = client.bmr.map { Self.formatDouble($0) } ?? ""
        tdee = client.tdee.map { Self.formatDouble($0) } ?? ""
        habits = client.habits ?? ""
        medicalHistory = client.medicalHistory ?? ""
    }

    /// Writes every field back onto `client`. Blank strings become `nil`
    /// (except `name`, which keeps the client's existing name rather than
    /// being blanked out by an accidental empty save -- CONTRACT.md §4
    /// requires `name` to always be non-empty). Unparseable numeric text
    /// (e.g. leftover non-digit characters) becomes `nil` rather than
    /// silently keeping a stale value or crashing.
    public func apply(to client: Client) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            client.name = trimmedName
        }
        client.phone = Self.nilIfEmpty(phone)
        client.gender = Self.nilIfEmpty(gender)
        client.age = Int(age.trimmingCharacters(in: .whitespaces))
        client.heightCm = Double(heightCm.trimmingCharacters(in: .whitespaces))
        client.startWeightKg = Double(startWeightKg.trimmingCharacters(in: .whitespaces))
        client.goal = Self.nilIfEmpty(goal)
        client.frequency = Self.nilIfEmpty(frequency)
        client.bmr = Double(bmr.trimmingCharacters(in: .whitespaces))
        client.tdee = Double(tdee.trimmingCharacters(in: .whitespaces))
        client.habits = Self.nilIfEmpty(habits)
        client.medicalHistory = Self.nilIfEmpty(medicalHistory)
    }

    private static func nilIfEmpty(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func formatDouble(_ d: Double) -> String {
        d == d.rounded() ? String(format: "%.0f", d) : String(d)
    }
}
