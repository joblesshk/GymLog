import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import Vision

/// Local evidence for a scan. The default summary omits token text and
/// extracted health values; the explicit detailed copy includes them only
/// after the user requests it.
public struct InBodyTokenBoxDiagnostic: Codable, Equatable {
    public let text: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let confidence: Double

    init(token: RecognizedToken) {
        text = token.text
        x = Double(token.rect.minX)
        y = Double(token.rect.minY)
        width = Double(token.rect.width)
        height = Double(token.rect.height)
        confidence = Double(token.confidence)
    }
}

public struct InBodyScanDiagnostics: Codable, Equatable, Identifiable {
    public let id: String
    public let inputSHA256: String
    public let operatingSystem: String
    public let format: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let exifOrientation: UInt32
    public let visionRevision: Int
    public let tokenCount: Int
    public let tokenBoxes: [InBodyTokenBoxDiagnostic]
    public let fieldConfidence: [String: String]
    public let fieldValues: [String: String]
    public let passedThreshold: Bool

    public var summary: String {
        var lines = [
            "inputSHA256: \(inputSHA256)",
            "operating system: \(operatingSystem)",
            "format: \(format)",
            "pixels: \(pixelWidth)x\(pixelHeight)",
            "EXIF orientation: \(exifOrientation)",
            "Vision revision: \(visionRevision)",
            "tokens: \(tokenCount)",
            "passed threshold: \(passedThreshold)",
            "field confidence: \(fieldConfidence.keys.sorted().map { "\($0)=\(fieldConfidence[$0] ?? "missing")" }.joined(separator: ", "))",
            "token boxes (top-left pixel coordinates):"
        ]
        lines.append(contentsOf: tokenBoxes.enumerated().map { index, box in
            "  [\(index)] x=\(box.x), y=\(box.y), w=\(box.width), h=\(box.height), confidence=\(box.confidence)"
        })
        return lines.joined(separator: "\n")
    }

    /// Explicitly requested detail for diagnosing OCR versus parser errors.
    /// This includes recognized report text and extracted values; it is only
    /// placed on the clipboard after the user taps Copy Details and is never
    /// logged or sent anywhere by the scan pipeline.
    public var detailedSummary: String {
        var lines = [summary, "", "DETAILS (contains report text; local clipboard only):"]
        lines.append("field values: \(fieldValues.keys.sorted().map { "\($0)=\(fieldValues[$0] ?? "")" }.joined(separator: ", "))")
        lines.append("token text and boxes:")
        lines.append(contentsOf: tokenBoxes.enumerated().map { index, box in
            "  [\(index)] \(box.text.debugDescription) x=\(box.x), y=\(box.y), w=\(box.width), h=\(box.height), confidence=\(box.confidence)"
        })
        return lines.joined(separator: "\n")
    }
}

public struct InBodyScanOutput {
    public let scan: InBodyScanResult
    public let diagnostics: InBodyScanDiagnostics
}

/// Shared local scan pipeline used by the UI and synthetic/runtime tests.
/// The input Data is decoded at full available resolution; no upload or
/// logging occurs here.
public enum InBodyScanService {
    public static func scan(data: Data) throws -> InBodyScanOutput {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw InBodyTextRecognizerError.couldNotDecodeImage
        }

        let orientation = cgImageOrientation(from: source)
        let tokens = try InBodyTextRecognizer.recognizeTokens(in: image, orientation: orientation)
        let scan = InBodyReportParser.parse(tokens: tokens)
        let inputSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let diagnostics = InBodyScanDiagnostics(
            id: inputSHA256,
            inputSHA256: inputSHA256,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            format: CGImageSourceGetType(source).map { String(describing: $0) } ?? "unknown",
            pixelWidth: image.width,
            pixelHeight: image.height,
            exifOrientation: orientation.rawValue,
            visionRevision: VNRecognizeTextRequestRevision3,
            tokenCount: tokens.count,
            tokenBoxes: tokens.map(InBodyTokenBoxDiagnostic.init),
            fieldConfidence: [
                "date": confidenceName(scan.dateConfidence),
                "weight": confidenceName(scan.weightConfidence),
                "bodyFat": confidenceName(scan.bodyFatConfidence),
                "skeletalMuscle": confidenceName(scan.skeletalMuscleConfidence),
                "bmi": confidenceName(scan.bmiConfidence),
                "visceralFat": confidenceName(scan.visceralFatConfidence),
                "bmr": confidenceName(scan.bmrConfidence),
                "bodyFatMass": confidenceName(scan.bodyFatMassConfidence)
            ],
            fieldValues: fieldValues(scan),
            passedThreshold: scan.passedThreshold
        )
        return InBodyScanOutput(scan: scan, diagnostics: diagnostics)
    }

    static func cgImageOrientation(from source: CGImageSource) -> CGImagePropertyOrientation {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawValue = properties[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: rawValue) else {
            return .up
        }
        return orientation
    }

    private static func confidenceName(_ confidence: FieldConfidence) -> String {
        switch confidence {
        case .confident: return "confident"
        case .uncertain: return "uncertain"
        case .missing: return "missing"
        }
    }

    private static func fieldValues(_ scan: InBodyScanResult) -> [String: String] {
        var values: [String: String] = [:]
        let decimalFields: [(String, Double?)] = [
            ("weight", scan.weightKg),
            ("bodyFat", scan.bodyFatPercent),
            ("skeletalMuscle", scan.skeletalMuscleKg),
            ("bmi", scan.bmi),
            ("bmr", scan.bmr),
            ("bodyFatMass", scan.bodyFatMassKg)
        ]
        for (key, value) in decimalFields {
            if let value { values[key] = String(format: "%.4g", value) }
        }
        if let value = scan.visceralFatLevel { values["visceralFat"] = String(value) }
        if let date = scan.date { values["date"] = ISO8601DateFormatter().string(from: date) }
        return values
    }
}
