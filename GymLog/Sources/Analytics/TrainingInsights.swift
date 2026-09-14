import Foundation
import CryptoKit

/// Versioned, deliberately conservative population estimate; never a measurement.
public struct EnergyLine: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var rule: String
    public var planned: Double?
    public var actual: Double?
    public var plannedSeconds: Double?
    public var actualSeconds: Double?
    public var recordedSets: Int
    public var totalSets: Int
    public var facts: [String]
}
public struct EnergyReport: Codable, Equatable {
    public var version = "2026-09-14.1"
    public var weightKg: Double?
    public var weightDate: Date?
    public var lines: [EnergyLine]
    public var planned: Double? { total(lines.map(\.planned)) }
    public var actual: Double? { total(lines.map(\.actual)) }
    public var isPartial: Bool { lines.contains { $0.actual == nil || $0.recordedSets < $0.totalSets } }
    public var planPartial: Bool { lines.contains { $0.planned == nil } }
    private func total(_ values: [Double?]) -> Double? {
        let known = values.compactMap { $0 }; return known.isEmpty ? nil : known.reduce(0, +)
    }
    public static func display(_ value: Double?) -> String {
        value.map { "≈\(Int($0.rounded())) kcal" } ?? L("資料不足", "Insufficient data")
    }
}
public struct TrainingReview: Codable, Equatable {
    public var summary: String
    public var findings: [String]
    public var suggestions: [String]
    public var limitations: [String]
    public var evidenceIDs: [String]
}
public struct InsightArchive: Codable {
    public var fingerprint: String
    public var energy: EnergyReport
    public var review: TrainingReview?
    public var reviewFingerprint: String?
    public var generatedAt: Date?
    public var model: String?
}

