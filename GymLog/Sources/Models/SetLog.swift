import Foundation
import SwiftData

/// CONTRACT.md §6. One set-level record.
///
/// MARK: - Persisting `LoadValue` / `RepTarget` in SwiftData
///
/// `LoadValue` (9 branches, §7.6) and `RepTarget` (7 branches, §7.7-7.8) are
/// enums with associated values. SwiftData *can* store a `Codable & Hashable`
/// enum directly as a model property (it goes through an internal
/// transformable/blob encoding), but that path is:
///   - opaque: the on-disk bytes aren't directly inspectable against
///     CONTRACT.md's documented wire format, which matters a lot here since
///     "never lose the raw source text" is the whole point of this app;
///   - not something we want to depend on for predicate/sort behavior as
///     the schema grows through M2/M3;
///   - less predictable for migrations than a plain `String` column.
///
/// Instead, each enum is persisted as the *exact* CONTRACT.md JSON shape,
/// serialized to a `String` column (`loadJSON`, `targetJSON`, `actualJSON`),
/// via `LoadValue`/`RepTarget`'s own `Codable` conformance. A computed
/// property on top decodes lazily and falls back to `.unknown(raw:)` on any
/// failure -- so a corrupted column degrades gracefully instead of crashing
/// or faulting the whole object, consistent with CONTRACT.md §11.4's
/// "never crash on unrecognized data" rule applied one level deeper (to the
/// storage layer, not just enum string decoding).
@Model
public final class SetLog {
    public var setIndex: Int

    private var loadJSON: String
    private var targetJSON: String
    private var actualJSON: String

    public var isInferred: Bool

    public var entry: ExerciseEntry?

    // Perf fix: `load`/`target`/`actual` were plain computed properties --
    // every single read ran a fresh `JSONDecoder().decode()`. Fine in
    // isolation, but real call sites (analytics over hundreds of sets,
    // wheel-render helpers scanning the whole table) read these repeatedly,
    // and a hot enough caller turned "cheap per call" into "thousands of
    // redundant decodes per second" -- see EntryRowView.swift and
    // ExerciseHistoryView.swift for the two confirmed hot paths this fed.
    // `@Transient` so the cache itself is never persisted -- only the JSON
    // string columns are -- and is invalidated by the setters below, so a
    // mutation is never able to serve a stale cached read.
    @Transient private var _cachedLoad: LoadValue?
    @Transient private var _cachedTarget: RepTarget?
    @Transient private var _cachedActual: RepTarget?

    public init(setIndex: Int, load: LoadValue, target: RepTarget, actual: RepTarget, isInferred: Bool) {
        self.setIndex = setIndex
        self.loadJSON = JSONColumnCoding.encode(load) ?? #"{"kind":"unknown","raw":""}"#
        self.targetJSON = JSONColumnCoding.encode(target) ?? #"{"kind":"unknown","raw":""}"#
        self.actualJSON = JSONColumnCoding.encode(actual) ?? #"{"kind":"unknown","raw":""}"#
        self.isInferred = isInferred
    }

    public var load: LoadValue {
        get {
            if let cached = _cachedLoad { return cached }
            let decoded: LoadValue = JSONColumnCoding.decode(loadJSON) ?? .unknown(raw: "")
            _cachedLoad = decoded
            return decoded
        }
        set {
            loadJSON = JSONColumnCoding.encode(newValue) ?? #"{"kind":"unknown","raw":""}"#
            _cachedLoad = newValue
        }
    }

    public var target: RepTarget {
        get {
            if let cached = _cachedTarget { return cached }
            let decoded: RepTarget = JSONColumnCoding.decode(targetJSON) ?? .unknown(raw: "")
            _cachedTarget = decoded
            return decoded
        }
        set {
            targetJSON = JSONColumnCoding.encode(newValue) ?? #"{"kind":"unknown","raw":""}"#
            _cachedTarget = newValue
        }
    }

    public var actual: RepTarget {
        get {
            if let cached = _cachedActual { return cached }
            let decoded: RepTarget = JSONColumnCoding.decode(actualJSON) ?? .unknown(raw: "")
            _cachedActual = decoded
            return decoded
        }
        set {
            actualJSON = JSONColumnCoding.encode(newValue) ?? #"{"kind":"unknown","raw":""}"#
            _cachedActual = newValue
        }
    }
}
