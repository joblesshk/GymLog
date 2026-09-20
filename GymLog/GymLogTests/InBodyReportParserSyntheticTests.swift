import XCTest
import CoreGraphics
import CoreImage
import ImageIO
import UIKit
import UniformTypeIdentifiers
@testable import GymLogKit

final class InBodyReportParserSyntheticTests: XCTestCase {
    private func token(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat = 40, height: CGFloat = 10) -> RecognizedToken {
        RecognizedToken(text: text, rect: CGRect(x: x, y: y, width: width, height: height), confidence: 0.95)
    }

    private func basicTokens(skeletalLabel: String = "Skeletal Muscle Mass", skeletalValue: String = "30.9") -> [RecognizedToken] {
        [
            token("Weight (kg)", x: 10, y: 10), token("68.8", x: 70, y: 10, width: 30),
            token("Percent Body Fat", x: 10, y: 30, width: 80), token("28.7", x: 120, y: 30, width: 30),
            token(skeletalLabel, x: 10, y: 50, width: 110), token(skeletalValue, x: 130, y: 50, width: 30),
            token("BMI", x: 10, y: 70), token("26.0", x: 70, y: 70, width: 30)
        ]
    }

    func testExplicitChineseSkeletalMuscleLabelsAreRecognized() {
        let traditional = InBodyReportParser.parse(tokens: basicTokens(skeletalLabel: "骨骼肌量"))
        let simplified = InBodyReportParser.parse(tokens: basicTokens(skeletalLabel: "骨骼肌重"))

        XCTAssertEqual(traditional.skeletalMuscleKg, 30.9)
        XCTAssertEqual(simplified.skeletalMuscleKg, 30.9)
        XCTAssertEqual(traditional.skeletalMuscleConfidence, .confident)
        XCTAssertEqual(simplified.skeletalMuscleConfidence, .confident)
    }

    func testEnglishSkeletalMuscleLabelSplitAcrossRowsAndSMMCode() {
        var split = basicTokens()
        split.remove(at: 4)
        split.remove(at: 4)
        split.insert(token("Skeletal Muscle", x: 10, y: 50, width: 105), at: 4)
        split.insert(token("Mass", x: 10, y: 65, width: 35), at: 5)
        split.insert(token("30.9", x: 55, y: 65, width: 30), at: 6)

        let splitResult = InBodyReportParser.parse(tokens: split)
        let shortCodeResult = InBodyReportParser.parse(tokens: basicTokens(skeletalLabel: "SMM"))

        XCTAssertEqual(splitResult.skeletalMuscleKg, 30.9)
        XCTAssertEqual(shortCodeResult.skeletalMuscleKg, 30.9)
    }

    func testMissingSMMDoesNotBorrowAdjacentPBFOrBMIOrScaleTicks() {
        let tokens = [
            token("Weight (kg)", x: 10, y: 10), token("68.8", x: 70, y: 10, width: 30),
            token("PBF", x: 10, y: 30), token("28.7", x: 70, y: 30, width: 30),
            token("SMM", x: 10, y: 50),
            token("55", x: 100, y: 50), token("70", x: 170, y: 50),
            token("85", x: 240, y: 50), token("100", x: 310, y: 50), token("115", x: 380, y: 50),
            token("BMI", x: 10, y: 70), token("26.0", x: 70, y: 70, width: 30)
        ]

        let result = InBodyReportParser.parse(tokens: tokens)

        XCTAssertNil(result.skeletalMuscleKg)
        // The global axis detector may conservatively exclude 28.7 when it
        // is numerically adjacent to the chart ticks. It must never borrow
        // BMI=26.0 as PBF, though; a missing value is the safe outcome.
        XCTAssertNotEqual(result.bodyFatPercent, Optional(26.0))
        XCTAssertEqual(result.bmi, 26.0)
        XCTAssertNotEqual(result.skeletalMuscleKg, Optional(28.7))
        XCTAssertNotEqual(result.skeletalMuscleKg, Optional(26.0))
        XCTAssertNotEqual(result.skeletalMuscleKg, Optional(55.0))
    }