@MainActor
public enum TrainingInsights {
    public static let sources = "Compendium 2024: https://pacompendium.com/conditioning-exercise/ ; limitations: https://pacompendium.com/corrected-mets/ ; ACSM 2026: https://acsm.org/resistance-training-guidelines-update-2026/"
    public static let assumptions = L("活動熱量粗估，非實測。力量訓練預設每次 3 秒、未設定休息時 60 秒；組合訓練休息只計一次。WOD 用中等循環訓練作近似。缺少速度的距離、器械卡路里與未知輪次不換算；未填實際不當作零。未包含未記錄的熱身、放鬆及課後消耗。", "Rough active-energy estimate, not measured. Strength defaults: 3 sec/rep and 60 sec rest when unspecified; shared rest counted once. WOD uses moderate circuit activity as a proxy. Distance without pace, machine calories and unknown rounds are not converted. Missing results are not zero. Unrecorded warm-up, cool-down and afterburn excluded.")
    public static func weight(_ client: Client?, date: Date) -> (Double?, Date?) {
        let end = Calendar.current.startOfDay(for: date).addingTimeInterval(86400)
        if let metric = client?.bodyMetrics?.filter({ $0.date < end && validWeight($0.weightKg) }).sorted(by: { $0.date > $1.date }).first {
            return (metric.weightKg, metric.date)
        }
        // An undated starting weight cannot be asserted to belong to an old session.
        if Calendar.current.isDateInToday(date), validWeight(client?.startWeightKg) { return (client?.startWeightKg, nil) }
        return (nil, nil)
    }
    public static func validWeight(_ value: Double?) -> Bool { value.map { $0.isFinite && (20...350).contains($0) } ?? false }
    public static func kcal(met: Double, weight: Double?, seconds: Double?) -> Double? {
        guard validWeight(weight), let w = weight, let s = seconds, s.isFinite, (0...86400).contains(s), met.isFinite, (1...25).contains(met) else { return nil }
        return (met - 1) * 3.5 * w / 200 * s / 60
    }
    public static func seconds(_ quantity: RepTarget) -> Double? {
        let result: Double
        switch quantity {
        case .fixed(let n, _): result = Double(n) * 3
        case .perSide(let l, let r, _): guard l >= 0, r >= 0 else { return nil }; result = (Double(l) + Double(r)) * 3
        case .range(let l, let h, _): guard l >= 0, h >= l else { return nil }; result = (Double(l) + Double(h)) * 1.5
        case .time(let n, _): result = Double(n)
        default: return nil
        }
        return (0...86400).contains(result) ? result : nil
    }
    public static func rule(name: String, pattern: MovementPattern?) -> (String, Double) {
        let n = name.lowercased()
        if n.contains("plank") { return ("02024", 2.8) }
        if (n.contains("kettlebell") || n.contains("kb ")) && n.contains("swing") { return ("02058", 9.8) }
        if pattern == .squat || pattern == .hipHinge { return ("02052", 5) }
        if pattern == .conditioning { return ("02022-proxy", 3.8) }
        if pattern == .unknown || pattern == nil { return ("unmapped", 0) }
        return ("02054", 3.5)
    }
    public static func strength(id: String, name: String, pattern: MovementPattern?, sets: [(load: LoadValue, target: RepTarget, actual: RepTarget)], rest: Double, weight: Double?) -> EnergyLine {
        let (code, met) = rule(name: name, pattern: pattern)
        func duration(_ values: [RepTarget]) -> Double? {
            let known = values.compactMap(seconds)
            guard !known.isEmpty else { return nil }
            let positive = known.filter { $0 > 0 }.count
            return known.reduce(0,+) + Double(max(0, positive - 1)) * rest
        }
        let ps = sets.allSatisfy { seconds($0.target) != nil } ? duration(sets.map(\.target)) : nil; let ac = duration(sets.map(\.actual))
        let facts = sets.enumerated().map { index, s in "set \(index + 1): target=\(JSONColumnCoding.encode(s.target) ?? "unknown"), actual=\(JSONColumnCoding.encode(s.actual) ?? "unknown"), load=\(JSONColumnCoding.encode(s.load) ?? "unknown")" }
        return EnergyLine(id: id, name: name, rule: code, planned: kcal(met: met, weight: weight, seconds: ps), actual: kcal(met: met, weight: weight, seconds: ac), plannedSeconds: ps, actualSeconds: ac, recordedSets: sets.filter { if case .unknown = $0.actual { return false }; return true }.count, totalSets: sets.count, facts: facts)
    }
    public static func wod(id: String, payload: WODPayload, weight: Double?) -> EnergyLine {
        let p = payload.prescription; let r = payload.result
        let planned: Double?
        switch p.format {
        case .amrap: planned = p.timeCapSeconds.map(Double.init)
        case .emom: planned = p.intervalCount.flatMap { count in p.intervalSeconds.map { Double(count) * Double($0) } }
        case .interval: planned = p.intervalCount.flatMap { count in p.intervalSeconds.map { Double(count) * (Double($0) + Double(p.restSeconds ?? 0)) } }
        default: planned = nil // For Time cap is not an expected completion time.
        }
        var actual = r.elapsedSeconds.map(Double.init)
        if r.status == .notRecorded || r.status == .unknown { actual = nil }
        if actual == nil && r.status == .completed && p.format != .forTime { actual = planned }
        return EnergyLine(id: id, name: p.name ?? "WOD", rule: "02035-proxy", planned: kcal(met: 5, weight: weight, seconds: planned), actual: kcal(met: 5, weight: weight, seconds: actual), plannedSeconds: planned, actualSeconds: actual, recordedSets: actual == nil ? 0 : 1, totalSets: 1, facts: [WODSummaryFormatter.compactSummary(payload), "WOD energy is a block estimate, not a sum of machine calories. Individual movement duration is unavailable."])
    }
    public static func draft(_ draft: TodayDraftStore, client: Client) -> EnergyReport {
        let (w,d) = weight(client, date: draft.sessionDate)
        var lines: [EnergyLine] = []
        for (bi,b) in draft.blocks.enumerated() {
            if b.sectionKind == .wod, let wd = b.wodDraft {
                lines.append(wod(id: "b\(bi)", payload: WODPayload(prescription: wd.resolvedPrescription(prescriptionID: "estimate"), result: wd.resolvedResult()), weight: w))
            } else {
                for (ei,e) in b.entries.enumerated() {
                    let shared = b.entries.count > 1
                    let rest = Double(b.restSeconds ?? e.restSeconds ?? 60) / Double(shared ? b.entries.count : 1)
                    lines.append(strength(id: "b\(bi)e\(ei)", name: e.exercise.displayName, pattern: e.exercise.movementPattern, sets: e.resolvedSets(), rest: max(0,rest), weight: w))
                }
            }
        }
        return EnergyReport(weightKg: w, weightDate: d, lines: lines)
    }
    public static func calculate(_ session: WorkoutSession, frozenWeight: Double? = nil, frozenDate: Date? = nil) -> EnergyReport {
        let current = weight(session.client, date: session.date)
        let w = frozenWeight ?? current.0; let d = frozenWeight == nil ? current.1 : frozenDate
        var lines: [EnergyLine] = []
        for b in session.orderedBlocks {
            if b.sectionKind == .wod {
                if let p = b.wodPayload { lines.append(wod(id: "b\(b.order)", payload: p, weight: w)) }
                else { lines.append(EnergyLine(id: "b\(b.order)", name: "WOD", rule: "unknown", recordedSets: 0, totalSets: 1, facts: ["Unsupported WOD payload"])) }
            } else {
                for e in b.orderedEntries {
                    lines.append(strength(id: "b\(b.order)e\(e.order)", name: e.displayName, pattern: e.exercise?.movementPattern, sets: e.orderedSets.map { ($0.load,$0.target,$0.actual) }, rest: Double(max(0,b.restSeconds ?? 60)) / Double(max(1,b.orderedEntries.count)), weight: w))
                }
            }
        }
        return EnergyReport(weightKg: w, weightDate: d, lines: lines)
    }
    public static func decode(_ session: WorkoutSession) -> InsightArchive? {
        guard let s = session.insightJSON else { return nil }; return try? JSONDecoder().decode(InsightArchive.self, from: Data(s.utf8))
    }
    public static func encode(_ archive: InsightArchive) -> String? { (try? JSONEncoder().encode(archive)).flatMap { String(data: $0, encoding: .utf8) } }
    public static func fingerprint(_ report: EnergyReport) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        return SHA256.hash(data: (try? enc.encode(report)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    public static func report(_ session: WorkoutSession) -> EnergyReport {
        let old = decode(session)
        return calculate(session, frozenWeight: old?.energy.weightKg, frozenDate: old?.energy.weightDate)
    }
    public static func capture(_ session: WorkoutSession) {
        let report = report(session); let old = decode(session)
        session.insightJSON = encode(InsightArchive(fingerprint: fingerprint(report), energy: report, review: old?.review, reviewFingerprint: old?.reviewFingerprint, generatedAt: old?.generatedAt, model: old?.model))
    }
}
