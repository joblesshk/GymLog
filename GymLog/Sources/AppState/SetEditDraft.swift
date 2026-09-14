import Foundation

/// One `SetLog`'s editable fields as a plain value type, used by
/// `SessionEditSheet` (2026-09-07 审阅 B01: 历史课次编辑取消必须零写入).
///
/// The previous history-edit sheet wrote every keystroke straight into the
/// live `SetLog` -- `set.load =`/`set.target =`/`set.actual =` inside each
/// `Binding`'s setter -- and "Cancel" only called `dismiss()`, never undoing
/// those writes. Since `SetLog` is a SwiftData reference type, a cancelled
/// edit stayed live in `modelContext` until ANY subsequent
/// `modelContext.save()` -- triggered by completely unrelated work
/// elsewhere in the app -- silently persisted it.
///
/// Living in GymLogKit (not the view file) is deliberate: this type's
/// validation/apply logic is the actual bug-fix surface and needs direct
/// unit tests (`SetEditDraftTests`) independent of any SwiftUI rendering,
/// same rationale as `EntryDraft`/`TodayDraftSnapshot` in this directory.
///
/// Deliberately holds text (not parsed numbers) for every field: an
/// in-progress "42." or an emptied field must round-trip through a
/// `TextField` without the draft rejecting or reformatting it mid-keystroke
/// -- validation only runs at `validationError`/`apply(to:)` time, not on
/// every keystroke.
public struct SetEditDraft: Equatable {
    public enum Kind: Equatable {
        case fixed
        case time
        case distance
        case rounds
        case perSide
        /// Load/target/actual combination this editor doesn't support
        /// in-line (bodyweight/band/machine-stack/pin-load/sled loads,
        /// `.range` targets) -- shown read-only by the caller.
        case unsupported
    }

    /// `nil` when the set's load isn't `.absolute` -- weight isn't editable
    /// for that set, but its target/actual quantity still might be.
    public var kgText: String?
    public var targetPrimaryText: String
    /// Only used by `.perSide` (the right-side rep count).
    public var targetSecondaryText: String?
    public var actualPrimaryText: String
    public var actualSecondaryText: String?
    public let kind: Kind

    public init(set: SetLog) {
        if case .absolute(let kg, _) = set.load {
            kgText = Self.formatNumber(kg)
        } else {
            kgText = nil
        }
        switch (set.target, set.actual) {
        case (.fixed(let t, _), .fixed(let a, _)):
            kind = .fixed
            targetPrimaryText = "\(t)"; actualPrimaryText = "\(a)"
            targetSecondaryText = nil; actualSecondaryText = nil
        case (.time(let t, _), .time(let a, _)):
            kind = .time
            targetPrimaryText = "\(t)"; actualPrimaryText = "\(a)"
            targetSecondaryText = nil; actualSecondaryText = nil
        case (.distance(let t, _), .distance(let a, _)):
            kind = .distance
            targetPrimaryText = "\(t)"; actualPrimaryText = "\(a)"
            targetSecondaryText = nil; actualSecondaryText = nil
        case (.rounds(let t, _), .rounds(let a, _)):
            kind = .rounds
            targetPrimaryText = "\(t)"; actualPrimaryText = "\(a)"
            targetSecondaryText = nil; actualSecondaryText = nil
        case (.perSide(let tl, let tr, _), .perSide(let al, let ar, _)):
            kind = .perSide
            targetPrimaryText = "\(tl)"; targetSecondaryText = "\(tr)"
            actualPrimaryText = "\(al)"; actualSecondaryText = "\(ar)"
        default:
            kind = .unsupported
            targetPrimaryText = ""; actualPrimaryText = ""
            targetSecondaryText = nil; actualSecondaryText = nil
        }
    }

    public var isEditable: Bool { kind != .unsupported }
    public var isWeightEditable: Bool { kgText != nil }

    /// Sane upper bound against fat-fingered digit floods -- not a
    /// meaningful training limit, just a guard against obviously-wrong
    /// input (CONTRACT.md §11.4's "never crash on unrecognized data" spirit
    /// applied to hand-typed corrections too).
    public static let maxQuantity = 100_000
    public static let maxKg = 2_000.0

    /// `nil` when every editable field on this set is valid; otherwise a
    /// short, user-facing reason. Checked before Save is enabled AND again
    /// right before anything is applied to the model.
    public var validationError: String? {
        if isWeightEditable {
            guard let kg = Double(kgText ?? ""), kg.isFinite, kg >= 0, kg <= Self.maxKg else {
                return L("重量需為 0～\(Int(Self.maxKg)) 之間的數字", "Weight must be a number between 0 and \(Int(Self.maxKg))")
            }
        }
        func validQuantity(_ text: String) -> Bool {
            guard let value = Int(text), value >= 0, value <= Self.maxQuantity else { return false }
            return true
        }
        switch kind {
        case .fixed, .time, .distance, .rounds:
            guard validQuantity(targetPrimaryText), validQuantity(actualPrimaryText) else {
                return L("數值需為 0～\(Self.maxQuantity) 之間的整數", "Value must be a whole number between 0 and \(Self.maxQuantity)")
            }
        case .perSide:
            guard validQuantity(targetPrimaryText), validQuantity(targetSecondaryText ?? ""),
                  validQuantity(actualPrimaryText), validQuantity(actualSecondaryText ?? "") else {
                return L("左右次數需為 0～\(Self.maxQuantity) 之間的整數", "Left/right reps must be whole numbers between 0 and \(Self.maxQuantity)")
            }
        case .unsupported:
            return nil
        }
        return nil
    }

    /// Only meant to be called after `validationError == nil` -- every
    /// `Int`/`Double` parse below is then known to succeed. Left as
    /// best-effort (skips a field silently) rather than throwing if called
    /// with an invalid draft anyway, since the actual caller always guards
    /// on `validationError` for every draft before applying any of them.
    public func apply(to set: SetLog) {
        if isWeightEditable, let kg = Double(kgText ?? "") {
            set.load = .absolute(kg: kg, raw: kgText ?? "")
        }
        switch kind {
        case .fixed:
            if let t = Int(targetPrimaryText) { set.target = .fixed(value: t, raw: targetPrimaryText) }
            if let a = Int(actualPrimaryText) { set.actual = .fixed(value: a, raw: actualPrimaryText) }
        case .time:
            if let t = Int(targetPrimaryText) { set.target = .time(seconds: t, raw: targetPrimaryText) }
            if let a = Int(actualPrimaryText) { set.actual = .time(seconds: a, raw: actualPrimaryText) }
        case .distance:
            if let t = Int(targetPrimaryText) { set.target = .distance(meters: t, raw: targetPrimaryText) }
            if let a = Int(actualPrimaryText) { set.actual = .distance(meters: a, raw: actualPrimaryText) }
        case .rounds:
            if let t = Int(targetPrimaryText) { set.target = .rounds(count: t, raw: targetPrimaryText) }
            if let a = Int(actualPrimaryText) { set.actual = .rounds(count: a, raw: actualPrimaryText) }
        case .perSide:
            if let tl = Int(targetPrimaryText), let tr = Int(targetSecondaryText ?? "") {
                set.target = .perSide(left: tl, right: tr, raw: "\(tl),\(tr)")
            }
            if let al = Int(actualPrimaryText), let ar = Int(actualSecondaryText ?? "") {
                set.actual = .perSide(left: al, right: ar, raw: "\(al),\(ar)")
            }
        case .unsupported:
            break
        }
    }

    public static func formatNumber(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}