    func testOriginalSameRowSMMPBFAndScaleDoesNotBorrowBMI() {
        // Regression for the observed failure: the PBF value and the SMM
        // chart scale share an OCR band, while BMI is on the next row.
        let tokens = [
            token("Weight (kg)", x: 10, y: 10), token("68.8", x: 70, y: 10, width: 30),
            token("SMM", x: 10, y: 50),
            token("PBF", x: 60, y: 50), token("28.7", x: 100, y: 50, width: 30),
            token("55", x: 180, y: 50), token("70", x: 250, y: 50),
            token("85", x: 320, y: 50), token("100", x: 390, y: 50), token("115", x: 460, y: 50),
            token("BMI", x: 10, y: 70), token("26.0", x: 70, y: 70, width: 30)
        ]

        let result = InBodyReportParser.parse(tokens: tokens)

        XCTAssertNil(result.skeletalMuscleKg)
        if let bodyFat = result.bodyFatPercent {
            XCTAssertEqual(bodyFat, 28.7, accuracy: 0.01)
        }
        XCTAssertNotEqual(result.bodyFatPercent, Optional(26.0))
        XCTAssertEqual(result.bmi, 26.0)
    }

    func testMissingSMMKeepsFirstAdjacentScaleTickOutOfFieldValue() {
        let tokens = [
            token("SMM", x: 10, y: 50),
            token("55", x: 55, y: 50), token("70", x: 125, y: 50),
            token("85", x: 195, y: 50), token("100", x: 265, y: 50),
            token("115", x: 335, y: 50)
        ]

        let result = InBodyReportParser.parse(tokens: tokens)

        XCTAssertNil(result.skeletalMuscleKg)
    }

    func testTotalMuscleMassIsNotMappedToSkeletalMuscle() {
        let result = InBodyReportParser.parse(tokens: basicTokens(skeletalLabel: "Total Muscle Mass", skeletalValue: "40.0"))

        XCTAssertNil(result.skeletalMuscleKg)
        XCTAssertEqual(result.weightKg, 68.8)
        XCTAssertEqual(result.bodyFatPercent, 28.7)
        XCTAssertEqual(result.bmi, 26.0)
    }

    func testAxisTicksAndSharedReferenceRangeAreNotUsedAsFieldValues() {
        var tokens = basicTokens(skeletalLabel: "SMM", skeletalValue: "30.9")
        // The chart scale is on a separate row, so it is excluded as a scale
        // without changing the real SMM row's nearest-value search.
        tokens += [
            token("55", x: 160, y: 90), token("70", x: 230, y: 90),
            token("85", x: 300, y: 90), token("100", x: 370, y: 90), token("115", x: 440, y: 90)
        ]
        // A reference range with one shared OCR box must not become a value.
        tokens += [
            token("(", x: 200, y: 30, width: 8),
            token("25.0", x: 208, y: 30, width: 30),
            token("35.0", x: 208, y: 30, width: 30),
            token(")", x: 240, y: 30, width: 8)
        ]

        let result = InBodyReportParser.parse(tokens: tokens)

        XCTAssertEqual(result.skeletalMuscleKg, 30.9)
        XCTAssertEqual(result.bodyFatPercent, 28.7)
    }

    func testOrientationUsesLogicalDimensionsForLeftAndRightExif() {
        let raw = CGSize(width: 4032, height: 3024)

        XCTAssertEqual(InBodyTextRecognizer.orientedImageSize(raw: raw, orientation: .up), raw)
        XCTAssertEqual(InBodyTextRecognizer.orientedImageSize(raw: raw, orientation: .left), CGSize(width: 3024, height: 4032))
        XCTAssertEqual(InBodyTextRecognizer.orientedImageSize(raw: raw, orientation: .right), CGSize(width: 3024, height: 4032))
        XCTAssertEqual(InBodyTextRecognizer.orientedImageSize(raw: raw, orientation: .upMirrored), raw)
    }

