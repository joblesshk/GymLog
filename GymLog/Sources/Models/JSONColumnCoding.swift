import Foundation

/// Shared encode/decode for the "persist a Codable enum as a JSON string
/// column" pattern used by `SetLog` (`LoadValue`/`RepTarget`) and
/// `TemplateExerciseSlot` (`RepTarget`) -- see `SetLog.swift`'s persistence
/// note for why a JSON string column instead of SwiftData's built-in
/// transformable-enum storage.
///
/// Ponytail review finding: this was two byte-identical private static
/// pairs, one per model file, justified by a comment claiming SwiftData
/// `@Model` types can't share stored-property mixins -- true for stored
/// properties, but these functions touch none; they're plain generic
/// (de)serialization with no reason to be duplicated.
enum JSONColumnCoding {
    static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode<T: Decodable>(_ json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
