import Foundation
import CryptoKit

/// The text representation used when a messaging application strips the
/// `.gymlogshare` attachment.  The JSON is deliberately complete: a recipient
/// can copy the whole message, including the explanatory prose, back into
/// GymLog and recover the same package.
public enum ExchangeTextCodec {
    public static let jsonStart = "--- GYMLOG EXCHANGE JSON v1 ---"
    public static let jsonEnd = "--- END GYMLOG EXCHANGE JSON ---"
    public static let maxTextBytes = ExchangeImporter.maxFileSize

    public enum CodecError: LocalizedError, Equatable {
        case empty
        case tooLarge(Int)
        case truncated
        case malformedJSON
        case multiplePackages
        case unsupportedLegacy(String)

        public var errorDescription: String? {
            switch self {
            case .empty: return "The pasted text is empty."
            case .tooLarge(let count): return "The pasted text is too large (\(count) bytes; limit \(ExchangeTextCodec.maxTextBytes))."
            case .truncated: return "The GymLog package is incomplete or truncated. Copy the complete message, including its JSON section."
            case .malformedJSON: return "The GymLog JSON section is damaged. Copy the complete message again; it cannot be imported as a legacy summary."
            case .multiplePackages: return "The message contains more than one GymLog package. Paste one package at a time."
            case .unsupportedLegacy(let detail): return "This older summary cannot be imported safely: \(detail)"
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// Produces a readable message followed by one complete, versioned JSON
    /// package. Keep this independent of AppLanguage so the Kit remains
    /// Foundation-only and messages are stable across sender locales.
    public static func encode(_ package: ExchangePackage, readablePrefix: String? = nil) throws -> String {
        let data = try encoder.encode(package)
        guard let json = String(data: data, encoding: .utf8) else { throw CodecError.malformedJSON }
        let language = LanguageContext.current
        let kind = language.t(package.payloadKind == .plan ? "訓練計劃" : "訓練結果", package.payloadKind == .plan ? "Training Plan" : "Training Results")
        let readableLines = readablePrefix.map {
            [$0, "", language.t("以下是完整分享資料，請保留整段文字。", "The complete share data follows; keep the entire message.")]
        } ?? readablePackageLines(package, kind: kind, language: language)
        let readable = (readableLines + [
            "",
            jsonStart,
            json,
            jsonEnd
        ]).joined(separator: "\n")
        try validateByteCount(readable)
        return readable
    }

    public static func data(_ package: ExchangePackage) throws -> Data {
        Data(try encode(package).utf8)
    }

    /// Decodes UTF-8, BOM-prefixed UTF-8, and reasonable UTF-16 text files.
    /// A file's actual bytes are checked after reading, rather than relying on
    /// filesystem metadata that may be unavailable for security-scoped URLs.
    public static func decode(data: Data) throws -> ExchangePackage {
        guard data.count <= maxTextBytes else { throw CodecError.tooLarge(data.count) }
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) { text = String(data: data, encoding: .utf16LittleEndian) }
        else if data.starts(with: [0xFE, 0xFF]) { text = String(data: data, encoding: .utf16BigEndian) }
        else { text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) }
        guard let text else { throw CodecError.truncated }
        return try decode(text)
    }

    public static func decode(_ text: String) throws -> ExchangePackage {
        try validateByteCount(text)
        let normalized = text.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CodecError.empty }

        let hasMarker = normalized.contains(jsonStart) || normalized.contains(jsonEnd)
        if hasMarker {
            let startCount = normalized.components(separatedBy: jsonStart).count - 1
            let endCount = normalized.components(separatedBy: jsonEnd).count - 1
            if startCount > 1 || endCount > 1 { throw CodecError.multiplePackages }
            guard startCount == 1, endCount == 1,
                  let start = normalized.range(of: jsonStart), let end = normalized.range(of: jsonEnd, range: start.upperBound..<normalized.endIndex), start.upperBound <= end.lowerBound else {
                throw CodecError.truncated
            }
            let body = normalized[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { throw CodecError.truncated }
            if normalized.range(of: jsonStart, range: end.upperBound..<normalized.endIndex) != nil ||
                normalized.range(of: jsonEnd, range: end.upperBound..<normalized.endIndex) != nil { throw CodecError.multiplePackages }
            return try parseJSON(String(body))
        }

        // Backward compatibility: pure JSON and JSON surrounded by chat prose.
        let candidates = balancedJSONObjectCandidates(in: normalized)
        if candidates.count > 1 { throw CodecError.multiplePackages }
        if let candidate = candidates.first { return try parseJSON(candidate) }
        return try parseLegacySummary(normalized)
    }