    // Synthetic layout and values, not a transcription of a private report.
    private func chartTokens(code: String = "SMM", value: String? = "31.7") -> [RecognizedToken] {
        var tokens = [
            token(code, x: 20, y: 100, width: 30),
            token("UnreadableCaption", x: 20, y: 105, width: 90),
            token("Report", x: 700, y: 20)
        ]
        for (index, tick) in ["20.0", "250", "35.0", "40.0", "5.0", "500", "550"].enumerated() {
            tokens.append(token(tick, x: CGFloat(150 + index * 50), y: 96, width: 25))
        }
        if let value { tokens.append(token(value, x: 275, y: 110, width: 30)) }
        return tokens
    }

    func testChartValueBelowScaleSurvivesGarbledCaptionAndNonMonotonicTicks() {
        let muscle = InBodyReportParser.parse(tokens: chartTokens())
        let fat = InBodyReportParser.parse(tokens: chartTokens(code: "PBF", value: "24.6"))
        let bmi = InBodyReportParser.parse(tokens: chartTokens(code: "BMI", value: "23.4"))
        XCTAssertEqual(muscle.skeletalMuscleKg, 31.7)
        XCTAssertEqual(fat.bodyFatPercent, 24.6)
        XCTAssertEqual(bmi.bmi, 23.4)
    }

    func testMissingChartValueDoesNotFallThroughToHistory() {
        var tokens = chartTokens(value: nil)
        tokens += [token("Skeletal Muscle Mass", x: 20, y: 300, width: 110),
                   token("28.1", x: 150, y: 300, width: 30)]
        XCTAssertNil(InBodyReportParser.parse(tokens: tokens).skeletalMuscleKg)
    }

    func testChartDoesNotBorrowAnotherFieldBelowScale() {
        var tokens = chartTokens(value: nil)
        tokens += [token("BMI", x: 200, y: 110, width: 30),
                   token("23.4", x: 275, y: 110, width: 30)]
        XCTAssertNil(InBodyReportParser.parse(tokens: tokens).skeletalMuscleKg)
    }

    func testChartAmbiguityAndSharedReferenceRangeRemainMissing() {
        var ambiguous = chartTokens()
        ambiguous.append(token("33.1", x: 350, y: 110, width: 30))
        XCTAssertNil(InBodyReportParser.parse(tokens: ambiguous).skeletalMuscleKg)
        var range = chartTokens(value: nil)
        range += [token("27.0", x: 275, y: 110, width: 60),
                  token("35.0", x: 275, y: 110, width: 60)]
        XCTAssertNil(InBodyReportParser.parse(tokens: range).skeletalMuscleKg)
    }

    func testChartDescriptiveCaptionDoesNotBlockItsOwnMeasurement() {
        var tokens = chartTokens(code: "PBF", value: "24.6")
        tokens.removeAll { $0.text == "UnreadableCaption" }
        tokens.append(token("Percent Body Fat", x: 20, y: 110, width: 90))
        XCTAssertEqual(InBodyReportParser.parse(tokens: tokens).bodyFatPercent, 24.6)
    }

    func testChartAllowsTwoConsecutiveTicksMissingFromOCR() {
        var tokens = chartTokens()
        tokens.removeAll { $0.text == "250" || $0.text == "35.0" }
        XCTAssertEqual(InBodyReportParser.parse(tokens: tokens).skeletalMuscleKg, 31.7)
    }

    func testLaterHistoryGridDoesNotOverrideEarlierTableValue() {
        var tokens = basicTokens(skeletalLabel: "SMM")
        tokens += chartTokens().map {
            RecognizedToken(text: $0.text, rect: $0.rect.offsetBy(dx: 0, dy: 300), confidence: $0.confidence)
        }
        XCTAssertEqual(InBodyReportParser.parse(tokens: tokens).skeletalMuscleKg, 30.9)
    }

