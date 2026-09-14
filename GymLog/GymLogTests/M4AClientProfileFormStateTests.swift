import XCTest
import SwiftData
@testable import GymLogKit

/// CONTRACT-M4.md §4.3 -- the client profile form's round-trip through
/// `ModelContext`. `ClientProfileFormState` (Sources/AppState) is the pure
/// logic `ClientProfileView` binds its `TextField`s to; these tests prove
/// the full cycle (`Client` -> form -> edited form -> `apply(to:)` ->
/// `ModelContext.save()` -> re-fetch) round-trips correctly, without going
/// through SwiftUI. CONTRACT-M4.md's own risk callout is that a save bug
/// here corrupts the real coach's profile, not test fixture data, so this
/// is exercised against both an all-null profile (the real Example Athlete
/// baseline, CONTRACT.md §4) and a fully-populated one.
@MainActor
final class M4AClientProfileFormStateTests: XCTestCase {

    // MARK: - Loading: Client -> form

    /// CONTRACT.md §4's real baseline: Example Athlete's profile is entirely
    /// `nil` except `name`. The form must render that as empty strings, not
    /// crash or show "nil" text.
    func testFormLoadsAllNullClientAsEmptyStrings() {
        let client = Client(id: "cl-1", name: "Example Athlete")
        let form = ClientProfileFormState(client: client)
        XCTAssertEqual(form.name, "Example Athlete")
        XCTAssertEqual(form.phone, "")
        XCTAssertEqual(form.gender, "")
        XCTAssertEqual(form.age, "")
        XCTAssertEqual(form.heightCm, "")
        XCTAssertEqual(form.startWeightKg, "")
        XCTAssertEqual(form.goal, "")
        XCTAssertEqual(form.frequency, "")
        XCTAssertEqual(form.bmr, "")
        XCTAssertEqual(form.tdee, "")
        XCTAssertEqual(form.habits, "")
        XCTAssertEqual(form.medicalHistory, "")
    }

    func testFormLoadsPopulatedClientFields() {
        let client = Client(
            id: "cl-1", name: "Test Client", phone: "13800000000", gender: "男", age: 30,
            heightCm: 178, startWeightKg: 75.5, goal: "增肌", frequency: "每周3次",
            bmr: 1700, tdee: 2600, habits: "作息规律", medicalHistory: "左膝旧伤"
        )
        let form = ClientProfileFormState(client: client)
        XCTAssertEqual(form.phone, "13800000000")
        XCTAssertEqual(form.gender, "男")
        XCTAssertEqual(form.age, "30")
        XCTAssertEqual(form.heightCm, "178")
        XCTAssertEqual(form.startWeightKg, "75.5")
        XCTAssertEqual(form.goal, "增肌")
        XCTAssertEqual(form.bmr, "1700")
        XCTAssertEqual(form.tdee, "2600")
        XCTAssertEqual(form.habits, "作息规律")
        XCTAssertEqual(form.medicalHistory, "左膝旧伤")
    }

    // MARK: - Full round-trip through a real ModelContext

    /// The exact save path `ClientProfileView.save(client:)` runs: fill in
    /// a previously-all-null real client's profile, apply, save, then
    /// re-fetch from a fresh context to prove it actually persisted (not
    /// just mutated the in-memory object).
    func testEditingAndSavingAllNullClientRoundTripsThroughModelContext() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)

        let client = Client(id: "cl-1", name: "Example Athlete") // the real baseline: all-null except name
        context.insert(client)
        try context.save()

        var form = ClientProfileFormState(client: client)
        form.phone = "13900001111"
        form.gender = "男"
        form.age = "35"
        form.heightCm = "175"
        form.startWeightKg = "80"
        form.goal = "减脂"
        form.frequency = "每周4次"
        form.bmr = "1650.5"
        form.tdee = "2500"
        form.habits = "夜跑"
        form.medicalHistory = "无"
        form.apply(to: client)
        try context.save()

        let fetched = try XCTUnwrap(try context.fetch(FetchDescriptor<Client>()).first { $0.id == "cl-1" })
        XCTAssertEqual(fetched.name, "Example Athlete", "name must be preserved")
        XCTAssertEqual(fetched.phone, "13900001111")
        XCTAssertEqual(fetched.gender, "男")
        XCTAssertEqual(fetched.age, 35)
        XCTAssertEqual(fetched.heightCm, 175)
        XCTAssertEqual(fetched.startWeightKg, 80)
        XCTAssertEqual(fetched.goal, "减脂")
        XCTAssertEqual(fetched.frequency, "每周4次")
        XCTAssertEqual(fetched.bmr, 1650.5)
        XCTAssertEqual(fetched.tdee, 2500)
        XCTAssertEqual(fetched.habits, "夜跑")
        XCTAssertEqual(fetched.medicalHistory, "无")
    }

    /// Blanking a previously-filled field must clear it back to `nil`, not
    /// leave a stale value or write an empty string.
    func testClearingAFieldWritesNilNotEmptyString() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = Client(id: "cl-1", name: "Test Client", phone: "12345678900", goal: "增肌")
        context.insert(client)
        try context.save()

        var form = ClientProfileFormState(client: client)
        form.phone = ""
        form.goal = "   " // whitespace-only must also count as empty
        form.apply(to: client)
        try context.save()

        let fetched = try XCTUnwrap(try context.fetch(FetchDescriptor<Client>()).first)
        XCTAssertNil(fetched.phone)
        XCTAssertNil(fetched.goal)
    }

    /// An empty `name` field on save must not blank out the client's real
    /// name (CONTRACT.md §4 requires `name` to be present) -- an accidental
    /// select-all-delete in the name field followed by a stray save must
    /// not corrupt the coach's real client record.
    func testBlankNameOnApplyDoesNotOverwriteExistingName() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = Client(id: "cl-1", name: "Example Athlete")
        context.insert(client)
        try context.save()

        var form = ClientProfileFormState(client: client)
        form.name = "   "
        form.apply(to: client)

        XCTAssertEqual(client.name, "Example Athlete", "blank name must never overwrite the existing name")
    }

    /// Unparseable numeric text (stray characters left in a text field)
    /// must not crash and must fail safe to `nil`, not silently keep a
    /// stale prior value.
    func testUnparseableNumericTextBecomesNilRatherThanCrashingOrStaleValue() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = Client(id: "cl-1", name: "Test Client", age: 30, heightCm: 178)
        context.insert(client)
        try context.save()

        var form = ClientProfileFormState(client: client)
        form.age = "abc"
        form.heightCm = "一米七八"
        form.apply(to: client)

        XCTAssertNil(client.age)
        XCTAssertNil(client.heightCm)
    }
}