    private static func validateByteCount(_ text: String) throws {
        let count = text.lengthOfBytes(using: .utf8)
        guard count <= maxTextBytes else { throw CodecError.tooLarge(count) }
    }

    private static func parseJSON(_ json: String) throws -> ExchangePackage {
        guard let data = json.data(using: .utf8) else { throw CodecError.malformedJSON }
        do { return try ExchangeImporter.parse(data) }
        catch let error as ExchangeImporter.ImportError { throw error }
        catch { throw CodecError.malformedJSON }
    }

    private static func readablePackageLines(_ package: ExchangePackage, kind: String, language: AppLanguage) -> [String] {
        var lines = [
            "GymLog · \(kind)",
            language.t("學員：\(package.client.displayName)", "Client: \(package.client.displayName)"),
            language.t("課次：\(package.sessions.count)", "Sessions: \(package.sessions.count)"),
            language.t("格式版本：\(package.formatVersion)", "Format version: \(package.formatVersion)"),
            language.t("請將整段文字貼回 GymLog 以匯入。", "Paste the entire message back into GymLog to import it.")
        ]
        for session in package.sessions {
            lines.append("")
            lines.append(language.t("訓練日 \(session.trainingLocalDate) · 第 \(session.weekNumber) 週", "Session \(session.trainingLocalDate) · Week \(session.weekNumber)"))
            for block in session.blocks.sorted(by: { $0.order < $1.order }) {
                if block.sectionKind == .wod {
                    if let raw = block.wodPayloadRawJSON,
                       let data = raw.data(using: .utf8),
                       let payload = try? JSONDecoder().decode(WODPayload.self, from: data) {
                        lines.append("  WOD")
                        lines.append(contentsOf: WODSummaryFormatter.detailLines(payload).map { "  \($0)" })
                    } else {
                        lines.append(language.t("  WOD（完整處方內容無法在此版本展開）", "  WOD (full prescription details cannot be expanded by this version)"))
                    }
                }
                for entry in block.entries.sorted(by: { $0.order < $1.order }) {
                    let sets = entry.sets.sorted(by: { $0.setIndex < $1.setIndex }).map { set in
                        let quantity = package.payloadKind == .results ? (set.actual ?? .unknown(raw: "not recorded")) : set.target
                        return "\(set.load.displayText) × \(quantity.displayText)"
                    }.joined(separator: ", ")
                    lines.append("  • \(entry.exerciseRef.canonicalName): \(sets)")
                }
            }
        }
        return lines
    }