    func testBasalMetabolicRateWithDroppedLetter() {
        let result = InBodyReportParser.parse(tokens: [
            token("Basal Metabolc Rate", x: 20, y: 10, width: 130),
            token("1628", x: 165, y: 10, width: 40)
        ])
        XCTAssertEqual(result.bmr, 1628)
    }

    func testScanServiceRunsOnGeneratedLocalImageAndReturnsDiagnostics() throws {
        let image = makeSyntheticReportImage()
        let uprightData = try encodedJPEG(image, exifOrientation: .up)
        let upright = try InBodyScanService.scan(data: uprightData)

        XCTAssertEqual(upright.diagnostics.pixelWidth, 1200)
        XCTAssertEqual(upright.diagnostics.pixelHeight, 500)
        XCTAssertEqual(try XCTUnwrap(upright.scan.skeletalMuscleKg), 30.9, accuracy: 0.01)
        XCTAssertTrue(upright.scan.passedThreshold)
        XCTAssertEqual(upright.diagnostics.inputSHA256.count, 64)
        XCTAssertEqual(upright.diagnostics.tokenCount, upright.diagnostics.tokenBoxes.count)
        XCTAssertFalse(upright.diagnostics.summary.contains("68.8"))
        XCTAssertTrue(upright.diagnostics.detailedSummary.contains("68.8"))
        XCTAssertTrue(upright.diagnostics.detailedSummary.contains("Skeletal"))
        XCTAssertTrue(upright.diagnostics.detailedSummary.contains("operating system:"))

        // Encode the same displayed report as raw pixels inverse-rotated for
        // each EXIF tag. Vision then applies the tag exactly once; the parser
        // should see the same report values as the upright input.
        let right = try InBodyScanService.scan(data: encodedJPEG(image, exifOrientation: .right))
        let left = try InBodyScanService.scan(data: encodedJPEG(image, exifOrientation: .left))
        XCTAssertEqual(try XCTUnwrap(right.scan.skeletalMuscleKg), try XCTUnwrap(upright.scan.skeletalMuscleKg), accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(left.scan.skeletalMuscleKg), try XCTUnwrap(upright.scan.skeletalMuscleKg), accuracy: 0.01)
        XCTAssertTrue(right.scan.passedThreshold)
        XCTAssertTrue(left.scan.passedThreshold)
        XCTAssertEqual(right.diagnostics.exifOrientation, CGImagePropertyOrientation.right.rawValue)
        XCTAssertEqual(left.diagnostics.exifOrientation, CGImagePropertyOrientation.left.rawValue)
    }

    private func makeSyntheticReportImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 500), format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 500))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 42, weight: .bold),
                .foregroundColor: UIColor.black
            ]
            ("Weight (kg) 68.8   Percent Body Fat 28.7\nSkeletal Muscle Mass 30.9   BMI 26.0" as NSString)
                .draw(in: CGRect(x: 40, y: 80, width: 1120, height: 180), withAttributes: attributes)
        }
    }

    private func encodedJPEG(_ image: UIImage, exifOrientation: CGImagePropertyOrientation) throws -> Data {
        guard let base = image.cgImage else { throw NSError(domain: "InBodyTest", code: 1) }
        let rawImage: CGImage
        switch exifOrientation {
        case .right, .left:
            let inverse = exifOrientation == .right ? CGImagePropertyOrientation.left : .right
            let ciImage = CIImage(cgImage: base).oriented(forExifOrientation: Int32(inverse.rawValue))
            rawImage = try XCTUnwrap(CIContext().createCGImage(ciImage, from: ciImage.extent))
        default:
            rawImage = base
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "InBodyTest", code: 2)
        }
        CGImageDestinationAddImage(destination, rawImage, [kCGImagePropertyOrientation: exifOrientation.rawValue] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "InBodyTest", code: 3) }
        return data as Data
    }
}