    private static func balancedJSONObjectCandidates(in text: String) -> [String] {
        var candidates: [String] = []
        var start: String.Index?
        var depth = 0
        var inString = false
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" { inString = true; continue }
            if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}" && depth > 0 {
                depth -= 1
                if depth == 0, let objectStart = start {
                    candidates.append(String(text[objectStart...index]))
                    // Trim the consumed object and continue scanning by
                    // design; a second top-level object is an explicit error.
                    start = nil
                }
            }
        }
        return candidates
    }

    // MARK: Legacy SessionSummaryGenerator format

    private static func parseLegacySummary(_ text: String) throws -> ExchangePackage {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let header = lines.first else { throw CodecError.empty }
        let patterns = [
            try! NSRegularExpression(pattern: "^(.+) 訓練摘要 · (\\d{4}-\\d{2}-\\d{2}) · 第(\\d+)週$"),
            try! NSRegularExpression(pattern: "^(.+) — Session Summary · (\\d{4}-\\d{2}-\\d{2}) · Week (\\d+)$")
        ]
        var clientName: String?, date: String?, week: Int?
        for regex in patterns {
            let range = NSRange(header.startIndex..<header.endIndex, in: header)
            if let match = regex.firstMatch(in: header, range: range), match.numberOfRanges == 4 {
                clientName = capture(header, match, 1); date = capture(header, match, 2); week = Int(capture(header, match, 3) ?? "")
                break
            }
        }
        guard let clientName, let date, let week else { throw CodecError.unsupportedLegacy("the title is not a supported SessionSummaryGenerator format") }

        var blocks: [ExchangeBlockDTO] = []
        var index = 1
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { index += 1; continue }
            if line.contains("WOD") || line.hasPrefix("AMRAP") || line.hasPrefix("For Time") || line.hasPrefix("EMOM") || line.hasPrefix("間歇") {
                throw CodecError.unsupportedLegacy("WOD summaries do not contain enough structured prescription data")
            }
            guard line.last == ":" || line.last == "：" else { throw CodecError.unsupportedLegacy("an unsupported block or note line was found") }
            let blockLabel = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
            guard let blockType = blockType(for: blockLabel) else { throw CodecError.unsupportedLegacy("unknown block type '\(blockLabel)'") }
            index += 1
            var entries: [ExchangeEntryDTO] = []
            while index < lines.count {
                let entryLine = lines[index].trimmingCharacters(in: .whitespaces)
                guard entryLine.hasPrefix("•") else { break }
                guard let colon = entryLine.firstIndex(of: "：") ?? entryLine.firstIndex(of: ":") else { throw CodecError.unsupportedLegacy("an exercise row has no separator") }
                let left = String(entryLine[entryLine.index(after: entryLine.startIndex)..<colon]).trimmingCharacters(in: .whitespaces)
                let right = entryLine[entryLine.index(after: colon)...]
                let name = left.replacingOccurrences(of: "（PR）", with: "").replacingOccurrences(of: " (PR)", with: "").trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { throw CodecError.unsupportedLegacy("an exercise row has no name") }
                let setParts = right.split(whereSeparator: { $0 == "、" || $0 == "," }).map(String.init)
                guard !setParts.isEmpty else { throw CodecError.unsupportedLegacy("exercise '\(name)' has no set result") }
                let sets = try setParts.enumerated().map { try parseLegacySet($0.element, index: $0.offset, exercise: name) }
                entries.append(ExchangeEntryDTO(order: entries.count, exerciseRef: ExchangeExerciseRef(exerciseID: "legacy-\(fingerprint(name))", canonicalName: name, nameZh: "", recordingMetric: metricFor(sets), equipment: .other), plannedSets: sets.count, sets: sets))
                index += 1
            }
            guard !entries.isEmpty else { throw CodecError.unsupportedLegacy("block '\(blockLabel)' has no supported exercise rows") }
            blocks.append(ExchangeBlockDTO(order: blocks.count, blockType: blockType, restSeconds: nil, sectionKind: .strength, entries: entries, wodPayloadRawJSON: nil))
        }
        guard !blocks.isEmpty else { throw CodecError.unsupportedLegacy("the summary contains no exercise blocks") }
        let ref = ExchangeClientRef(remoteClientID: "legacy-\(fingerprint(clientName))", displayName: clientName)
        let session = ExchangeSessionDTO(recordID: "legacy-\(fingerprint(text))", sourcePlanID: nil, trainingLocalDate: date, weekNumber: week, plannedDurationMinutes: nil, blocks: blocks)
        let digest = ExchangeDigest.compute(payloadKind: .results, client: ref, sessions: [session], exercises: [])
        let package = ExchangePackage(formatVersion: 1, packageID: "legacy-\(fingerprint(text))", createdAt: Date(), originInstallationID: "gymlog-legacy-summary", payloadKind: .results, client: ref, sessions: [session], exercises: [], contentDigestSHA256: digest)
        let issues = ExchangeImporter.validateStructure(package)
        guard issues.isEmpty else {
            throw CodecError.unsupportedLegacy("the summary failed validation: \(issues.joined(separator: "; "))")
        }
        return package
    }

    private static func parseLegacySet(_ text: String, index: Int, exercise: String) throws -> ExchangeSetDTO {
        let parts = text.split(separator: "×", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw CodecError.unsupportedLegacy("exercise '\(exercise)' has an unsupported set format") }
        let load = parseLoad(parts[0])
        let actual = parseQuantity(parts[1])
        return ExchangeSetDTO(setIndex: index, load: load, target: .unknown(raw: "legacy summary has no target"), actual: actual)
    }

    private static func parseLoad(_ text: String) -> LoadValue {
        let raw = text.trimmingCharacters(in: .whitespaces)
        if let match = raw.range(of: "^([0-9]+(?:\\.[0-9]+)?)\\s*(kg|公斤)$", options: [.regularExpression, .caseInsensitive]) {
            let matched = String(raw[match])
            if let value = Double(matched.replacingOccurrences(of: "kg", with: "", options: .caseInsensitive).replacingOccurrences(of: "公斤", with: "").trimmingCharacters(in: .whitespaces)) { return .absolute(kg: value, raw: raw) }
        }
        if let match = raw.range(of: "^(?:單側\\s*)?([0-9]+(?:\\.[0-9]+)?)\\s*kg(?:/side)?$", options: [.regularExpression, .caseInsensitive]), let value = Double(String(raw[match]).replacingOccurrences(of: "單側", with: "").replacingOccurrences(of: "/side", with: "", options: .caseInsensitive).replacingOccurrences(of: "kg", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces)) {
            return raw.lowercased().contains("/side") || raw.hasPrefix("單側") ? .perSide(kg: value, raw: raw) : .absolute(kg: value, raw: raw)
        }
        if let match = raw.range(of: "^(輔助|assisted)\\s*-?([0-9]+(?:\\.[0-9]+)?)\\s*kg$", options: [.regularExpression, .caseInsensitive]) {
            let matched = String(raw[match]).replacingOccurrences(of: "輔助", with: "").replacingOccurrences(of: "assisted", with: "", options: .caseInsensitive).replacingOccurrences(of: "kg", with: "", options: .caseInsensitive).replacingOccurrences(of: "-", with: "")
            if let value = Double(matched.trimmingCharacters(in: .whitespaces)) { return .assisted(kg: value, raw: raw) }
        }
        if raw.range(of: "^(BW|bodyweight|徒手|自重)$", options: [.regularExpression, .caseInsensitive]) != nil { return .bodyweight(raw: raw) }
        return .unknown(raw: raw)
    }

    private static func parseQuantity(_ text: String) -> RepTarget {
        let raw = text.trimmingCharacters(in: .whitespaces)
        if let match = raw.range(of: "^([0-9]+)-([0-9]+)\\s*(次|reps?)$", options: [.regularExpression, .caseInsensitive]) {
            let values = String(raw[match]).split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if values.count == 2 { return .range(low: values[0], high: values[1], raw: raw) }
        }
        if let match = raw.range(of: "^([0-9]+)\\s*(次|reps?)$", options: [.regularExpression, .caseInsensitive]), let value = Int(String(raw[match]).components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) { return .fixed(value: value, raw: raw) }
        if let match = raw.range(of: "^([0-9]+)\\s*(輪|rounds?)$", options: [.regularExpression, .caseInsensitive]), let value = Int(String(raw[match]).components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) { return .rounds(count: value, raw: raw) }
        if let match = raw.range(of: "^([0-9]+)\\s*(米|m)$", options: [.regularExpression, .caseInsensitive]), let value = Int(String(raw[match]).components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) { return .distance(meters: value, raw: raw) }
        if let match = raw.range(of: "^([0-9]{1,3}):([0-9]{2})$", options: [.regularExpression]) {
            let p = raw[match].split(separator: ":").compactMap { Int($0) }
            if p.count == 2 { return .time(seconds: p[0] * 60 + p[1], raw: raw) }
        }
        if let match = raw.range(of: "^左右各([0-9]+)次$", options: [.regularExpression]), let value = Int(String(raw[match]).components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) { return .perSide(left: value, right: value, raw: raw) }
        if let match = raw.range(of: "^左([0-9]+)\\s*右([0-9]+)次$", options: [.regularExpression]) {
            let values = String(raw[match]).split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if values.count == 2 { return .perSide(left: values[0], right: values[1], raw: raw) }
        }
        if let match = raw.range(of: "^([0-9]+)\\s+reps?/side$", options: [.regularExpression, .caseInsensitive]), let value = Int(String(raw[match]).components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) { return .perSide(left: value, right: value, raw: raw) }
        if let match = raw.range(of: "^L([0-9]+)\\s+R([0-9]+)\\s+reps$", options: [.regularExpression, .caseInsensitive]) {
            let values = String(raw[match]).split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if values.count == 2 { return .perSide(left: values[0], right: values[1], raw: raw) }
        }
        return .unknown(raw: raw)
    }

    private static func metricFor(_ sets: [ExchangeSetDTO]) -> RecordingMetric {
        guard let actual = sets.first?.actual else { return .unknown }
        switch actual { case .fixed, .range, .perSide: return .reps; case .time: return .time; case .distance: return .distance; case .rounds: return .rounds; case .unknown: return .unknown }
    }

    private static func blockType(for label: String) -> BlockType? {
        switch label.lowercased() {
        case "單組", "single": return .single
        case "超級組", "superset": return .superset
        case "遞減組", "dropset": return .dropset
        case "循環組", "circuit": return .circuit
        default: return nil
        }
    }

    private static func capture(_ text: String, _ match: NSTextCheckingResult, _ index: Int) -> String? {
        let range = match.range(at: index); guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }; return String(text[swiftRange])
    }

    private static func fingerprint(_ text: String) -> String { SHA256.hash(data: Data(text.precomposedStringWithCanonicalMapping.utf8)).map { String(format: "%02x", $0) }.joined() }
}
